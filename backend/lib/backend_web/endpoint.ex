defmodule BackendWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :backend

  socket("/socket", BackendWeb.UserSocket,
    websocket: true,
    longpoll: false
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(BackendWeb.CORSPlug)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Phoenix.json_library()
  )

  plug(BackendWeb.Router)
end
