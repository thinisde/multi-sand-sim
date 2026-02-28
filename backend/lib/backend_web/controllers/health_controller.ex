defmodule BackendWeb.HealthController do
  use Phoenix.Controller, formats: [:json]

  def index(conn, _params) do
    json(conn, %{status: "ok", topic: "global"})
  end
end
