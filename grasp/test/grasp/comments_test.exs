defmodule Grasp.CommentsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Grasp.Comments

  setup do
    %{function_id: "Test.Fn#{System.unique_integer([:positive])}.run/0"}
  end

  test "add/1 opens a thread, broadcasts and reads back", %{function_id: function_id} do
    :ok = Comments.subscribe()
    body = unique("the guard is unreachable")

    assert {:ok, thread} =
             Comments.add(%{
               function_id: function_id,
               side: "new",
               line: 12,
               body: "  #{body}  ",
               author: "human",
               snippet: "def run do"
             })

    assert_receive :comments_changed

    assert %{
             function_id: ^function_id,
             side: "new",
             line: 12,
             snippet: "def run do",
             author: "human",
             resolved: false,
             replies: []
           } = thread

    assert thread.body == body
    assert {:ok, ^thread} = Comments.fetch(thread.id)
    assert Comments.list(function_id: function_id) == [thread]
  end

  test "a thread is written to the store's file", %{function_id: function_id} do
    {:ok, thread} = add(function_id, %{})

    assert path = Comments.path()
    assert {:ok, {threads, next_id, 0}} = path |> File.read!() |> Comments.decode()
    assert next_id > thread.id
    assert Enum.any?(threads, &(&1.id == thread.id and &1.body == thread.body))
  end

  test "list/1 filters by function and hides resolved threads", %{function_id: function_id} do
    {:ok, first} = add(function_id, %{line: 1})
    {:ok, second} = add(function_id, %{line: 2})
    {:ok, other} = add(function_id <> "x", %{})

    assert Comments.list(function_id: function_id) == [first, second]
    assert {:ok, resolved} = Comments.set_resolved(first.id, true)
    assert resolved.resolved
    assert Comments.list(function_id: function_id) == [second]

    assert Comments.list(function_id: function_id, include_resolved: true) == [resolved, second]
    assert {:ok, _reopened} = Comments.set_resolved(first.id, false)
    refute other in Comments.list(function_id: function_id)
  end

  test "by_function/0 groups every thread, resolved included", %{function_id: function_id} do
    {:ok, first} = add(function_id, %{line: 1})
    {:ok, second} = add(function_id, %{line: 2})
    {:ok, second} = Comments.set_resolved(second.id, true)

    assert Comments.by_function()[function_id] == [first, second]
  end

  test "reply/2 appends replies with ids of their own", %{function_id: function_id} do
    {:ok, thread} = add(function_id, %{})
    body = unique("agreed")

    assert {:ok, replied} = Comments.reply(thread.id, %{body: body, author: "agent"})

    assert [%{id: reply_id, author: "agent", body: ^body, created_at: created_at}] =
             replied.replies

    assert reply_id != thread.id
    assert {:ok, _datetime, _offset} = DateTime.from_iso8601(created_at)

    assert {:ok, replied} = Comments.reply(thread.id, %{body: unique("and"), author: "human"})
    assert [_first, %{id: second_id}] = replied.replies
    assert second_id != reply_id

    assert :ok = Comments.delete_reply(thread.id, reply_id)
    assert {:ok, %{replies: [%{id: ^second_id}]}} = Comments.fetch(thread.id)
  end

  test "delete/1 removes a thread and ignores unknown ids", %{function_id: function_id} do
    {:ok, thread} = add(function_id, %{})

    assert :ok = Comments.delete(thread.id)
    assert Comments.fetch(thread.id) == :error
    assert Comments.list(function_id: function_id) == []
    assert :ok = Comments.delete(thread.id)
    assert :ok = Comments.delete_reply(thread.id, 1)
  end

  test "ids are never reused", %{function_id: function_id} do
    {:ok, thread} = add(function_id, %{})
    :ok = Comments.delete(thread.id)

    {:ok, later} = add(function_id, %{})
    assert later.id > thread.id
  end

  test "add/1 rejects anything but a well-formed comment", %{function_id: function_id} do
    valid = %{
      function_id: function_id,
      side: "new",
      line: 1,
      body: unique("look here"),
      author: "human"
    }

    assert {:ok, _thread} = Comments.add(valid)
    assert Comments.add(%{valid | function_id: :atom}) == {:error, :invalid}
    assert Comments.add(%{valid | side: "both"}) == {:error, :invalid}
    assert Comments.add(%{valid | line: 0}) == {:error, :invalid}
    assert Comments.add(%{valid | line: "1"}) == {:error, :invalid}
    assert Comments.add(%{valid | author: "robot"}) == {:error, :invalid}
    assert Comments.add(%{valid | body: "   "}) == {:error, :invalid}
    assert Comments.add(Map.delete(valid, :body)) == {:error, :invalid}
    assert Comments.add(%{}) == {:error, :invalid}
  end

  test "reply/2 reports an unknown thread apart from an invalid body", %{function_id: function_id} do
    {:ok, thread} = add(function_id, %{})

    assert Comments.reply(thread.id, %{body: "", author: "human"}) == {:error, :invalid}

    assert Comments.reply(thread.id, %{body: unique("hi"), author: "nobody"}) ==
             {:error, :invalid}

    assert Comments.reply(0, %{body: unique("hi"), author: "human"}) == {:error, :unknown}
    assert Comments.set_resolved(0, true) == {:error, :unknown}
  end

  test "encode/2 and decode/1 round-trip the document" do
    threads = [
      %{
        id: 1,
        function_id: "SampleApp.Greeter.greet/2",
        side: "new",
        line: 8,
        snippet: "def greet(name, loud? \\\\ false) do",
        body: "why a default here?",
        author: "human",
        created_at: "2026-09-17T09:00:00Z",
        resolved: false,
        github: %{
          id: 55_123,
          url: "https://github.com/acme/sample_app/pull/42#discussion_r55123",
          published_at: "2026-09-17T09:03:00Z"
        },
        replies: [
          %{
            id: 2,
            author: "agent",
            body: "callers rely on it",
            created_at: "2026-09-17T09:01:00Z"
          }
        ]
      },
      %{
        id: 3,
        function_id: "SampleApp.Formatter.shout/1",
        side: "old",
        line: 1,
        snippet: nil,
        body: "the base read better",
        author: "agent",
        created_at: "2026-09-17T09:02:00Z",
        resolved: true,
        github: nil,
        replies: []
      }
    ]

    document = Comments.encode(threads, 4)

    assert document =~ "\n"
    assert Comments.decode(document) == {:ok, {threads, 4, 0}}
  end

  test "decode/1 corrects a counter that lags behind the ids it hands out" do
    document = ~s({"version": 1, "next_id": 2, "comments": #{comments_json()}})

    assert {:ok, {[thread], next_id, 0}} = Comments.decode(document)
    assert thread.id == 7
    assert next_id == 10
  end

  test "decode/1 keeps the entries it can read and counts the rest" do
    document =
      ~s({"version": 1, "next_id": 20, "comments": [{"id": "x"}, #{one_comment()}, null]})

    assert {:ok, {[thread], 20, 2}} = Comments.decode(document)
    assert thread.id == 7
  end

  test "decode/1 refuses a document it cannot read" do
    assert {:error, _reason} = Comments.decode("not json")
    assert {:error, _reason} = Comments.decode(~s({"version": 2, "next_id": 1, "comments": []}))
    assert {:error, _reason} = Comments.decode(~s({"version": 1, "next_id": 1}))

    assert Comments.decode(~s({"version": 1, "next_id": 1, "comments": [{}]})) ==
             {:ok, {[], 1, 1}}

    assert Comments.decode(~s({"version": 1, "next_id": 1, "comments": []})) == {:ok, {[], 1, 0}}
  end

  test "snippet/3 reads the line off the record it is written on" do
    record = record("SampleApp.Formatter.shout/1")

    assert record["span"]["start_line"] == 8

    assert Comments.snippet(record, "new", 8) ==
             "@doc \"Upcases text and adds an exclamation mark.\""

    assert Comments.snippet(record, "new", 10) ==
             "def shout(text), do: String.upcase(text) <> \"!\""

    assert Comments.snippet(record, "new", 7) == nil
    assert Comments.snippet(record, "new", 11) == nil

    assert Comments.snippet(record, "old", 1) ==
             "@doc \"Upcases text and adds an exclamation mark.\""

    assert Comments.snippet(record, "old", 3) == "def shout(text), do: text"

    assert Comments.snippet(record("SampleApp.Greeter.greet/2"), "old", 1) == nil
    assert Comments.snippet(nil, "new", 1) == nil
  end

  test "mark_published/2 stamps a thread with its GitHub review comment", %{
    function_id: function_id
  } do
    {:ok, thread} = add(function_id, %{})
    assert thread.github == nil

    url = "https://github.com/acme/sample_app/pull/42#discussion_r55123"
    assert {:ok, published} = Comments.mark_published(thread.id, %{id: 55_123, url: url})

    assert %{id: 55_123, url: ^url, published_at: published_at} = published.github
    assert {:ok, _datetime, _offset} = DateTime.from_iso8601(published_at)
    assert {:ok, ^published} = Comments.fetch(thread.id)
  end

  test "mark_published/2 does not know an id no thread holds" do
    assert Comments.mark_published(9_999_999, %{id: 1, url: "https://example.test/r1"}) ==
             {:error, :unknown}
  end

  test "the github stamp survives encode and decode", %{function_id: function_id} do
    {:ok, thread} = add(function_id, %{})

    {:ok, published} =
      Comments.mark_published(thread.id, %{id: 77, url: "https://example.test/r77"})

    document = Comments.encode([published], published.id + 1)
    assert {:ok, {[decoded], _next_id, 0}} = Comments.decode(document)
    assert decoded == published
  end

  test "a thread written without a github stamp decodes with none", %{function_id: function_id} do
    {:ok, thread} = add(function_id, %{})
    document = Comments.encode([thread], thread.id + 1)

    assert {:ok, {[decoded], _next_id, 0}} = Comments.decode(document)
    assert decoded.github == nil
    refute document |> Jason.decode!() |> Map.fetch!("comments") |> hd() |> Map.has_key?("github")
  end

  test "a thread whose github stamp is malformed is dropped" do
    comment =
      String.replace(
        one_comment(),
        ~s("resolved": false),
        ~s("github": {"id": "x"}, "resolved": false)
      )

    document = ~s({"version": 1, "next_id": 9, "comments": [) <> comment <> "]}"

    assert {:ok, {[], _next_id, 1}} = Comments.decode(document)
  end

  @tag :tmp_dir
  test "a store keeps what it can read of a damaged file and moves the file aside", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "comments.json")

    File.write!(
      path,
      ~s({"version": 1, "next_id": 9, "comments": [{"id": "x"}, #{one_comment()}]})
    )

    log =
      capture_log(fn ->
        store = start_isolated(path)

        assert [%{id: 7, body: "worth a look"}] = Comments.list([], store)
        assert {:ok, _thread} = Comments.add(isolated_attrs(), store)
      end)

    assert log =~ "dropped 1 unreadable entry"
    assert File.exists?(path <> ".corrupt")
    assert {:ok, {threads, _next_id, 0}} = path |> File.read!() |> Comments.decode()
    assert Enum.map(threads, & &1.id) == [7, 10]
  end

  @tag :tmp_dir
  test "a store that could not read its file at all keeps the file aside", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "comments.json")
    File.write!(path, "{not json")

    log =
      capture_log(fn ->
        store = start_isolated(path)

        assert Comments.list([], store) == []
        assert {:ok, _thread} = Comments.add(isolated_attrs(), store)
      end)

    assert log =~ "could not read comments"
    assert File.read!(path <> ".corrupt") == "{not json"
    assert {:ok, {[%{id: 1}], 2, 0}} = path |> File.read!() |> Comments.decode()
  end

  # A store of this test's own: the application's reads the project's file, and these tests
  # need a file they can damage.
  defp start_isolated(path) do
    name = :"comments_#{System.unique_integer([:positive])}"
    start_supervised!({Comments, [path: path, name: name]})
    name
  end

  defp isolated_attrs do
    %{function_id: "Test.Isolated.run/0", side: "new", line: 1, body: "later", author: "human"}
  end

  defp comments_json, do: "[" <> one_comment() <> "]"

  defp one_comment do
    ~s({"id": 7, "function_id": "Test.Fn.run/0", "side": "new", "line": 1, "snippet": null,) <>
      ~s( "body": "worth a look", "author": "human", "created_at": "2026-09-17T09:00:00Z",) <>
      ~s( "resolved": false, "replies": [{"id": 9, "author": "agent", "body": "ok",) <>
      ~s( "created_at": "2026-09-17T09:01:00Z"}]})
  end

  defp add(function_id, attrs) do
    %{
      function_id: function_id,
      side: "new",
      line: 1,
      body: unique("worth a look"),
      author: "human",
      snippet: nil
    }
    |> Map.merge(attrs)
    |> Comments.add()
  end

  defp unique(body), do: "#{body} #{System.unique_integer([:positive])}"

  defp record(id) do
    {:ok, record} = Grasp.Index.fetch_function(Grasp.IndexStore.get(), id)
    record
  end
end
