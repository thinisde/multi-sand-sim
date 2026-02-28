import Config

dotenv_path = Path.expand("../../.env", __DIR__)

strip_wrapping_quotes = fn value ->
  cond do
    String.length(value) >= 2 and String.starts_with?(value, "\"") and
        String.ends_with?(value, "\"") ->
      String.slice(value, 1, String.length(value) - 2)

    String.length(value) >= 2 and String.starts_with?(value, "'") and
        String.ends_with?(value, "'") ->
      String.slice(value, 1, String.length(value) - 2)

    true ->
      value
  end
end

if File.exists?(dotenv_path) do
  dotenv_path
  |> File.stream!()
  |> Enum.each(fn raw_line ->
    line = String.trim(raw_line)

    if line != "" and not String.starts_with?(line, "#") do
      case String.split(line, "=", parts: 2) do
        [raw_key, raw_value] ->
          key = String.trim(raw_key)

          value =
            raw_value
            |> String.trim()
            |> strip_wrapping_quotes.()

          if key != "" and is_nil(System.get_env(key)) do
            System.put_env(key, value)
          end

        _ ->
          :ok
      end
    end
  end)
end

if config_env() in [:dev, :prod] do
  port = String.to_integer(System.get_env("PORT") || "4000")

  origins =
    System.get_env("ALLOWED_ORIGINS", "http://localhost:5173")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  config :backend, :cors_origins, origins

  config :backend, BackendWeb.Endpoint,
    server: true,
    http: [ip: {0, 0, 0, 0}, port: port],
    check_origin: origins,
    secret_key_base: System.get_env("SECRET_KEY_BASE") || "dev_secret_key_base_change_me"
end
