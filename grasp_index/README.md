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

The document also lists the project's **entry points** — the places its code starts
executing. After compiling, the task loads the application's modules and reads what they
export and what behaviours they declare: Phoenix routers (by their `__routes__/0`) give a
`route` per controller action and a `live_route` per LiveView route, with the verb, path,
router and helper as meta; `Oban.Worker` gives `perform/1` with its queue and max
attempts; `Phoenix.LiveView`, `Phoenix.LiveComponent`, `GenServer`, `Supervisor`,
`Application` and `Plug` give their callbacks. A callback is listed only when the index
holds a definition for it, so the defaults `use GenServer` injects and a dependency's
forwarded controllers stay out. Each module record also carries the `behaviours` it
declares.

The document shape is described in `docs/specs/2026-09-15-grasp-design.md` at the repo
root under "Index JSON".

## Tests

```
mix test       # unit tests
mix test.all   # unit tests plus the integration test, which runs mix grasp.index
               # against test/fixtures/sample_app in a subprocess
```

`mix test` excludes the `:integration` tag, so it needs no fixture deps and no
subprocess compile. `mix test.all` is `mix test --include integration`.
