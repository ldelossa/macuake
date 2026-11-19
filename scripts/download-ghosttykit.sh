#!/usr/bin/env bash
set -euo pipefail

# Fetch the exact gitlink's checksum-pinned binary, independent of fork/CI owner.
# Never installs Zig or other host packages. --replace is explicitly opt-in.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/release.py" dependency "$@"
