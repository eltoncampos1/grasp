# grasp CLI — Spec

> Working name. Colide com o upstream [gfrancischelli/grasp](https://github.com/gfrancischelli/grasp)
> (Apache-2.0), do qual este projeto deriva o conceito e o formato do índice. Renomear antes de
> publicar (candidatos: `graspx`, `gcr`, `canvas-review`).
>
> **Decisão (2026-09-22): independência total do upstream.** Tudo que era Elixir foi
> reimplementado em Go — indexador (tree-sitter), viewer (embutido no binário via `embed.FS`),
> comments e publish. Nada do fluxo depende de Elixir instalado. Foco inicial de linguagens:
> **Elixir, JS/TS e Go**.

## Visão

Code review visual, agnóstico de linguagem, como **CLI standalone** — sem ser dependência do
projeto revisado. O grasp original é uma dependência Elixir (`only: :dev`) montada no router do
app, o que restringe a projetos Phoenix 1.8+/Elixir 1.19+ e exige setup por projeto. Esta CLI é
um binário único que roda em qualquer repo git:

```bash
cd qualquer-repo
grasp init      # uma vez por repo
grasp pr        # picker de PRs → worktree + index + web + review
```

O que fica no repo: apenas `.grasp/` (gitignorado, exceto as regras de review do time).

## Princípios

1. **Contrato central: `index.json` v1**, compatível com o schema do grasp upstream
   (`{version, project, git, modules[], functions[], entry_points[]}`; cada function com
   `id`, `file`, `span`, `source`, `base_source`, `change`, `calls[{target, range}]`).
   Indexadores e viewer se comunicam só por ele — qualquer um dos lados é substituível.
2. **Zero footprint no projeto revisado.** Nada de dependência, mount em router, ou restrição
   de versão de framework.
3. **Agente plugável.** Claude Code é o backend default, mas a camada de agente é um adapter —
   outros CLIs (Kimi, etc.) entram por config.
4. **Review local primeiro; publicar é sempre explícito.** O agente escreve comments no
   `.grasp/comments.json` local. Nada é postado no GitHub sem um `grasp publish` deliberado.

## Comandos

| Comando | Descrição | Versão |
|---|---|---|
| `grasp init` | Setup do repo: detecta linguagens, remote, base branch; escolhe perfil do agente; escreve config + `.gitignore` | v0 |
| `grasp pr [N]` | Sem `N`: picker fuzzy de PRs abertos. Com `N`: direto. Worktree → index → web → browser, numa tacada | v0 |
| `grasp pr --close [N]` | Remove o worktree (forçado). Sem `N`: picker dos worktrees abertos | v0 |
| `grasp index [--base REF]` | Só gera o índice (scripting/CI). Base default: `origin/HEAD` detectado no init | v0 |
| `grasp doctor` | Diagnóstico: gh autenticado? agente resolve? qual perfil/modelo será usado? ping real no agente | v0 |
| `grasp web [BRANCH]` | Revisa a branch atual (ou a indicada) contra a base: indexa, sobe o server, **abre o browser** e **dispara o auto-review** (ver abaixo) | v1 |
| `grasp publish [N]` | Envia os comment threads locais como review comments do PR, via `gh`. Threads já publicadas são puladas | v1 |

Flags do `grasp web` / `grasp pr`:

- `--no-open` — não abrir o browser
- `--no-review` — não disparar o auto-review
- `--port`, `--base REF`
- `--watch` (web) — reindexa ao salvar arquivos (file watcher; substitui o hook de compiler
  do grasp original)

## Configuração

Três camadas, da mais geral para a mais específica:

```
~/.config/grasp/config.toml    # defaults globais do usuário (perfil de agente default, editor, porta)
.grasp/config.toml             # por-repo, PESSOAL — gitignorado (perfis têm paths locais)
.grasp/review.md               # regras de review — COMMITÁVEL (padrão do time, viaja com o repo)
```

### `.grasp/config.toml`

```toml
[agent]
backend    = "claude-code"        # v2: "kimi", "custom"
command    = "claude"
config_dir = "~/.claude-work"    # CLAUDE_CONFIG_DIR do perfil escolhido no init
model      = "opus"

[review]
base = "main"          # autodetectado: origin/HEAD
auto = true            # dispara review ao abrir web/pr (--no-review desliga pontualmente)

[index]
languages = ["typescript", "javascript"]   # detectadas no init; determina os grammars

[web]
port   = 4040
editor = "vscode"      # deep links file:line — vscode | cursor | zed | idea
open   = true
```

### Perfis do Claude (dor real que o init resolve)

Usuários com múltiplos perfis (`CLAUDE_CONFIG_DIR`, ex.: `~/.claude`, `~/.claude-work`) hoje
caem no perfil errado quando o grasp spawna `claude` com env herdado — e o `claude mcp add` do
setup registra o MCP no perfil errado.

- `grasp init` **descobre os perfis** (glob `~/.claude*` + default) e pergunta qual usar no repo.
- Todo spawn do agente sai com `CLAUDE_CONFIG_DIR` do config — determinístico.
- O MCP server do grasp **não é registrado em perfil nenhum**: é passado inline no spawn via
  `claude --mcp-config '{"mcpServers":{"grasp":{"type":"http","url":"http://127.0.0.1:PORT/mcp"}}}'`.
  Zero mutação de perfil; o perfil só decide auth/modelo.
- `grasp doctor` imprime a resolução completa e testa com `claude -p "ping"` no env configurado.

## Fluxos

### `grasp init`

1. Detecta linguagens por extensão/heurística → seleciona grammars tree-sitter.
2. Detecta remote, repo do GitHub (`gh repo view`), base branch (`origin/HEAD`).
3. Picker de perfil do agente (ver acima).
4. Escreve `.grasp/config.toml`, cria `.grasp/review.md` a partir de template, adiciona
   `.grasp/` ao `.gitignore` (com exceção `!.grasp/review.md`).

### `grasp pr [N]`

1. Sem `N`: picker fuzzy alimentado por `gh pr list --json number,title,author,headRefName,statusCheckRollup,updatedAt`
   (cache em `.grasp/cache/` com TTL curto; refresh em background — picker abre instantâneo).
2. Fetch base + head; worktree detached em `.grasp/worktrees/pr-N` (move se já existe; checkout
   não-forçado — edits não commitados param com a mensagem do git, como no upstream).
3. Indexa dentro do worktree contra o merge-base do PR → `.grasp/index.json`.
4. Sobe o server (se não estiver de pé), abre o browser, dispara auto-review (se configurado).

Comments e sessões ficam no `.grasp/` do checkout principal, nunca no worktree — o review
sobrevive ao `--close` (comportamento herdado do upstream).

### Sync com o repositório (cache do `gh`)

O init ancora a CLI no repo, então ela mantém `.grasp/cache/` com PRs abertos e branches para
os pickers. Issues **não** ganham UI própria: entram como tool MCP (`get_issue`) para o agente
puxar contexto durante o review (v2).

## Auto-review (v2 — documentado desde já)

Ao abrir `grasp web` ou `grasp pr` (com `review.auto = true` e sem `--no-review`):

1. A CLI monta o prompt de review: template embutido + **`.grasp/review.md`** (regras, padrões
   e convenções do time — commitável) + metadados do PR (título, descrição, base).
2. Spawna o agente configurado, conectado ao MCP do grasp via config inline.
3. O agente usa as tools MCP para trabalhar o canvas: buscar no índice, traçar callers/callees,
   abrir e organizar cards, **escrever comments nas linhas** — que aparecem na UI em tempo real
   enquanto o humano navega.
4. O resultado são comment threads locais. **Publicar no GitHub continua sendo ação manual**
   (`grasp publish` ou pedir no chat) — princípio 4.

### `.grasp/review.md` (exemplo)

```markdown
# Regras de review deste repo

- Toda query MongoDB deve ter escopo de tenant e `"deleted" => false`.
- Mutations GraphQL: verificar `__typename` antes de acessar dados.
- Apontar N+1 e índices ausentes em queries novas.
- Não comentar estilo — o linter cobre.
```

## Agentes plugáveis (v2 — documentado desde já)

A camada de agente é um adapter com três responsabilidades: **spawn** (comando + args + env),
**streaming** (normalizar o output para o chat panel) e **conexão MCP** (como o CLI do agente
recebe o server do grasp).

```toml
[agent]
backend = "kimi"

[agents.kimi]
command = "kimi"                 # Kimi CLI (Moonshot) — suporta MCP
# args/env específicos do backend

[agents.custom]
command = "meu-agente"
args    = ["--mcp", "{mcp_url}", "--prompt", "{prompt}"]
```

- **claude-code** (default): `--output-format stream-json`, `--mcp-config` inline,
  `CLAUDE_CONFIG_DIR` por perfil.
- **kimi**: Kimi CLI com MCP; adapter próprio de streaming.
- **custom**: template de comando com placeholders — escape hatch para qualquer CLI.

O viewer e as tools MCP são agnósticos ao backend; só o adapter muda.

## Indexação

- **v0: tree-sitter** — fronteiras de função exatas; resolução de calls heurística (por nome,
  com marcação de ambiguidade). Suficiente para review diff-first; perde a exatidão do compiler
  tracer do grasp original.
- Classificação `added/modified/unchanged/removed`: `git diff` contra o merge-base × spans das
  funções; `base_source` extraído do blob da base (`git show BASE:file`).
- **Futuro:** backends de precisão plugáveis por linguagem — SCIP (scip-typescript, scip-go,
  scip-python) e/ou LSP call hierarchy — emitindo o mesmo `index.json`.
- `entry_points` são framework-específicos (rotas, workers): fora do v0; depois como detectores
  plugáveis por convenção.

## Stack

- **Go**, binário único: `os/exec` (git/gh), go-tree-sitter (grammars compilados no binário),
  `net/http` + `embed.FS` (viewer), SSE para live reload do índice, bubbletea/fuzzyfinder
  (pickers), SDK Go oficial de MCP.
- O canvas é JS no browser (embutido no binário). Referência de comportamento: `review_live.ex`
  (~1.2k linhas) + `canvas.js` (~1.2k linhas) do upstream.
- Distribuição: `brew install` / `curl | sh`, cross-compile por plataforma.

## Roadmap

| Versão | Entrega |
|---|---|
| **v0** ✅ | `init`, `pr` (picker + worktree), `index` tree-sitter TS/JS, `doctor`. Validado contra PRs reais do builder-ui e contra o viewer upstream (2026-09-22) |
| **v1** ✅ (parcial) | **Entregue 2026-09-22:** indexadores Elixir (aliases, imports only:, clauses merged, captures, pipe-arity) e Go (packages via go.mod, methods por receiver); viewer próprio embutido no binário — canvas com cards e edges SVG, sidebar de changes, palette ⌘K, diff/source (`d`), changes-only fold (`h`), comments com reply/resolve persistidos em `.grasp/comments.json`, live-reload SSE, guard de loopback; `grasp publish` (threads → review comments via gh, fallback file-level). Validado: platform Elixir 7.1k funções/11.5k edges em 0,73s; grasp-cli Go; builder-ui JS |
| **v1.1** ✅ | **Entregue 2026-09-22:** canvas whiteboard (posições livres, drag/pan/zoom, reset layout por profundidade, signature mode, arrow keys, Shift+x fecha subtree); auto-abertura do review (changed functions em colunas por módulo, modified em diff, edges entre elas); callers menu abrindo à esquerda; edges coloridas por call site com double-click para saltar; syntax highlight (ex/js/go); sidebar review-first (Changes, Comments, Related 1-hop; módulos completos atrás de toggle); sessões (`.grasp/sessions/*.json`, autosave, `pr-N` automática, menu no header, `?s=`); comments com range (shift+click) e lado base; chat panel ⌘I (CLI headless, cwd = árvore revisada, system prompt com changed+review.md, modos read/edit com allowlists, resume por sessão, stop, 60 turns, model select) |
| **v1 restante** | MCP server em Go (agente dirige o canvas: set_cards/open_card/find_paths/comments), groups/frames, re-anchoring de comments, drag para range, entry points plugáveis, `web --watch` |
| **v2** | Auto-review na abertura (`review.auto` + `.grasp/review.md`, `--no-review`), agentes plugáveis (Kimi, custom), issues como contexto MCP, backends de precisão (SCIP/LSP), path aliases JS |

## Riscos e decisões em aberto

- **Nome** — colisão com o upstream; decidir antes de publicar.
- **Precisão heurística** — o v0 valida se a navegação por tree-sitter sustenta a experiência;
  se não, antecipar SCIP.
- **Viewer: reescrever vs. emprestar** — v0 empresta o do upstream (exige Elixir na máquina, só
  para validação); v1 assume a reescrita (~2-3 semanas, o item mais caro do projeto).
- **Upstream** — o schema versionado sugere contrato pensado; vale conversar com o autor sobre
  um modo "bring your own indexer" antes de divergir demais.
