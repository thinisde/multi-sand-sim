defmodule BackendWeb.Router do
  use Phoenix.Router

  scope "/", BackendWeb do
    get("/", HealthController, :index)
  end
end
