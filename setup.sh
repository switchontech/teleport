#!/bin/bash
# Main entry point — one command from the repo root to build + run the
# server. Just calls into deploy/server/build-and-run.sh, which does the
# actual work (build, start, apply roles, create admin, bake VS installer).
#
# Usage: bash setup.sh   (run from anywhere, or from the repo root)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/deploy/server/build-and-run.sh" "$@"
