defmodule Grasp.MCP.Tools do
  @moduledoc "Shared plumbing for the MCP tools: the loaded index, session cards, and JSON/error replies."

  alias Anubis.Server.Response
  alias Grasp.Session
  alias Grasp.Session.Forest

  @doc "The loaded index, or the tool error every index-reading tool replies with when none is loaded."
  @spec index() :: {:ok, Grasp.Index.t()} | {:error, Response.t()}
  def index, do: index(Grasp.IndexStore.get())

  @doc "`index/0` over a store value, so the no-index reply can be exercised without a store."
  @spec index(Grasp.Index.t() | nil) :: {:ok, Grasp.Index.t()} | {:error, Response.t()}
  def index(nil), do: {:error, Response.error(Response.tool(), "no index loaded")}
  def index(%Grasp.Index{} = index), do: {:ok, index}

  @doc """
  The card `card_id` of the session named `session`, or the message a tool answers with when
  the session holds no such card.

  Starts the session if it is not running, so every card-addressing tool reads the same
  empty forest whether or not anyone has opened the session yet.
  """
  @spec fetch_card(Session.name(), Forest.id()) :: {:ok, Forest.card()} | {:error, String.t()}
  def fetch_card(session, card_id) do
    :ok = Session.ensure(session)

    case Forest.card(Session.get(session), card_id) do
      nil -> {:error, "unknown card: #{card_id}"}
      card -> {:ok, card}
    end
  end

  @doc """
  Every card in `card_ids`, or the message naming the first id the session holds no card for.

  A tool taking a list of ids answers for all of them before it changes anything, so a call
  naming one card that has since closed leaves the graph as it was rather than half moved.
  """
  @spec fetch_cards(Session.name(), [Forest.id()]) ::
          {:ok, [Forest.card()]} | {:error, String.t()}
  def fetch_cards(session, card_ids) when is_list(card_ids) do
    Enum.reduce_while(card_ids, {:ok, []}, fn id, {:ok, cards} ->
      case fetch_card(session, id) do
        {:ok, card} -> {:cont, {:ok, [card | cards]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, cards} -> {:ok, Enum.reverse(cards)}
      {:error, _message} = error -> error
    end
  end

  @doc """
  The record for the function id `id`, or the message a tool answers an unknown id with.

  Any arity a definition with default arguments answers to resolves to that definition, so
  `record["id"]` is the canonical id the graph and the cards are keyed by.
  """
  @spec fetch_function(Grasp.Index.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def fetch_function(%Grasp.Index{} = index, id) do
    case Grasp.Index.fetch_function(index, id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, "unknown function: #{id}"}
    end
  end

  @doc "A filter term folded to lower case, passing `nil` — an absent term — through."
  @spec downcase(String.t() | nil) :: String.t() | nil
  def downcase(nil), do: nil
  def downcase(string) when is_binary(string), do: String.downcase(string)

  @doc "A JSON tool reply."
  @spec reply(term(), term()) :: {:reply, Response.t(), term()}
  def reply(frame, data), do: {:reply, Response.json(Response.tool(), data), frame}

  @doc "A tool error reply, from a message or from a response an earlier step already built."
  @spec error(term(), Response.t() | String.t()) :: {:reply, Response.t(), term()}
  def error(frame, %Response{} = response), do: {:reply, response, frame}

  def error(frame, message) when is_binary(message),
    do: {:reply, Response.error(Response.tool(), message), frame}
end
