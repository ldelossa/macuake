#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/build-release.sh 0.3.2 [--identity NAME | --ad-hoc]
# Builds/signs/verifies an arm64 archive only. Does not launch or install it.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/release.py" build "$@"
