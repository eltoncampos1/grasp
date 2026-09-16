defmodule Grasp.MCP.SessionToolsTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.MCP.Tools
  alias Grasp.Session

  @greet "SampleApp.Greeter.greet/2"
  @wrap "SampleApp.Formatter.wrap/1"
  @show "SampleAppWeb.GreetController.show/2"

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

      assert body["roots"] == [1]
      assert body["focus"] == 1
      assert card(body, 1)["function_id"] == @show
      assert card(body, 1)["children"] == [2]

      assert card(body, 2) == %{
               "id" => 2,
               "function_id" => @greet,
               "parent_id" => 1,
               "children" => [],
               "opened_by" => "SampleApp.Greeter.greet/1",
               "collapsed" => false,
               "highlight" => %{"call" => @wrap}
             }
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
      assert body["roots"] == [1]

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
      assert card(body, 2)["opened_by"] == "SampleApp.Greeter.greet/1"
      assert card(body, 2)["highlight"] == %{"call" => @wrap}
      assert body["focus"] == 2
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
      assert card(body, 1)["children"] == []
    end

    test "get_session answers an empty forest for a session nobody has opened", %{
      session: session
    } do
      assert json!(run(Tools.GetSession, %{session: session})) ==
               %{"roots" => [], "focus" => nil, "cards" => []}
    end

    test "an unknown card is an error for both", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @show})

      assert run(Tools.FocusCard, %{session: session, card_id: 4}).isError
      assert run(Tools.CloseCard, %{session: session, card_id: 4}).isError
    end
  end

  describe "input schemas" do
    test "name the session, the cards and the required ids" do
      # Anubis leaves a field's default out of the JSON schema, so the description carries it
      assert Tools.SetCards.input_schema()["properties"]["session"]["description"] =~ "default"
      assert Tools.SetCards.input_schema()["required"] == ["cards"]
      assert "function_id" in Tools.OpenCard.input_schema()["required"]
      assert "card_id" in Tools.CloseCard.input_schema()["required"]
      refute Tools.GetSession.input_schema()["required"]
    end
  end
end
