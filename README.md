# Macuake: ldelossa fork

A personal fork of [menemy/macuake](https://github.com/menemy/macuake), a Quake-style drop-down terminal powered by [Ghostty](https://ghostty.org).
Press `Option+Space` to show or hide the terminal.

**Apple Silicon only, macOS 14 or later.**
Releases are built and Developer-ID signed locally, but are intentionally **not notarized**.
Updates are manual through Homebrew, with no Sparkle or upstream update feed.

## Install on another Mac

Install [Homebrew](https://brew.sh) if it is not already available, then run:

```sh
brew tap ldelossa/macuake
brew trust ldelossa/macuake
brew install --cask ldelossa/macuake/macuake
```

Homebrew 7 requires `brew trust` before it loads a third-party cask.
It is a one-time, reversible local approval (`brew untrust ldelossa/macuake`), not a Gatekeeper or quarantine change.

Launch `/Applications/Macuake.app`.
If macOS blocks the first launch, approve it in **System Settings > Privacy & Security > Open Anyway** after checking that you trust this fork.
That approval may be needed separately on each Mac.
The cask does not disable Gatekeeper, remove quarantine, or bypass security policy.

The app has the same `com.maquake.app` identity as upstream.
It is a replacement, not a side-by-side installation.
If an upstream or manually installed copy is already present, finish your terminal work, quit it, and move that app aside yourself before installing the cask.
Do not use `--force` to overwrite an app with active sessions.
Your preferences and `~/.config/ghostty/config` are not bundled or overwritten.

### Update

Finish terminal work and quit Macuake before upgrading:

```sh
brew update
brew upgrade --cask ldelossa/macuake/macuake
```

Updates appear only when a new fork release is published.
The app's Updates settings and menu explain this Homebrew-only policy.
Uninstalling the cask removes the app, not your Ghostty configuration or saved preferences.

## Fork features

- Independent tab-bar and selected/hovered-tab RGB colors and opacity.
- Simple color pickers with saturation/brightness, hue, hex and opacity controls.
- Automatic opaque black/white foreground contrast against composited backgrounds.
- Owned picker/popover interactions no longer trigger outside-click auto-hide.
- Keyboard focus follows new splits, pane navigation and pane closure.
- Renderer cursor focus follows the active native terminal without changing cursor shape/blink preferences.
- Pane zoom retains the real split tree, sessions and divider ratios.
- Ghostty's tab-title prompt action opens the inline rename editor.

Inactive tabs use the chosen fill at 75% of the tab-opacity setting, while selected and editing tabs use the full setting.
Hover keeps inactive opacity unchanged and gently brightens the fill, or darkens very light fills, rather than applying the selected-tab appearance.
Text and icons remain fully opaque, with contrast calculated against each tab's fill.
The selected tab also has a bottom marker.

## Shortcuts and Ghostty configuration

| Shortcut | Action |
|----------|--------|
| `Option+Space` | Toggle terminal, configurable in Settings |
| `Cmd+T` | New tab |
| `Cmd+W` | Close tab |
| `Cmd+D` | Split horizontally |
| `Cmd+Shift+D` | Split vertically |
| `Cmd+]` / `Cmd+[` | Next / previous pane |
| `Cmd+1` through `Cmd+9` | Switch tabs |
| `Cmd+,` | Settings |

Existing Ghostty configuration is read from `~/.config/ghostty/config`.
These optional bindings reproduce the zoom/rename shortcuts used during verification:

```ini
keybind = ctrl+alt+z=toggle_split_zoom
keybind = ctrl+alt+comma=prompt_tab_title
```

These lines are examples, not an installed settings override.
Zoom follows pane navigation and exits when creating a split or closing the zoomed pane.
A one-pane tab does not zoom.
For rename, Enter saves, Escape cancels, and leaving the editor commits once.

## Build from source

Maintainer prerequisites are full Xcode, Git and Python 3.
The source also uses the pinned SwiftPM dependencies in `Package.resolved`.
The local release toolchain was verified with Xcode 27.0 beta 6 and its Swift toolchain.
A prebuilt Homebrew installation needs none of these development tools beyond Homebrew's own requirements.

```sh
git clone https://github.com/ldelossa/macuake.git
cd macuake
./scripts/download-ghosttykit.sh
swift build --scratch-path .build/development --disable-automatic-resolution
```

Set `DEVELOPER_DIR` to your full Xcode installation if needed.
The downloader uses the exact Ghostty gitlink and SHA256 in `Dependencies/GhosttyKit.json`, independent of `GITHUB_REPOSITORY`.
It installs no host packages and verifies existing binaries rather than silently accepting a different local build.
The original Ghostty source remains pinned as a submodule for rebuilding or inspection.
Third-party license notices are bundled with the app.

Build a local ad-hoc development archive, without installing or launching it:

```sh
./scripts/build-install.sh
```

The legacy helper copies `/Applications/Macuake_dev.app` only with `--install`, and refuses to replace an existing copy.
It retains the normal app identity and is not intended to run alongside another Macuake.

### Verification

```sh
./scripts/check-regressions.sh
./scripts/check-regressions.sh --gpu  # requires a real local Metal device
```

Each suite runs in a separate process with separate build products.
The GPU checks exercise actual Ghostty surfaces/actions; they are not physical-shortcut or cursor-pixel UI tests.
CI runs the headless regression matrix and Python release-tool tests, and does not publish releases.

## Publish a new personal release

On the signing Mac, keep the Developer ID Application private key in Keychain.
Do not export it or add signing/notarization secrets to GitHub.
Install/authenticate the GitHub CLI and keep a local clone of the public tap at a path such as `~/git/homebrew-macuake`.
Both repositories must be clean, on `main`, and identical to their pushed `origin/main`.
The scripts refuse unexpected remotes, existing version tags, dirty source and branch divergence.

After committing and pushing source changes, publish a new unused version with one command:

```sh
./scripts/publish-release.sh 0.3.3 --tap-path "$HOME/git/homebrew-macuake"
```

`SIGNING_IDENTITY` may select a specific valid Developer ID Application name or fingerprint if more than one is present.
The tool builds arm64, packages resources and required Swift compatibility libraries, removes development loader paths, signs nested code and the app, verifies a relocated archive, and generates SHA256/provenance metadata.
It also publishes corresponding app/Ghostty/gettext source materials and bundled third-party notices.
It creates a draft release, downloads the uploaded ZIP to compare its checksum, publishes it, then commits and pushes the version-pinned cask.
It never installs or launches the app, terminates sessions, notarizes it, or changes user settings.

If a network/upload/push step fails, inspect the retained tag/draft/release and tap checkout before resuming manually.
No force push, tag overwrite, automatic deletion or destructive rollback is attempted.
Never reuse a published version for different bytes.

To build/sign/validate an archive without publishing:

```sh
./scripts/build-release.sh 0.3.3
```

Outputs are under `build/releases/<version>/`, not the running `build/Macuake.app`.
For a locally rebuilt or modified Ghostty library, `--ad-hoc --local-ghostty` permits relinking without the maintainer's private key.
The publication path never accepts that override.

## Existing APIs

The fork retains the existing MCP HTTP server and Unix-socket API without changing their permissions or enabling settings.
See [API.md](API.md) for the socket reference.
The existing socket path is `/tmp/macuake.sock` and the MCP endpoint is `http://localhost:19876/mcp` when enabled.

```sh
claude mcp add --transport http macuake http://localhost:19876/mcp
```

## License and credits

MIT, consistent with the upstream README's license declaration.
Original Macuake contributors, [Ghostty](https://github.com/ghostty-org/ghostty), KeyboardShortcuts and the MCP Swift SDK retain their respective credits and licenses.
This is a personal fork, not an upstream release or an official Homebrew cask.
