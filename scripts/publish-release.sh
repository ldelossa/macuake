#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/publish-release.sh 0.3.2 --tap-path "$HOME/git/homebrew-macuake"
# Requires clean, pushed main branches and a local Developer ID certificate.
# Private signing keys remain in Keychain; no notarization or CI secrets used.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/release.py" publish "$@"
