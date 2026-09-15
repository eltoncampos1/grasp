defmodule SampleAppWeb.Endpoint do
  @moduledoc "Minimal endpoint so the router compiles."
  use Phoenix.Endpoint, otp_app: :sample_app
  plug(SampleAppWeb.Router)
end
