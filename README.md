# Multi-User Sand Simulation (Single Global Room)

Monorepo with three apps:
- `backend/`: Elixir + Phoenix channels authoritative simulation server.
- `frontend/`: SvelteKit + Tailwind client.
- `physics_engine/`: Rust + wasm-pack + wgpu client renderer.

All clients join one fixed Phoenix topic: `"global"`.

## Requirements

- Elixir 1.19+ and Erlang/OTP 28+
- Node 20+
- `pnpm`
- Rust stable
- `wasm-pack`

## Run

1. Backend

```bash
cd backend
mix setup && mix phx.server
```

2. Frontend

```bash
cd frontend
pnpm install && pnpm dev
```

3. WASM build (manual)

```bash
cd physics_engine
wasm-pack build --target web --release --out-dir ../frontend/static/wasm --out-name physics_engine
```

WASM helper script:

```bash
./scripts/rebuild-wasm.sh
```

## Environment

Use a single root env file:
- `.env` (repo root)

Backend automatically loads this file in `config/runtime.exs`.
You can still override any value from the shell before starting.

```bash
cd backend
mix phx.server
```

Frontend is wired with `envDir: '..'`, so it reads the same root `.env`.

## Protocol

Topic:
- `global`

Client -> server:
- `brush`: `{ id, userId, x, y, add, radius, t }`
- `reset`: `{ id }`

Server -> clients:
- `brush`: immediate broadcast of received brush events
- `reset`: `{ type: "reset", id, userId, tick }`
- `snapshot`: `%{type: "snapshot", w: 800, h: 600, bytesB64: "...", tick: tick_count}`
  - `bytesB64` is `Base64(gzip(raw_grid_bytes))`

## Authoritative Sim

- Grid: `800x600`, bytes `0` or `255`
- Global state owner: `Backend.GlobalSim` GenServer
- Tick: `60Hz`
- Per tick:
  1. apply queued brush events
  2. vertical fall pass
  3. diagonal pass (`dx = +1 or -1`)
  4. opposite diagonal pass
- Diagonal direction order alternates each tick.
- Snapshot broadcast interval: every ~2 seconds.

## Notes

- The server is authoritative; clients render locally for responsiveness.
- On snapshot receipt, frontend decodes + gunzips and calls `eng.import_state(bytes)`.
- Reset clears authoritative state and broadcasts `reset` + `snapshot`.
