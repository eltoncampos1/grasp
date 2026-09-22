package indexer

import (
	"path"
	"strings"
)

// resolveAll turns every file's raw call sites into Call entries pointing at
// indexed function ids. Heuristic, in order of confidence:
//
//  1. a name defined in the same file (includes `Class.method`);
//  2. a name imported from another project file (default, named or namespace);
//  3. a name defined exactly once across the whole project.
//
// Anything else — external packages, ambiguous names — is dropped rather than
// guessed: a wrong edge misleads a review more than a missing one.
func resolveAll(files map[string]*fileParse) {
	byName := map[string][]*record{}
	for _, f := range files {
		for _, r := range f.records {
			byName[r.localName] = append(byName[r.localName], r)
		}
	}

	for _, f := range files {
		for _, r := range f.records {
			for _, c := range r.rawCalls {
				target, kind := resolveCall(f, c, files, byName)
				if target == nil || target == r {
					continue
				}
				r.fn.Calls = append(r.fn.Calls, Call{
					Kind:   kind,
					Target: target.fn.ID,
					Range:  c.rng,
				})
			}
		}
	}
}

func resolveCall(f *fileParse, c rawCall, files map[string]*fileParse, byName map[string][]*record) (*record, string) {
	if c.object == "" {
		if r := f.byName[c.name]; r != nil {
			return r, "local"
		}
		if ref, ok := f.imports[c.name]; ok {
			if tf := resolveSpec(f, ref.spec, files); tf != nil {
				if ref.name == "default" {
					return tf.defaultRecord(), "remote"
				}
				return tf.byName[ref.name], "remote"
			}
			return nil, "" // imported, but external to the project
		}
		if lst := byName[c.name]; len(lst) == 1 {
			return lst[0], "remote"
		}
		return nil, ""
	}

	// `X.m()` — X as a namespace or default import of a project file.
	if ref, ok := f.imports[c.object]; ok {
		if tf := resolveSpec(f, ref.spec, files); tf != nil {
			return tf.byName[c.name], "remote"
		}
		return nil, ""
	}
	// `X.m()` — method of a class in the same file.
	if r := f.byName[c.object+"."+c.name]; r != nil {
		return r, "local"
	}
	return nil, ""
}

func (fp *fileParse) defaultRecord() *record {
	for _, r := range fp.records {
		if r.isDefault {
			return r
		}
	}
	if fp.defaultName != "" {
		return fp.byName[fp.defaultName]
	}
	return nil
}

var indexableExts = []string{".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"}

// resolveSpec resolves a relative import specifier to a parsed project file.
// Package imports (react, lodash, aliases) return nil in v0.
func resolveSpec(from *fileParse, spec string, files map[string]*fileParse) *fileParse {
	if !strings.HasPrefix(spec, ".") {
		return nil
	}
	base := path.Join(path.Dir(from.relPath), spec)
	candidates := []string{base}
	for _, ext := range indexableExts {
		candidates = append(candidates, base+ext)
	}
	for _, ext := range indexableExts {
		candidates = append(candidates, path.Join(base, "index"+ext))
	}
	for _, cand := range candidates {
		if f, ok := files[cand]; ok {
			return f
		}
	}
	return nil
}
