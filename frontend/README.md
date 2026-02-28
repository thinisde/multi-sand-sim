# Frontend (SvelteKit)

Client renderer + interaction layer for the global sand simulation.

## Run

```bash
pnpm install && pnpm dev
```

If `pnpm` is unavailable locally, use your equivalent package manager.

## Environment

Frontend reads environment from the repo root `.env` file (`envDir: '..'`).

The client connects to Phoenix channels over websocket and joins topic `global`.
