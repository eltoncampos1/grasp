defmodule GraspWeb.ErrorHTML do
  @moduledoc "Renders plain status messages for HTTP errors."

  use GraspWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
