locals_without_parens = [grasp: 1, grasp: 2]

[
  import_deps: [:phoenix, :phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens],
  # test/fixtures/sample_app is a project of its own that the indexer reads: the tests pin
  # the line and column of what it declares, so it is formatted on its own terms, not here.
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib}/**/*.{heex,ex,exs}",
    "test/test_helper.exs",
    "test/fixtures/regenerate.exs",
    "test/{grasp,grasp_web,mix,support}/**/*.{heex,ex,exs}"
  ]
]
