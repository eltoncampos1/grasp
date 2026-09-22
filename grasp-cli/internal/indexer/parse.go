package indexer

import (
	"path/filepath"
	"strings"
	"unicode"

	sitter "github.com/tree-sitter/go-tree-sitter"
	ts_js "github.com/tree-sitter/tree-sitter-javascript/bindings/go"
	ts_ts "github.com/tree-sitter/tree-sitter-typescript/bindings/go"
)

var (
	langJS  = sitter.NewLanguage(ts_js.Language())
	langTS  = sitter.NewLanguage(ts_ts.LanguageTypescript())
	langTSX = sitter.NewLanguage(ts_ts.LanguageTSX())
)

// LanguageFor picks the grammar for a path; nil means "not indexable".
func LanguageFor(path string) *sitter.Language {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".ts", ".mts", ".cts":
		return langTS
	case ".tsx":
		return langTSX
	case ".js", ".jsx", ".mjs", ".cjs":
		return langJS
	}
	return nil
}

// rawCall is an unresolved call site: `name(...)`, `object.name(...)` or a
// JSX component usage. Resolution into Call happens after every file parsed.
type rawCall struct {
	object string
	name   string
	rng    Range
}

// record is one extracted function plus what resolution needs.
type record struct {
	fn        *Function
	localName string // resolution key: "foo" or "Class.method"
	isDefault bool   // the file's `export default`
	rawCalls  []rawCall
}

// importRef maps a local identifier to where it was imported from.
type importRef struct {
	spec string // the literal import source ("./x", "react", …)
	name string // exported name, "default", or "*" for namespaces
}

type fileParse struct {
	relPath     string
	module      string
	records     []*record
	byName      map[string]*record
	imports     map[string]importRef
	defaultName string // `export default foo` referencing a declaration above
	lines       []string
}

func moduleName(relPath string) string {
	p := strings.TrimSuffix(relPath, filepath.Ext(relPath))
	return strings.ReplaceAll(p, "/", ".")
}

// parseFile extracts function records and their raw call sites from one file.
// The parser is reused across files by the same worker; the tree is closed
// before returning.
func parseFile(parser *sitter.Parser, relPath string, src []byte) *fileParse {
	lang := LanguageFor(relPath)
	if lang == nil {
		return nil
	}
	if err := parser.SetLanguage(lang); err != nil {
		return nil
	}
	tree := parser.Parse(src, nil)
	if tree == nil {
		return nil
	}
	defer tree.Close()

	fp := &fileParse{
		relPath: relPath,
		module:  moduleName(relPath),
		byName:  map[string]*record{},
		imports: map[string]importRef{},
		lines:   strings.Split(string(src), "\n"),
	}

	root := tree.RootNode()
	cursor := root.Walk()
	children := root.NamedChildren(cursor)
	cursor.Close()
	for i := range children {
		fp.topStatement(&children[i], src, false, false, nil)
	}
	return fp
}

// topStatement handles one module-level statement. spanNode, when non-nil,
// is the enclosing export_statement so the record's span includes it.
func (fp *fileParse) topStatement(stmt *sitter.Node, src []byte, exported, isDefault bool, spanNode *sitter.Node) {
	switch stmt.Kind() {
	case "export_statement":
		hasDefault := false
		for i := uint(0); i < stmt.ChildCount(); i++ {
			if c := stmt.Child(i); c != nil && c.Kind() == "default" {
				hasDefault = true
			}
		}
		if decl := stmt.ChildByFieldName("declaration"); decl != nil {
			fp.topStatement(decl, src, true, hasDefault, stmt)
			return
		}
		if v := stmt.ChildByFieldName("value"); v != nil {
			if v.Kind() == "identifier" {
				fp.defaultName = v.Utf8Text(src)
			} else if fn := unwrapFunction(v, 3); fn != nil {
				fp.addRecord("default", fn, stmt, src, true, true)
			}
		}

	case "function_declaration", "generator_function_declaration":
		name := "default"
		if n := stmt.ChildByFieldName("name"); n != nil {
			name = n.Utf8Text(src)
		}
		fp.addRecord(name, stmt, spanOr(stmt, spanNode), src, exported, isDefault)

	case "lexical_declaration", "variable_declaration":
		declarators := namedChildrenOfKind(stmt, "variable_declarator")
		for i := range declarators {
			d := &declarators[i]
			nameN := d.ChildByFieldName("name")
			valueN := d.ChildByFieldName("value")
			if nameN == nil || valueN == nil || nameN.Kind() != "identifier" {
				continue
			}
			valueN = unwrapFunction(valueN, 3)
			if valueN == nil {
				continue
			}
			// A single declarator takes the whole statement (and any export
			// keyword) as its span; siblings in a multi-declaration keep their
			// own node.
			span := d
			if len(declarators) == 1 {
				span = spanOr(stmt, spanNode)
			}
			fp.addRecord(nameN.Utf8Text(src), valueN, span, src, exported, isDefault)
		}

	case "class_declaration", "abstract_class_declaration":
		nameN := stmt.ChildByFieldName("name")
		body := stmt.ChildByFieldName("body")
		if nameN == nil || body == nil {
			return
		}
		className := nameN.Utf8Text(src)
		cursor := body.Walk()
		members := body.NamedChildren(cursor)
		cursor.Close()
		for i := range members {
			m := &members[i]
			switch m.Kind() {
			case "method_definition":
				if mn := m.ChildByFieldName("name"); mn != nil {
					fp.addRecord(className+"."+mn.Utf8Text(src), m, m, src, exported, false)
				}
			case "field_definition", "public_field_definition":
				prop := m.ChildByFieldName("property")
				value := m.ChildByFieldName("value")
				if prop != nil && value != nil && isFunctionKind(value.Kind()) {
					fp.addRecord(className+"."+prop.Utf8Text(src), value, m, src, exported, false)
				}
			}
		}

	case "import_statement":
		fp.addImport(stmt, src)
	}
}

func isFunctionKind(kind string) bool {
	switch kind {
	case "arrow_function", "function_expression", "function", "generator_function":
		return true
	}
	return false
}

// unwrapFunction digs a function out of wrapper calls — React.forwardRef(fn),
// memo(() => …), observer(connect(fn)) — up to depth levels of nesting. The
// record keeps the declarator's name; the wrapper is an implementation detail.
func unwrapFunction(n *sitter.Node, depth int) *sitter.Node {
	if isFunctionKind(n.Kind()) {
		return n
	}
	if depth == 0 || n.Kind() != "call_expression" {
		return nil
	}
	args := n.ChildByFieldName("arguments")
	if args == nil {
		return nil
	}
	for i := uint(0); i < args.NamedChildCount(); i++ {
		if c := args.NamedChild(i); c != nil {
			if fn := unwrapFunction(c, depth-1); fn != nil {
				return fn
			}
		}
	}
	return nil
}

func spanOr(node, wrapper *sitter.Node) *sitter.Node {
	if wrapper != nil {
		return wrapper
	}
	return node
}

func namedChildrenOfKind(n *sitter.Node, kind string) []sitter.Node {
	cursor := n.Walk()
	children := n.NamedChildren(cursor)
	cursor.Close()
	out := children[:0]
	for i := range children {
		if children[i].Kind() == kind {
			out = append(out, children[i])
		}
	}
	return out
}

// addRecord creates a Function for a definition. funcNode carries the
// parameters and body; spanNode is the full statement the card shows.
func (fp *fileParse) addRecord(localName string, funcNode, spanNode *sitter.Node, src []byte, exported, isDefault bool) {
	arity := countParams(funcNode)

	kind := "defp"
	if exported {
		kind = "def"
	}

	start := int(spanNode.StartPosition().Row) + 1
	end := int(spanNode.EndPosition().Row) + 1

	fn := &Function{
		Module:      fp.module,
		Name:        localName,
		Arity:       arity,
		Arities:     []int{arity},
		Kind:        kind,
		File:        fp.relPath,
		Span:        Span{StartLine: start, EndLine: end},
		Source:      fp.sourceLines(start, end),
		Change:      "unchanged",
		Calls:       []Call{},
		HiddenCalls: []Call{},
	}
	fn.ID = fp.module + "." + localName + "/" + itoa(arity)

	rec := &record{fn: fn, localName: localName, isDefault: isDefault}
	collectCalls(funcNode, src, &rec.rawCalls)
	// TS overload signatures and accidental redeclarations: first one wins.
	if _, dup := fp.byName[localName]; dup {
		return
	}
	fp.records = append(fp.records, rec)
	fp.byName[localName] = rec
}

func (fp *fileParse) sourceLines(start, end int) string {
	if start < 1 {
		start = 1
	}
	if end > len(fp.lines) {
		end = len(fp.lines)
	}
	if start > end {
		return ""
	}
	return strings.Join(fp.lines[start-1:end], "\n")
}

func countParams(funcNode *sitter.Node) int {
	if p := funcNode.ChildByFieldName("parameters"); p != nil {
		n := 0
		cursor := p.Walk()
		for _, c := range p.NamedChildren(cursor) {
			if c.Kind() != "comment" {
				n++
			}
		}
		cursor.Close()
		return n
	}
	// `x => …`: a single bare parameter.
	if funcNode.ChildByFieldName("parameter") != nil {
		return 1
	}
	return 0
}

// collectCalls walks a definition's subtree recording call sites: plain
// `name(...)`, single-level `object.name(...)`, and capitalized JSX tags
// (a component tag is a call site, the way upstream treats ~H templates).
func collectCalls(n *sitter.Node, src []byte, out *[]rawCall) {
	switch n.Kind() {
	case "call_expression":
		if fnN := n.ChildByFieldName("function"); fnN != nil {
			switch fnN.Kind() {
			case "identifier":
				name := fnN.Utf8Text(src)
				if name != "require" && name != "import" {
					*out = append(*out, rawCall{name: name, rng: rangeOf(fnN)})
				}
			case "member_expression":
				obj := fnN.ChildByFieldName("object")
				prop := fnN.ChildByFieldName("property")
				if obj != nil && prop != nil && obj.Kind() == "identifier" {
					*out = append(*out, rawCall{
						object: obj.Utf8Text(src),
						name:   prop.Utf8Text(src),
						rng:    rangeOf(fnN),
					})
				}
			}
		}
	case "jsx_self_closing_element", "jsx_opening_element":
		if nameN := n.ChildByFieldName("name"); nameN != nil {
			text := nameN.Utf8Text(src)
			parts := strings.Split(text, ".")
			switch {
			case len(parts) == 1 && startsUpper(text):
				*out = append(*out, rawCall{name: text, rng: rangeOf(nameN)})
			case len(parts) == 2 && startsUpper(parts[0]):
				*out = append(*out, rawCall{object: parts[0], name: parts[1], rng: rangeOf(nameN)})
			}
		}
	}
	for i := uint(0); i < n.NamedChildCount(); i++ {
		if c := n.NamedChild(i); c != nil {
			collectCalls(c, src, out)
		}
	}
}

func (fp *fileParse) addImport(stmt *sitter.Node, src []byte) {
	srcN := stmt.ChildByFieldName("source")
	if srcN == nil {
		return
	}
	spec := strings.Trim(srcN.Utf8Text(src), "'\"`")

	cursor := stmt.Walk()
	children := stmt.NamedChildren(cursor)
	cursor.Close()
	for i := range children {
		c := &children[i]
		if c.Kind() != "import_clause" {
			continue
		}
		cur := c.Walk()
		parts := c.NamedChildren(cur)
		cur.Close()
		for j := range parts {
			p := &parts[j]
			switch p.Kind() {
			case "identifier":
				fp.imports[p.Utf8Text(src)] = importRef{spec: spec, name: "default"}
			case "namespace_import":
				for k := uint(0); k < p.NamedChildCount(); k++ {
					if id := p.NamedChild(k); id != nil && id.Kind() == "identifier" {
						fp.imports[id.Utf8Text(src)] = importRef{spec: spec, name: "*"}
					}
				}
			case "named_imports":
				pc := p.Walk()
				specs := p.NamedChildren(pc)
				pc.Close()
				for k := range specs {
					s := &specs[k]
					if s.Kind() != "import_specifier" {
						continue
					}
					nameN := s.ChildByFieldName("name")
					if nameN == nil {
						continue
					}
					local := nameN
					if aliasN := s.ChildByFieldName("alias"); aliasN != nil {
						local = aliasN
					}
					fp.imports[local.Utf8Text(src)] = importRef{spec: spec, name: nameN.Utf8Text(src)}
				}
			}
		}
	}
}

func rangeOf(n *sitter.Node) Range {
	s, e := n.StartPosition(), n.EndPosition()
	return Range{
		Start: [2]int{int(s.Row) + 1, int(s.Column) + 1},
		End:   [2]int{int(e.Row) + 1, int(e.Column) + 1},
	}
}

func startsUpper(s string) bool {
	for _, r := range s {
		return unicode.IsUpper(r)
	}
	return false
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	digits := []byte{}
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}
