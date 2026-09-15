# grasp_index

The indexer half of [Grasp](../README.md). Add it to the project you want to review:

```elixir
{:grasp_index, "~> 0.1", only: :dev, runtime: false}
```

Then:

```
mix grasp.index [--out .grasp/index.json]
```

The task forces a full recompile with a compiler tracer attached, so every call the
compiler resolves is recorded with the position of the call in your source, then joins
those calls with the function definitions Sourceror finds and writes one JSON document.
The Grasp viewer and its MCP server read that document; `Grasp.Index` in this package is
the reader they use.

The document shape is described in `docs/specs/2026-09-15-grasp-design.md` at the repo
root under "Index JSON".
