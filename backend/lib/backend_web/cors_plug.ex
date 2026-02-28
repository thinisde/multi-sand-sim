defmodule BackendWeb.CORSPlug do
  import Plug.Conn

  @allow_headers "content-type,authorization"
  @allow_methods "GET,POST,OPTIONS"

  def init(opts), do: opts

  def call(conn, _opts) do
    origin = get_req_header(conn, "origin") |> List.first()
    cors_origins = Application.get_env(:backend, :cors_origins, [])

    conn =
      conn
      |> maybe_put_allow_origin(origin, cors_origins)
      |> put_resp_header("access-control-allow-credentials", "true")
      |> put_resp_header("access-control-allow-headers", @allow_headers)
      |> put_resp_header("access-control-allow-methods", @allow_methods)
      |> put_resp_header("vary", "origin")

    if conn.method == "OPTIONS" do
      conn
      |> send_resp(204, "")
      |> halt()
    else
      conn
    end
  end

  defp maybe_put_allow_origin(conn, nil, _cors_origins), do: conn

  defp maybe_put_allow_origin(conn, origin, cors_origins) do
    if origin in cors_origins do
      put_resp_header(conn, "access-control-allow-origin", origin)
    else
      conn
    end
  end
end
