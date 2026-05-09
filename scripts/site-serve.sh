#!/usr/bin/env bash
# PenguinLab production build + serve
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/site"
pnpm build
exec pnpm serve "$@"
