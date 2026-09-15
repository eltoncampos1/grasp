defmodule Grasp.IndexTest do
  use ExUnit.Case, async: true

  alias Grasp.Index

  defp document do
    %{
      "version" => 1,
      "generated_at" => "2026-09-15T10:00:00Z",
      "project" => %{"app" => "my_app", "root" => "/tmp/my_app", "elixirc_paths" => ["lib"]},
      "git" => nil,
      "modules" => [
        %{
          "name" => "MyApp.Wallets",
          "file" => "lib/my_app/wallets.ex",
          "line" => 1,
          "behaviours" => []
        }
      ],
      "entry_points" => [],
      "functions" => [
        function("MyApp.Wallets.credit/3", "MyApp.Wallets", "credit", 3, [2, 3], [
          %{
            "target" => "MyApp.Ledger.post/2",
            "kind" => "remote",
            "range" => %{"start" => [10, 5], "end" => [10, 16]}
          }
        ]),
        Map.put(
          function("MyApp.Wallets.debit/3", "MyApp.Wallets", "debit", 3, [3], []),
          "span",
          %{"start_line" => 5, "end_line" => 6}
        ),
        function(
          "MyAppWeb.WalletController.create/2",
          "MyAppWeb.WalletController",
          "create",
          2,
          [2],
          [
            %{
              "target" => "MyApp.Wallets.credit/2",
              "kind" => "remote",
              "range" => %{"start" => [8, 5], "end" => [8, 19]}
            }
          ],
          [%{"target" => "MyApp.Wallets.debit/3", "kind" => "remote", "line" => 12}]
        ),
        Map.put(
          function("MyApp.Ledger.post/2", "MyApp.Ledger", "post", 2, [2], []),
          "change",
          "modified"
        )
      ]
    }
  end

  defp function(id, module, name, arity, arities, calls, hidden \\ []) do
    %{
      "id" => id,
      "module" => module,
      "name" => name,
      "arity" => arity,
      "arities" => arities,
      "kind" => "def",
      "file" => "lib/x.ex",
      "span" => %{"start_line" => 1, "end_line" => 3},
      "source" => "def #{name}",
      "calls" => calls,
      "hidden_calls" => hidden,
      "change" => "unchanged",
      "base_source" => nil,
      "removed" => false
    }
  end

  setup do
    {:ok, index} = Index.from_document(document())
    %{index: index}
  end

  test "fetch_function/2 finds by canonical id and by default-argument arity", %{index: index} do
    assert {:ok, %{"id" => "MyApp.Wallets.credit/3"}} =
             Index.fetch_function(index, "MyApp.Wallets.credit/3")

    assert {:ok, %{"id" => "MyApp.Wallets.credit/3"}} =
             Index.fetch_function(index, "MyApp.Wallets.credit/2")

    assert :error = Index.fetch_function(index, "MyApp.Wallets.credit/9")
  end

  test "callers/2 inverts calls and hidden calls, resolving aliases", %{index: index} do
    assert Index.callers(index, "MyApp.Wallets.credit/3") == [
             "MyAppWeb.WalletController.create/2"
           ]

    assert Index.callers(index, "MyApp.Wallets.debit/3") == ["MyAppWeb.WalletController.create/2"]
    assert Index.callers(index, "MyApp.Ledger.post/2") == ["MyApp.Wallets.credit/3"]
    assert Index.callers(index, "Nobody.calls/0") == []
  end

  test "callees/2 lists resolved targets including hidden calls", %{index: index} do
    assert Index.callees(index, "MyAppWeb.WalletController.create/2") == [
             "MyApp.Wallets.credit/3",
             "MyApp.Wallets.debit/3"
           ]

    assert Index.callees(index, "MyApp.Wallets.credit/2") == ["MyApp.Ledger.post/2"]
  end

  test "search/3 ranks exact, then substring, then subsequence matches", %{index: index} do
    assert ids(Index.search(index, "MyApp.Wallets.debit/3")) == ["MyApp.Wallets.debit/3"]
    assert ids(Index.search(index, "credit")) == ["MyApp.Wallets.credit/3"]
    assert ["MyApp.Wallets.credit/3" | _] = ids(Index.search(index, "walcre"))

    assert ids(Index.search(index, "wallets")) == [
             "MyApp.Wallets.debit/3",
             "MyApp.Wallets.credit/3"
           ]

    assert ids(Index.search(index, "wallet")) == [
             "MyApp.Wallets.debit/3",
             "MyApp.Wallets.credit/3",
             "MyAppWeb.WalletController.create/2"
           ]

    assert Index.search(index, "zzzzzz") == []
    assert Index.search(index, "   ") == []
    assert length(Index.search(index, "a", 2)) == 2
  end

  test "functions_in_module/2 lists a module's functions in source order", %{index: index} do
    assert ids(Index.functions_in_module(index, "MyApp.Wallets")) == [
             "MyApp.Wallets.credit/3",
             "MyApp.Wallets.debit/3"
           ]

    assert Index.functions_in_module(index, "Nope") == []
  end

  test "changed_functions/1 returns everything not unchanged", %{index: index} do
    assert ids(Index.changed_functions(index)) == ["MyApp.Ledger.post/2"]
  end

  test "load/1 reads a document from disk", %{index: index} do
    path = tmp_path()
    File.write!(path, Jason.encode!(document()))

    assert {:ok, loaded} = Index.load(path)
    assert Index.functions(loaded) == Index.functions(index)

    assert Index.modules(loaded) == [
             %{
               "name" => "MyApp.Wallets",
               "file" => "lib/my_app/wallets.ex",
               "line" => 1,
               "behaviours" => []
             }
           ]

    assert {:error, _} = Index.load(path <> ".missing")
  end

  test "load/1 reports a document version it cannot read" do
    path = tmp_path()
    File.write!(path, Jason.encode!(%{"version" => 2, "functions" => []}))

    assert Index.load(path) == {:error, {:unsupported_document, 2}}
  end

  test "from_document/1 rejects a document that is not an index" do
    assert Index.from_document(%{}) == {:error, {:unsupported_document, nil}}
  end

  test "load/1 reports a top-level document that is not an object" do
    path = tmp_path()
    File.write!(path, Jason.encode!([]))

    assert Index.load(path) == {:error, {:unsupported_document, nil}}
  end

  test "from_document/1 reports a function record that is not an object" do
    document = Map.update!(document(), "functions", &["not a record" | &1])

    assert {:error, {:invalid_record, _}} = Index.from_document(document)
  end

  test "from_document/1 falls back to arity for a record with no arities" do
    record = document() |> Map.fetch!("functions") |> hd() |> Map.delete("arities")
    document = Map.put(document(), "functions", [record])

    assert {:ok, index} = Index.from_document(document)

    assert {:ok, %{"id" => "MyApp.Wallets.credit/3"}} =
             Index.fetch_function(index, "MyApp.Wallets.credit/3")

    assert :error = Index.fetch_function(index, "MyApp.Wallets.credit/2")
  end

  defp tmp_path do
    path = Path.join(System.tmp_dir!(), "grasp-index-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp ids(records), do: Enum.map(records, & &1["id"])
end
