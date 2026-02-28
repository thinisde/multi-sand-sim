#!/bin/bash

wasm-pack build --target web --release \
  --out-dir ../frontend/static/wasm \
  --out-name physics_engine

if command -v wasm-opt >/dev/null 2>&1; then
  wasm_file="../frontend/static/wasm/physics_engine_bg.wasm"
  opt_file="../frontend/static/wasm/physics_engine_bg.opt.wasm"

  if wasm-opt -Oz --enable-bulk-memory -o "$opt_file" "$wasm_file"; then
    mv "$opt_file" "$wasm_file"
  else
    echo "warning: wasm-opt failed; keeping unoptimized wasm output" >&2
    rm -f "$opt_file"
  fi
fi
