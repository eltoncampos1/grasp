defmodule Grasp.MCP.SessionToolsTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.MCP.Tools
  alias Grasp.Session

  @greet "SampleApp.Greeter.greet/2"
  @wrap "SampleApp.Formatter.wrap/1"
  @show "SampleAppWeb.GreetController.show/2"
  @mailer "SampleApp.Workers.Mailer.perform/1"
  @shout "SampleApp.Formatter.shout/1"

  setup do
    %{session: "mcp-#{System.unique_integer([:positive])}"}
  end

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  defp run(tool, params) do
    {:reply, response, _frame} = tool.execute(params, %Frame{})
    response
  end

  defp card(body, id), do: Enum.find(body["cards"], &(&1["id"] == id))

  describe "set_cards" do
    test "replaces the forest with the cards described", %{session: session} do
      response =
        run(Tools.SetCards, %{
          session: session,
          cards: [
            %{key: "a", function_id: @show},
            %{
              key: "b",
              function_id: "SampleApp.Greeter.greet/1",
              parent_key: "a",
              highlight: %{call: @wrap}
            }
          ]
        })

      refute response.isError
      body = json!(response)

      assert body["focus"] == 1
      assert body["columns"] == [[1], [2]]
      assert card(body, 1)["function_id"] == @show
      assert card(body, 1)["callees"] == [2]

      assert card(body, 2) == %{
               "id" => 2,
               "function_id" => @greet,
               "callers" => [1],
               "callees" => [],
               "collapsed" => false,
               "position" => nil,
               "view" => "auto",
               "context" => "auto",
               "highlight" => %{"call" => @wrap},
               "group" => nil
             }

      assert body["edges"] == [
               %{
                 "from" => 1,
                 "to" => 2,
                 "target" => "SampleApp.Greeter.greet/1",
                 "color" => 0
               }
             ]

      refute Map.has_key?(body, "roots")
      refute Enum.any?(body["cards"], &Map.has_key?(&1, "parent_id"))
    end

    test "cards carrying titles are drawn as one section each", %{session: session} do
      response =
        run(Tools.SetCards, %{
          session: session,
          cards: [
            %{key: "a", function_id: @show, group: "Request"},
            %{
              key: "b",
              function_id: "SampleApp.Greeter.greet/1",
              parent_key: "a",
              group: "Request"
            },
            %{key: "c", function_id: @mailer, group: "Background"},
            %{key: "d", function_id: @shout}
          ]
        })

      refute response.isError
      body = json!(response)

      assert body["groups"] == [
               %{"id" => 1, "title" => "Request", "cards" => [1, 2]},
               %{"id" => 2, "title" => "Background", "cards" => [3]}
             ]

      assert body["sections"] == [
               %{"group" => 1, "columns" => [[1], [2]]},
               %{"group" => 2, "columns" => [[3]]},
               %{"group" => nil, "columns" => [[4]]}
             ]

      assert card(body, 2)["group"] == 1
      assert card(body, 4)["group"] == nil
    end

    test "the same function under two callers is one card with two edges", %{session: session} do
      response =
        run(Tools.SetCards, %{
          session: session,
          cards: [
            %{key: "a", function_id: @show},
            %{key: "b", function_id: "SampleApp.Greeter.greet/1", parent_key: "a"},
            %{key: "c", function_id: @mailer},
            %{key: "d", function_id: "SampleApp.Greeter.greet/1", parent_key: "c"}
          ]
        })

      refute response.isError
      body = json!(response)

      assert Enum.map(body["cards"], & &1["function_id"]) == [@show, @greet, @mailer]
      assert card(body, 2)["callers"] == [1, 3]
      assert Enum.map(body["edges"], &{&1["from"], &1["to"]}) == [{1, 2}, {3, 2}]
      assert body["columns"] == [[1, 3], [2]]
    end

    test "an unknown function is an error and leaves the forest alone", %{session: session} do
      run(Tools.SetCards, %{session: session, cards: [%{key: "a", function_id: @show}]})
      before = Session.get(session)

      response =
        run(Tools.SetCards, %{
          session: session,
          cards: [%{key: "a", function_id: @show}, %{key: "b", function_id: "Nope.f/0"}]
        })

      assert response.isError
      assert [%{"text" => text}] = response.content
      assert text =~ "unknown functions: Nope.f/0"
      assert Session.get(session) == before
    end

    test "a highlight the function contradicts is an error", %{session: session} do
      response =
        run(Tools.SetCards, %{
          session: session,
          cards: [%{key: "a", function_id: @show, highlight: %{call: @wrap}}]
        })

      assert response.isError
      assert [%{"text" => text}] = response.content
      assert text =~ "does not call"
    end
  end

  describe "open_card" do
    test "opens a root, then a child linked by the parent's call", %{session: session} do
      body = json!(run(Tools.OpenCard, %{session: session, function_id: @show}))

      assert body["card_id"] == 1
      assert body["columns"] == [[1]]
      assert card(body, 1)["callers"] == []

      body =
        json!(
          run(Tools.OpenCard, %{
            session: session,
            function_id: @greet,
            parent_card_id: 1,
            highlight: %{call: @wrap}
          })
        )

      assert body["card_id"] == 2
      assert card(body, 2)["callers"] == [1]
      assert card(body, 2)["highlight"] == %{"call" => @wrap}
      assert body["focus"] == 2

      assert body["edges"] == [
               %{
                 "from" => 1,
                 "to" => 2,
                 "target" => "SampleApp.Greeter.greet/1",
                 "color" => 0
               }
             ]
    end

    test "opening a child twice focuses the one already there", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @show})

      first =
        json!(run(Tools.OpenCard, %{session: session, function_id: @greet, parent_card_id: 1}))

      run(Tools.FocusCard, %{session: session, card_id: 1})

      second =
        json!(run(Tools.OpenCard, %{session: session, function_id: @greet, parent_card_id: 1}))

      assert second["card_id"] == first["card_id"]
      assert second["focus"] == first["card_id"]
      assert length(second["cards"]) == 2
      assert card(second, 1)["callees"] == [first["card_id"]]
      assert length(second["edges"]) == 1
    end

    test "an unknown parent card is an error", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @show})
      before = Session.get(session)

      response =
        run(Tools.OpenCard, %{session: session, function_id: @greet, parent_card_id: 7})

      assert response.isError
      assert [%{"text" => "unknown card: 7"}] = response.content
      assert Session.get(session) == before
    end

    test "an unknown function is an error", %{session: session} do
      response = run(Tools.OpenCard, %{session: session, function_id: "Nope.f/0"})

      assert response.isError
      assert [%{"text" => "unknown function: Nope.f/0"}] = response.content
    end
  end

  describe "highlight_card" do
    test "marks a range and clears it again", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @greet})

      body =
        json!(
          run(Tools.HighlightCard, %{session: session, card_id: 1, highlight: %{lines: [6, 8]}})
        )

      assert card(body, 1)["highlight"] == %{"lines" => [6, 8]}

      body = json!(run(Tools.HighlightCard, %{session: session, card_id: 1, highlight: %{}}))

      assert card(body, 1)["highlight"] == nil
    end

    test "a range outside the function is an error", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @wrap})

      response =
        run(Tools.HighlightCard, %{session: session, card_id: 1, highlight: %{lines: [1, 2]}})

      assert response.isError
    end

    test "an unknown card is an error", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @wrap})

      response =
        run(Tools.HighlightCard, %{session: session, card_id: 9, highlight: %{lines: [4, 5]}})

      assert response.isError
      assert [%{"text" => "unknown card: 9"}] = response.content
    end
  end

  describe "focus_card, close_card and get_session" do
    test "focus moves, close removes the card, and get_session reads the forest", %{
      session: session
    } do
      run(Tools.OpenCard, %{session: session, function_id: @show})
      run(Tools.OpenCard, %{session: session, function_id: @greet, parent_card_id: 1})

      body = json!(run(Tools.FocusCard, %{session: session, card_id: 1}))
      assert body["focus"] == 1

      assert json!(run(Tools.GetSession, %{session: session}))["focus"] == 1

      body = json!(run(Tools.CloseCard, %{session: session, card_id: 2}))
      assert card(body, 2) == nil
      assert card(body, 1)["callees"] == []
      assert body["edges"] == []
    end

    test "get_session answers an empty forest for a session nobody has opened", %{
      session: session
    } do
      assert json!(run(Tools.GetSession, %{session: session})) ==
               %{
                 "focus" => nil,
                 "cards" => [],
                 "edges" => [],
                 "groups" => [],
                 "sections" => [],
                 "columns" => []
               }
    end

    test "an unknown card is an error for both", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @show})

      assert run(Tools.FocusCard, %{session: session, card_id: 4}).isError
      assert run(Tools.CloseCard, %{session: session, card_id: 4}).isError
    end
  end

  describe "set_view" do
    test "swaps a modified card between its source and the diff", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @shout})

      body = json!(run(Tools.SetView, %{session: session, card_id: 1, view: "diff"}))
      assert card(body, 1)["view"] == "diff"

      body = json!(run(Tools.SetView, %{session: session, card_id: 1, view: "source"}))
      assert card(body, 1)["view"] == "source"
    end

    test "a function with nothing to compare has no diff view, but has a source one", %{
      session: session
    } do
      run(Tools.OpenCard, %{session: session, function_id: @greet})

      response = run(Tools.SetView, %{session: session, card_id: 1, view: "diff"})

      assert response.isError
      assert [%{"text" => text}] = response.content
      assert text == "no diff for " <> @greet

      refute run(Tools.SetView, %{session: session, card_id: 1, view: "source"}).isError
    end

    test "an unknown card is an error", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @shout})

      response = run(Tools.SetView, %{session: session, card_id: 9, view: "diff"})

      assert response.isError
      assert [%{"text" => "unknown card: 9"}] = response.content
    end

    test "context says how much of the diff is drawn, and is left alone when omitted", %{
      session: session
    } do
      run(Tools.OpenCard, %{session: session, function_id: @shout})

      body =
        json!(run(Tools.SetView, %{session: session, card_id: 1, view: "diff", context: "hunks"}))

      assert card(body, 1)["view"] == "diff"
      assert card(body, 1)["context"] == "hunks"

      body = json!(run(Tools.SetView, %{session: session, card_id: 1, view: "source"}))
      assert card(body, 1)["context"] == "hunks"

      body =
        json!(
          run(Tools.SetView, %{session: session, card_id: 1, view: "source", context: "auto"})
        )

      assert card(body, 1)["context"] == "auto"
    end

    test "a context the card has no name for is an error", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @shout})

      response =
        run(Tools.SetView, %{session: session, card_id: 1, view: "diff", context: "some"})

      assert response.isError
      assert [%{"text" => "unknown context: some"}] = response.content
    end

    test "a view the card has no name for is an error", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @shout})

      response = run(Tools.SetView, %{session: session, card_id: 1, view: "sideways"})

      assert response.isError
      assert [%{"text" => "unknown view: sideways"}] = response.content
    end
  end

  describe "group_cards and ungroup_cards" do
    test "a title frames the cards named, and ungrouping returns them", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @show})
      run(Tools.OpenCard, %{session: session, function_id: @greet, parent_card_id: 1})
      run(Tools.OpenCard, %{session: session, function_id: @mailer})

      body = json!(run(Tools.GroupCards, %{session: session, title: "Request", card_ids: [1, 2]}))

      assert body["groups"] == [%{"id" => 1, "title" => "Request", "cards" => [1, 2]}]

      assert body["sections"] == [
               %{"group" => 1, "columns" => [[1], [2]]},
               %{"group" => nil, "columns" => [[3]]}
             ]

      body = json!(run(Tools.UngroupCards, %{session: session, card_ids: [1, 2]}))

      assert body["groups"] == []
      assert body["sections"] == [%{"group" => nil, "columns" => [[1, 3], [2]]}]
      assert card(body, 1)["group"] == nil
    end

    test "an unknown card is an error and nothing moves", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @show})
      before = Session.get(session)

      response = run(Tools.GroupCards, %{session: session, title: "Request", card_ids: [1, 7]})

      assert response.isError
      assert [%{"text" => "unknown card: 7"}] = response.content
      assert Session.get(session) == before

      response = run(Tools.UngroupCards, %{session: session, card_ids: [7]})

      assert response.isError
      assert [%{"text" => "unknown card: 7"}] = response.content
    end

    test "no title frames the cards under a group of its own", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @show})
      run(Tools.OpenCard, %{session: session, function_id: @mailer})

      body = json!(run(Tools.GroupCards, %{session: session, card_ids: [1]}))

      assert body["groups"] == [%{"id" => 1, "title" => nil, "cards" => [1]}]

      body = json!(run(Tools.GroupCards, %{session: session, title: "   ", card_ids: [2]}))

      assert body["groups"] == [
               %{"id" => 1, "title" => nil, "cards" => [1]},
               %{"id" => 2, "title" => nil, "cards" => [2]}
             ]
    end
  end

  describe "rename_group" do
    test "the group takes the new title and keeps its cards", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @show})
      run(Tools.GroupCards, %{session: session, title: "Request", card_ids: [1]})

      body = json!(run(Tools.RenameGroup, %{session: session, group_id: 1, title: " Deposits "}))

      assert body["groups"] == [%{"id" => 1, "title" => "Deposits", "cards" => [1]}]
      assert card(body, 1)["group"] == 1
    end

    test "a blank or absent title leaves the group untitled", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @show})
      run(Tools.GroupCards, %{session: session, title: "Request", card_ids: [1]})

      body = json!(run(Tools.RenameGroup, %{session: session, group_id: 1, title: "   "}))

      assert body["groups"] == [%{"id" => 1, "title" => nil, "cards" => [1]}]

      run(Tools.RenameGroup, %{session: session, group_id: 1, title: "Deposits"})
      body = json!(run(Tools.RenameGroup, %{session: session, group_id: 1}))

      assert body["groups"] == [%{"id" => 1, "title" => nil, "cards" => [1]}]
    end

    test "an unknown group is an error and nothing moves", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @show})
      run(Tools.GroupCards, %{session: session, title: "Request", card_ids: [1]})
      before = Session.get(session)

      response = run(Tools.RenameGroup, %{session: session, group_id: 7, title: "Deposits"})

      assert response.isError
      assert [%{"text" => "unknown group: 7"}] = response.content
      assert Session.get(session) == before
    end
  end

  describe "session names" do
    test "a call naming no cards is an error, whatever the session" do
      name = "empty-#{System.unique_integer([:positive])}"

      for tool <- [Tools.GroupCards, Tools.UngroupCards] do
        response = run(tool, %{session: name, card_ids: []})

        assert response.isError
        assert [%{"text" => "card_ids must name at least one card"}] = response.content
      end
    end

    test "a name no session file could carry is refused rather than started" do
      response = run(Tools.GetSession, %{session: "PR 123"})

      assert response.isError

      assert [%{"text" => "session names are letters, digits, - and _, up to 40 characters"}] =
               response.content

      refute "PR 123" in Session.list()
    end
  end

  describe "input schemas" do
    test "name the session, the cards and the required ids" do
      # Anubis leaves a field's default out of the JSON schema, so the description carries it
      assert Tools.SetCards.input_schema()["properties"]["session"]["description"] =~ "default"

      # One rule, in the schema a client reads and in the error a refused name is answered
      # with.
      assert Tools.SetCards.input_schema()["properties"]["session"]["description"] =~
               Grasp.Session.Disk.name_rule()

      assert Tools.SetCards.input_schema()["required"] == ["cards"]
      assert "function_id" in Tools.OpenCard.input_schema()["required"]
      assert "card_id" in Tools.CloseCard.input_schema()["required"]
      assert "card_id" in Tools.SetView.input_schema()["required"]
      assert "view" in Tools.SetView.input_schema()["required"]
      assert Tools.GroupCards.input_schema()["required"] == ["card_ids"]
      assert Tools.UngroupCards.input_schema()["required"] == ["card_ids"]
      assert Tools.RenameGroup.input_schema()["required"] == ["group_id"]
      refute Tools.GetSession.input_schema()["required"]
    end
  end
end
