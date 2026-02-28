import Config

config :backend, BackendWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false,
  secret_key_base: "test_secret_key_base_change_me",
  check_origin: false

config :logger, level: :warning
