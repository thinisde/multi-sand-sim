defmodule BackendWeb.GlobalChannel do
  use Phoenix.Channel

  alias Backend.GlobalSim
  alias BackendWeb.Presence

  @topic "global"
  @default_radius 7.0

  @impl true
  def join(@topic, _payload, socket) do
    send(self(), :after_join)
    {:ok, %{topic: @topic, userId: socket.assigns.user_id, color: socket.assigns.color}, socket}
  end

  def join(_other, _payload, _socket) do
    {:error, %{reason: "single_global_topic_only"}}
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _meta} =
      Presence.track(socket, socket.assigns.user_id, %{
        online_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        color: socket.assigns.color
      })

    push(socket, "presence_state", Presence.list(socket))
    push(socket, "snapshot", GlobalSim.snapshot_payload())

    {:noreply, socket}
  end

  @impl true
  def handle_in("brush", payload, socket) do
    case normalize_brush(payload, socket.assigns.user_id, socket.assigns.color) do
      {:ok, brush} ->
        GlobalSim.enqueue_brush(brush)
        broadcast!(socket, "brush", brush)
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("reset", payload, socket) do
    event_id =
      case Map.get(payload, "id") do
        id when is_binary(id) and byte_size(id) > 0 -> id
        _ -> "reset-#{System.unique_integer([:positive, :monotonic])}"
      end

    GlobalSim.reset(socket.assigns.user_id, event_id)
    {:reply, :ok, socket}
  end

  defp normalize_brush(payload, user_id, color) when is_map(payload) do
    x = to_float(Map.get(payload, "x"))
    y = to_float(Map.get(payload, "y"))

    if is_nil(x) or is_nil(y) do
      {:error, "invalid coordinates"}
    else
      id =
        case Map.get(payload, "id") do
          val when is_binary(val) and byte_size(val) > 0 -> val
          _ -> "evt-#{System.unique_integer([:positive, :monotonic])}"
        end

      radius = to_float(Map.get(payload, "radius")) || @default_radius

      brush = %{
        id: id,
        userId: user_id,
        color: color,
        x: x,
        y: y,
        add: to_bool(Map.get(payload, "add", true)),
        radius: radius,
        t: to_integer(Map.get(payload, "t")) || System.system_time(:millisecond)
      }

      {:ok, brush}
    end
  end

  defp normalize_brush(_payload, _user_id, _color), do: {:error, "invalid payload"}

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp to_float(_value), do: nil

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp to_integer(_value), do: nil

  defp to_bool(value) when value in [true, false], do: value
  defp to_bool("true"), do: true
  defp to_bool("false"), do: false
  defp to_bool(1), do: true
  defp to_bool(0), do: false
  defp to_bool(_), do: true
end
