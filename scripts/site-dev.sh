#!/usr/bin/env bash
# PenguinLab Docusaurus dev server (hot-reload)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/site"
exec pnpm start "$@"
