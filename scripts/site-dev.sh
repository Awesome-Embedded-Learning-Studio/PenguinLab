#!/usr/bin/env bash
# PenguinLab VitePress dev server (hot-reload)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/site"
exec pnpm dev "$@"
