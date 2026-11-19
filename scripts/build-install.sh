#!/usr/bin/env bash
set -euo pipefail

# Legacy development helper. Installation is genuinely opt-in and never replaces
# an existing app or stops a running session. Use Homebrew for released builds.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --help|-h)
            echo "Usage: $0 [--install]"
            echo "Builds an arm64 ad-hoc development archive; --install copies Macuake_dev.app only if absent."
            exit 0 ;;
        *) echo "Unsupported argument: $arg (this fork distributes arm64 only)" >&2; exit 2 ;;
    esac
done
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_ROOT/MaQuake/Resources/Info.plist")
"$SCRIPT_DIR/build-release.sh" "$VERSION" --ad-hoc
if "$INSTALL"; then
    DESTINATION="/Applications/Macuake_dev.app"
    if [ -e "$DESTINATION" ]; then
        echo "STOP: $DESTINATION already exists; it was not replaced." >&2
        exit 1
    fi
    TEMP=$(mktemp -d)
    trap 'rm -rf "$TEMP"' EXIT
    ditto -x -k "$PROJECT_ROOT/build/releases/$VERSION/Macuake-arm64.zip" "$TEMP"
    ditto "$TEMP/Macuake.app" "$DESTINATION"
    codesign --verify --deep --strict "$DESTINATION"
    echo "Installed $DESTINATION (same app identity; not intended to run alongside another Macuake)."
else
    echo "Build complete. No app was installed or stopped."
fi
