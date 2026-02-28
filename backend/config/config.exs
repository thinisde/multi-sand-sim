import Config

config :backend,
  generators: [timestamp_type: :utc_datetime]

config :backend, BackendWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [json: BackendWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Backend.PubSub,
  live_view: [signing_salt: "CHANGE_ME"]

config :backend, :cors_origins, ["http://localhost:5173"]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
