defmodule Backend.GlobalSim do
  use GenServer

  alias Backend.Snapshot
  alias BackendWeb.Endpoint

  @topic "global"
  @w 800
  @h 600
  @ground_y @h - 80

  @tick_hz 60
  @tick_ms div(1000, @tick_hz)
  @snapshot_every_ticks @tick_hz * 2
  @seen_ttl_ticks @tick_hz * 20

  @default_color {214, 181, 97}

  @type rgb :: {0..255, 0..255, 0..255}

  @type brush_event :: %{
          id: String.t(),
          userId: String.t(),
          color: String.t(),
          x: number(),
          y: number(),
          add: boolean(),
          radius: number(),
          t: integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec enqueue_brush(brush_event()) :: :ok
  def enqueue_brush(event) do
    GenServer.cast(__MODULE__, {:enqueue_brush, event})
  end

  @spec reset(String.t(), String.t()) :: :ok
  def reset(user_id, event_id) do
    GenServer.cast(__MODULE__, {:reset, user_id, event_id})
  end

  @spec snapshot_payload() :: map()
  def snapshot_payload do
    GenServer.call(__MODULE__, :snapshot_payload)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, @tick_ms)

    {:ok,
     %{
       grid: empty_grid(),
       colors: empty_colors(),
       queue: :queue.new(),
       tick: 0,
       parity: false,
       seen_ids: %{}
     }}
  end

  @impl true
  def handle_call(:snapshot_payload, _from, state) do
    {:reply, snapshot_payload_for(state.grid, state.colors, state.tick), state}
  end

  @impl true
  def handle_cast({:enqueue_brush, event}, state) do
    with {:ok, normalized} <- normalize_brush(event),
         false <- Map.has_key?(state.seen_ids, normalized.id) do
      seen_ids = Map.put(state.seen_ids, normalized.id, state.tick)
      queue = :queue.in(normalized, state.queue)
      {:noreply, %{state | queue: queue, seen_ids: seen_ids}}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_cast({:reset, user_id, event_id}, state) do
    tick = state.tick + 1
    grid = empty_grid()
    colors = empty_colors()

    Endpoint.broadcast(@topic, "reset", %{
      type: "reset",
      id: event_id,
      userId: user_id,
      tick: tick
    })

    Endpoint.broadcast(@topic, "snapshot", snapshot_payload_for(grid, colors, tick))

    seen_ids =
      case event_id do
        id when is_binary(id) and byte_size(id) > 0 -> %{id => tick}
        _ -> %{}
      end

    {:noreply,
     %{
       state
       | grid: grid,
         colors: colors,
         queue: :queue.new(),
         tick: tick,
         parity: false,
         seen_ids: seen_ids
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    {events, queue} = drain_queue(state.queue)

    dx_first = if state.parity, do: 1, else: -1

    {grid, colors} =
      {state.grid, state.colors}
      |> apply_brush_events(events)
      |> step_vertical()
      |> step_diagonal(dx_first)
      |> step_diagonal(-dx_first)

    tick = state.tick + 1

    if rem(tick, @snapshot_every_ticks) == 0 do
      Endpoint.broadcast(@topic, "snapshot", snapshot_payload_for(grid, colors, tick))
    end

    seen_ids =
      if rem(tick, @snapshot_every_ticks) == 0 do
        prune_seen_ids(state.seen_ids, tick)
      else
        state.seen_ids
      end

    Process.send_after(self(), :tick, @tick_ms)

    {:noreply,
     %{
       state
       | grid: grid,
         colors: colors,
         queue: queue,
         parity: !state.parity,
         tick: tick,
         seen_ids: seen_ids
     }}
  end

  defp normalize_brush(event) when is_map(event) do
    with id when is_binary(id) <- Map.get(event, :id),
         user_id when is_binary(user_id) <- Map.get(event, :userId),
         color when is_binary(color) <- Map.get(event, :color),
         {:ok, rgb} <- parse_hex_color(color),
         x when is_number(x) <- Map.get(event, :x),
         y when is_number(y) <- Map.get(event, :y),
         add when add in [true, false] <- Map.get(event, :add),
         radius when is_number(radius) <- Map.get(event, :radius),
         t when is_integer(t) <- Map.get(event, :t) do
      {:ok,
       %{
         id: id,
         userId: user_id,
         color: rgb,
         x: x,
         y: y,
         add: add,
         radius: radius,
         t: t
       }}
    else
      _ -> {:error, :invalid_event}
    end
  end

  defp normalize_brush(_), do: {:error, :invalid_event}

  defp parse_hex_color(hex) when is_binary(hex) do
    case String.trim(hex) |> String.downcase() do
      <<?#, r1, r2, g1, g2, b1, b2>> ->
        with {:ok, r} <- parse_hex_byte(<<r1, r2>>),
             {:ok, g} <- parse_hex_byte(<<g1, g2>>),
             {:ok, b} <- parse_hex_byte(<<b1, b2>>) do
          {:ok, {r, g, b}}
        end

      _ ->
        {:ok, @default_color}
    end
  end

  defp parse_hex_byte(value) do
    case Integer.parse(value, 16) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_color}
    end
  end

  defp drain_queue(queue) do
    drain_queue(queue, [])
  end

  defp drain_queue(queue, acc) do
    case :queue.out(queue) do
      {{:value, value}, rest} -> drain_queue(rest, [value | acc])
      {:empty, rest} -> {Enum.reverse(acc), rest}
    end
  end

  defp prune_seen_ids(seen_ids, tick) do
    Enum.reduce(seen_ids, %{}, fn {id, seen_tick}, acc ->
      if tick - seen_tick <= @seen_ttl_ticks do
        Map.put(acc, id, seen_tick)
      else
        acc
      end
    end)
  end

  defp apply_brush_events({grid, colors}, []), do: {grid, colors}

  defp apply_brush_events({grid, colors}, events) do
    updates =
      Enum.reduce(events, %{}, fn event, acc ->
        collect_brush_updates(event, acc)
      end)

    case map_size(updates) do
      0 ->
        {grid, colors}

      _ ->
        updates
        |> Map.to_list()
        |> Enum.sort_by(&elem(&1, 0))
        |> patch_grids(grid, colors)
    end
  end

  defp collect_brush_updates(event, acc) do
    cx = event.x |> round() |> clamp(0, @w - 1)
    cy = event.y |> round() |> clamp(0, @ground_y - 1)
    radius = event.radius |> round() |> clamp(1, 64)

    left = max(cx - radius, 0)
    right = min(cx + radius, @w - 1)
    top = max(cy - radius, 0)
    bottom = min(cy + radius, @ground_y - 1)

    {occ, color} =
      if event.add do
        {255, event.color}
      else
        {0, {0, 0, 0}}
      end

    r2 = radius * radius

    for y <- top..bottom, x <- left..right, reduce: acc do
      updates ->
        dx = x - cx
        dy = y - cy

        if dx * dx + dy * dy <= r2 do
          Map.put(updates, idx(x, y), {occ, color})
        else
          updates
        end
    end
  end

  defp patch_grids(updates, grid, colors) do
    size = byte_size(grid)

    {grid_parts, color_parts, cursor} =
      Enum.reduce(updates, {[], [], 0}, fn {index, {occ, {r, g, b}}}, {g_acc, c_acc, cursor} ->
        cond do
          index < cursor ->
            {g_acc, c_acc, cursor}

          index >= size ->
            {g_acc, c_acc, cursor}

          true ->
            g_acc =
              if index > cursor do
                [binary_part(grid, cursor, index - cursor) | g_acc]
              else
                g_acc
              end

            c_acc =
              if index > cursor do
                [binary_part(colors, cursor * 3, (index - cursor) * 3) | c_acc]
              else
                c_acc
              end

            {[<<occ>> | g_acc], [<<r, g, b>> | c_acc], index + 1}
        end
      end)

    grid_parts =
      if cursor < size do
        [binary_part(grid, cursor, size - cursor) | grid_parts]
      else
        grid_parts
      end

    color_parts =
      if cursor < size do
        [binary_part(colors, cursor * 3, (size - cursor) * 3) | color_parts]
      else
        color_parts
      end

    {
      grid_parts |> Enum.reverse() |> IO.iodata_to_binary(),
      color_parts |> Enum.reverse() |> IO.iodata_to_binary()
    }
  end

  defp step_vertical({grid, colors}) do
    max_y = @ground_y - 1

    {grid_rows, color_rows} =
      Enum.reduce(0..(@h - 1), {[], []}, fn y, {g_rows, c_rows} ->
        {g_row, c_row} =
          Enum.reduce(0..(@w - 1), {[], []}, fn x, {g_cells, c_cells} ->
            {occ, {r, g, b}} = vertical_value(grid, colors, x, y, max_y)
            {[<<occ>> | g_cells], [<<r, g, b>> | c_cells]}
          end)

        {[Enum.reverse(g_row) | g_rows], [Enum.reverse(c_row) | c_rows]}
      end)

    {
      grid_rows |> Enum.reverse() |> IO.iodata_to_binary(),
      color_rows |> Enum.reverse() |> IO.iodata_to_binary()
    }
  end

  defp vertical_value(_grid, _colors, _x, y, max_y) when y > max_y, do: {0, {0, 0, 0}}

  defp vertical_value(grid, colors, x, y, _max_y) do
    here = occupied?(grid, x, y)

    cond do
      here and y + 1 < @ground_y and not occupied?(grid, x, y + 1) ->
        {0, {0, 0, 0}}

      here ->
        {255, color_at(colors, x, y)}

      y > 0 and occupied?(grid, x, y - 1) ->
        {255, color_at(colors, x, y - 1)}

      true ->
        {0, {0, 0, 0}}
    end
  end

  defp step_diagonal({grid, colors}, dx) when dx in [-1, 1] do
    max_y = @ground_y - 1

    {grid_rows, color_rows} =
      Enum.reduce(0..(@h - 1), {[], []}, fn y, {g_rows, c_rows} ->
        {g_row, c_row} =
          Enum.reduce(0..(@w - 1), {[], []}, fn x, {g_cells, c_cells} ->
            {occ, {r, g, b}} = diagonal_value(grid, colors, x, y, dx, max_y)
            {[<<occ>> | g_cells], [<<r, g, b>> | c_cells]}
          end)

        {[Enum.reverse(g_row) | g_rows], [Enum.reverse(c_row) | c_rows]}
      end)

    {
      grid_rows |> Enum.reverse() |> IO.iodata_to_binary(),
      color_rows |> Enum.reverse() |> IO.iodata_to_binary()
    }
  end

  defp diagonal_value(_grid, _colors, _x, y, _dx, max_y) when y > max_y, do: {0, {0, 0, 0}}

  defp diagonal_value(grid, colors, x, y, dx, _max_y) do
    here = occupied?(grid, x, y)

    cond do
      here and can_move_diagonal?(grid, x, y, dx) ->
        {0, {0, 0, 0}}

      here ->
        {255, color_at(colors, x, y)}

      can_receive_diagonal?(grid, x, y, dx) ->
        {255, color_at(colors, x - dx, y - 1)}

      true ->
        {0, {0, 0, 0}}
    end
  end

  defp can_move_diagonal?(grid, x, y, dx) do
    target_x = x + dx
    target_y = y + 1

    target_y < @ground_y and target_x >= 0 and target_x < @w and occupied?(grid, x, target_y) and
      not occupied?(grid, target_x, target_y)
  end

  defp can_receive_diagonal?(grid, x, y, dx) do
    source_x = x - dx
    source_y = y - 1

    y > 0 and source_x >= 0 and source_x < @w and occupied?(grid, source_x, source_y) and
      occupied?(grid, source_x, y) and not occupied?(grid, x, y)
  end

  defp occupied?(_grid, x, _y) when x < 0 or x >= @w, do: false
  defp occupied?(_grid, _x, y) when y < 0 or y >= @ground_y, do: false

  defp occupied?(grid, x, y) do
    :binary.at(grid, idx(x, y)) == 255
  end

  defp color_at(_colors, x, _y) when x < 0 or x >= @w, do: {0, 0, 0}
  defp color_at(_colors, _x, y) when y < 0 or y >= @ground_y, do: {0, 0, 0}

  defp color_at(colors, x, y) do
    base = idx(x, y) * 3
    {:binary.at(colors, base), :binary.at(colors, base + 1), :binary.at(colors, base + 2)}
  end

  defp idx(x, y), do: y * @w + x

  defp clamp(value, min, max) do
    value
    |> max(min)
    |> min(max)
  end

  defp snapshot_payload_for(grid, colors, tick) do
    rgba = compose_rgba(grid, colors)

    %{
      type: "snapshot",
      w: @w,
      h: @h,
      bytesB64: Snapshot.encode(rgba),
      tick: tick,
      format: "rgba8"
    }
  end

  defp compose_rgba(grid, colors) do
    max_index = @w * @h - 1

    for index <- 0..max_index, into: <<>> do
      alpha = :binary.at(grid, index)
      base = index * 3
      r = :binary.at(colors, base)
      g = :binary.at(colors, base + 1)
      b = :binary.at(colors, base + 2)
      <<r, g, b, alpha>>
    end
  end

  defp empty_grid do
    :binary.copy(<<0>>, @w * @h)
  end

  defp empty_colors do
    :binary.copy(<<0, 0, 0>>, @w * @h)
  end
end
