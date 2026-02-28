# Backend (Phoenix)

Authoritative simulation server for the shared global sand world.

## Run

```bash
mix setup && mix phx.server
```

## Environment

Backend reads environment from the repo root `.env` file.

Run:

```bash
mix phx.server
```

## Socket

- Path: `/socket`
- Topic: `global`
- Events in: `brush`, `reset`
- Events out: `brush`, `reset`, `snapshot`, `presence_state`, `presence_diff`
