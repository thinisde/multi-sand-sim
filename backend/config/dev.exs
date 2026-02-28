import Config

config :backend, BackendWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_change_me",
  watchers: []

config :backend, :cors_origins, ["http://localhost:5173"]
