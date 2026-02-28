defmodule BackendWeb.UserSocket do
  use Phoenix.Socket

  @default_color "#d6b561"

  channel("global", BackendWeb.GlobalChannel)

  @impl true
  def connect(params, socket, _connect_info) do
    user_id =
      case Map.get(params, "userId") do
        value when is_binary(value) and byte_size(value) > 0 -> value
        _ -> random_id()
      end

    color =
      case Map.get(params, "color") do
        value when is_binary(value) and byte_size(value) > 0 ->
          normalize_color(value)

        _ ->
          @default_color
      end

    {:ok, socket |> assign(:user_id, user_id) |> assign(:color, color)}
  end

  @impl true
  def id(_socket), do: nil

  defp random_id do
    :crypto.strong_rand_bytes(12)
    |> Base.url_encode64(padding: false)
  end

  defp normalize_color(value) do
    value = String.trim(value)

    if String.match?(value, ~r/^#[0-9A-Fa-f]{6}$/) do
      String.downcase(value)
    else
      @default_color
    end
  end
end
