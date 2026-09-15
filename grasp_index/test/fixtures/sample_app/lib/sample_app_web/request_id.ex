defmodule SampleAppWeb.RequestId do
  @moduledoc "A plain plug."
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts), do: Plug.Conn.put_resp_header(conn, "x-request-id", "1")
end
