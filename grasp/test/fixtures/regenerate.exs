# Rebuilds test/fixtures/index.json from a freshly indexed sample app.
#
#     cd grasp_index/test/fixtures/sample_app && mix grasp.index --out /tmp/index.json
#     cd grasp && mix run test/fixtures/regenerate.exs /tmp/index.json
#
# The fixture is a real index document with a hand-made pull request painted on top: the
# indexer is run without `--base`, so nothing it writes says what a branch changed. This
# script takes the fresh document and carries the hand-made facts across:
#
#   * `project.root`, which the machine that ran the indexer would otherwise write as an
#     absolute path of its own, and which viewer tests read as `/tmp/sample_app`;
#   * the whole `git` block, naming the base ref, base sha, branch and head the fixture's
#     pull request is against;
#   * `generated_at`, a fixed instant so a regeneration shows only the records that moved;
#   * every record's `change`, `base_source` and `removed`, matched by id;
#   * every record the old fixture holds and the fresh document does not — a function the
#     branch removed exists only as a hand-made record, and reindexing cannot find it.
#
# A record the fresh document adds keeps the indexer's own `change: "unchanged"`.

[fresh_path] = System.argv()
fixture_path = Path.join(__DIR__, "index.json")

fresh = fresh_path |> File.read!() |> Jason.decode!()
old = fixture_path |> File.read!() |> Jason.decode!()

old_by_id = Map.new(old["functions"], &{&1["id"], &1})
fresh_ids = MapSet.new(fresh["functions"], & &1["id"])

merged =
  Enum.map(fresh["functions"], fn record ->
    case Map.fetch(old_by_id, record["id"]) do
      {:ok, previous} -> Map.merge(record, Map.take(previous, ~w(change base_source removed)))
      :error -> record
    end
  end)

kept = Enum.reject(old["functions"], &MapSet.member?(fresh_ids, &1["id"]))

document =
  fresh
  |> Map.put("functions", merged ++ kept)
  |> Map.put("generated_at", old["generated_at"])
  |> Map.put("git", old["git"])
  |> put_in(["project", "root"], old["project"]["root"])

File.write!(fixture_path, Jason.encode!(document, pretty: true))

IO.puts("#{fixture_path}: #{length(document["functions"])} functions (#{length(kept)} kept)")
