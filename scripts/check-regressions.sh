#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"
GPU=false
if [ "${1:-}" = "--gpu" ]; then
    GPU=true
elif [ "$#" -ne 0 ]; then
    echo "Usage: $0 [--gpu]" >&2
    exit 2
fi
SCRATCH="${MACUAKE_TEST_SCRATCH:-$ROOT/.build/fork-checks}"
LOGS="$ROOT/build/checks"
mkdir -p "$LOGS"
# Separate products protect an already-running development app's loader paths.
swift build --scratch-path "$SCRATCH" --disable-automatic-resolution --build-tests
SUITES=(
    ColorHexTests ColorSelectionTests WindowControllerAppearanceTests
    TabBarPaletteTests TabAppearanceTests PickerAutoHideTests GlobalClickOwnershipTests
    SplitFocusTests RendererFocusTests PaneZoomTests TabRenameShortcutTests HomebrewUpdatesTests
    KeyboardRoutingTests KeyboardFocusTests KeyboardBeepTests MouseDownNSViewTests
    GhosttyTerminalViewResponderTests PaneIntegrationTests PaneManagementTests
    PaneManagerAdvancedTests PaneNodeTreeTests TabClickTests TabManagerAdvancedTests
    TabManagerTests TabTests ResizeEdgeTests ResizePreviewMathTests
)
run_suite() {
    local mode="$1" suite="$2" log="$LOGS/$1-$2.log" enabled=0
    if [ "$mode" = gpu ]; then enabled=1; fi
    echo "Running $mode: $suite"
    if ! MACUAKE_TEST_GHOSTTY="$enabled" swift test --scratch-path "$SCRATCH" \
        --disable-automatic-resolution --skip-build --filter "$suite" > "$log" 2>&1; then
        tail -n 70 "$log"
        return 1
    fi
    # A misspelled/removed filter must not silently turn into a passing check.
    if ! grep -Eq 'Test run with [1-9][0-9]* tests? .*passed' "$log"; then
        tail -n 35 "$log"
        echo "STOP: suite produced no successful nonempty test run" >&2
        return 1
    fi
    tail -n 1 "$log"
}
for suite in "${SUITES[@]}"; do run_suite headless "$suite"; done
if "$GPU"; then
    # These require a real local Metal device, unlike the headless CI matrix.
    for suite in SplitFocusTests RendererFocusTests PaneZoomTests TabRenameShortcutTests \
        GhosttyBackendSplitTests GhosttyBackendTerminateTests; do
        run_suite gpu "$suite"
    done
fi
python3 -m unittest discover -s scripts/tests -v
git diff --check
