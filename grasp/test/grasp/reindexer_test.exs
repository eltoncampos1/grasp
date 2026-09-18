defmodule Grasp.ReindexerTest do
  # The compiler options are global to the VM and the index store is a singleton, so this
  # module owns both for as long as it runs and puts them back afterwards.
  use ExUnit.Case, async: false

  alias Grasp.Index.Tracer

  @moduletag :tmp_dir

  @fixture Path.expand("../fixtures/index.json", __DIR__)
  @probe "lib/sample_app/probe.ex"

  setup %{tmp_dir: tmp_dir} do
    tracers = Code.get_compiler_option(:tracers)
    parser = Code.get_compiler_option(:parser_options)
    store_path = Grasp.IndexStore.path()

    on_exit(fn ->
      Code.put_compiler_option(:tracers, tracers)
      Code.put_compiler_option(:parser_options, parser)
      Grasp.IndexStore.load(store_path)
    end)

    document =
      @fixture |> File.read!() |> Jason.decode!() |> put_in(["project", "root"], tmp_dir)

    index_path = Path.join(tmp_dir, "index.json")
    File.write!(index_path, Jason.encode!(document, pretty: true))
    :ok = Grasp.IndexStore.load(index_path)

    start_supervised!({Grasp.Reindexer, index_path: index_path, flush_ms: 50})

    %{index_path: index_path, root: tmp_dir}
  end

  test "installs the tracer into the running VM's compiler options" do
    assert Tracer in Code.get_compiler_option(:tracers)
    assert Code.get_compiler_option(:parser_options)[:columns] == true
  end

  test "a compile lands in the index file and in the store", %{index_path: index_path, root: root} do
    module = compile(root, "Enum.map(list, &Integer.to_string/1)")
    id = "#{inspect(module)}.run/1"

    record = await(fn -> fetch(index_path, id) end)
    assert record["file"] == @probe
    assert record["kind"] == "def"
    assert "Enum.map/2" in Enum.map(record["calls"], & &1["target"])
    assert record["change"] == "added"

    assert {:ok, ^record} = Grasp.Index.fetch_function(Grasp.IndexStore.get(), id)
  end

  test "leaves the records of every other file alone", %{index_path: index_path, root: root} do
    before = @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("functions")
    module = compile(root, "Enum.count(list)")

    await(fn -> fetch(index_path, "#{inspect(module)}.run/1") end)
    document = read(index_path)

    assert Enum.reject(document["functions"], &(&1["file"] == @probe)) == before
    assert document["project"]["root"] == root

    assert document["git"] == %{
             "base_ref" => "main",
             "base_sha" => "1111111",
             "branch" => "feature",
             "head" => "0000000"
           }
  end

  # The module is compiled from a file that exists on disk, because the update re-extracts
  # the files the compiler reported: a name unique to the run keeps the beam this test
  # loads from colliding with another's.
  defp compile(root, body) do
    module = Module.concat([SampleApp, "Probe#{System.unique_integer([:positive])}"])

    source = """
    defmodule #{inspect(module)} do
      @moduledoc "A module compiled while the reindexer is watching."

      @doc "Runs."
      def run(list), do: #{body}
    end
    """

    path = Path.join(root, @probe)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    Code.compile_string(source, path)
    module
  end

  defp await(fun, remaining \\ 2_000) do
    case fun.() do
      nil when remaining > 0 ->
        Process.sleep(20)
        await(fun, remaining - 20)

      nil ->
        flunk("the index was not updated within two seconds")

      value ->
        value
    end
  end

  defp fetch(index_path, id) do
    index_path |> read() |> Map.fetch!("functions") |> Enum.find(&(&1["id"] == id))
  end

  defp read(index_path), do: index_path |> File.read!() |> Jason.decode!()
end
