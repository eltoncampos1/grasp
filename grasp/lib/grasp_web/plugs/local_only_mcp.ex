defmodule GraspWeb.Plugs.LocalOnlyMcp do
  @moduledoc """
  The MCP transport behind `GraspWeb.Plugs.LocalOnly`.

  A host mounts Grasp with one router macro, which leaves no place for a pipeline of Grasp's
  own; pairing the two plugs here keeps the loopback check in front of the transport wherever
  the macro is called.
  """

  @behaviour Plug

  @transport Anubis.Server.Transport.StreamableHTTP.Plug

  @impl true
  def init(opts), do: {GraspWeb.Plugs.LocalOnly.init([]), @transport.init(opts)}

  @impl true
  def call(%Plug.Conn{} = conn, {local_opts, transport_opts}) do
    case GraspWeb.Plugs.LocalOnly.call(conn, local_opts) do
      %Plug.Conn{halted: true} = conn -> conn
      %Plug.Conn{} = conn -> @transport.call(conn, transport_opts)
    end
  end
end
