# StatusButler 0.1.0

> Released 2026-10-12 · macOS 13+ (Ventura and later) · First public release (build 1)

## What it is

**StatusButler** is a native macOS menu-bar status aggregator: it packs battery, Wi-Fi, volume and more into **one** hand-drawn icon. Click it for a six-section popover (Battery / Network / Volume / Bluetooth / Thermal / Performance) with drill-down details and direct controls. The bundled `butler` command line puts the same queries and actions in your terminal and scripts.

- **Three-in-one icon**: battery, network and volume in a single menu-bar slot; breathing animation while charging; a footer slot cycles additional signals such as temperature, fan speed or network rate
- **Six-section popover**: left-click to open; sections sample on demand — nothing runs when nobody is looking (efficiency first)
- **Settings center**: live icon preview, popover behavior, light/dark themes (6 presets), English and Simplified Chinese
- **Actions & automation**: `butler://` URL scheme plus the `butler` CLI — volume, panels, fan control, screen off and more are all scriptable
- **Safety red lines**: never touches Wi-Fi passwords or the keychain; never writes charging-related hardware (fan control is the sole whitelisted exception); minimal privacy permissions

## Installation

### Option 1: DMG (recommended)

1. Download `StatusButler-0.1.0.dmg` and its `.sha256` sidecar from GitHub Releases
2. Verify integrity (optional but recommended):
   ```bash
   shasum -a 256 --check StatusButler-0.1.0.dmg.sha256
   ```
3. Open the DMG and drag 状态管家 (StatusButler) into /Applications
4. **First launch**: 0.1.0 is ad-hoc signed (see Known Limitations), so macOS will block it. **Right-click the app → Open → Open** in Finder, or approve it under System Settings → Privacy & Security

### Option 2: build from source

```bash
git clone <this repository>
cd mactool/statusbutler
bash scripts/build-app.sh release no-open   # produces dist/状态管家.app
```

The CLI binary is built in the same run: `statusbutler/.build/release/butler`. Copy it to `/usr/local/bin` or `~/.local/bin` yourself.

### CLI quick start

```bash
butler status              # human-readable snapshot (main app must be running)
butler status --json       # machine-readable JSON (script friendly)
butler volume 50           # set volume to 50
butler panel thermal       # jump straight to the thermal panel
butler --help              # all verbs and the exit-code table
```

Full feature documentation: `docs/a13-usage.html` in the repository (user guide).

## Known Limitations

- **Ad-hoc signature and first-launch gate**: 0.1.0 has no Developer ID certificate; the app is ad-hoc signed and not notarized. The first launch requires right-click → Open or an approval in System Settings → Privacy & Security; upgrading may require approval again.
- **Sandbox network restrictions**: the script plugin slot isolates plugins via `sandbox-exec` with networking denied, but on macOS 26 (darwin26) the `network*` deny rules are ineffective and the tool may be missing — plugins then run in a degraded "unsandboxed flag + strict timeout" mode (alternative registered as T-035b). The weather module only reaches the Open-Meteo allow-listed domain through a URL / DNS / redirect three-gate check.
- **Desktop widgets (coming soon)**: the data layer is ready, but the WidgetKit extension does not ship with 0.1.0 — widgets are not yet available.
- **No auto-update**: the Sparkle update chain is not wired yet; watch the Releases page manually.
- **Launch at login**: the settings toggle is a placeholder; login-item registration lands in a later release.
- **Feature scope**: iDevice battery and per-app volume are not included in this release.
- **Architecture**: the DMG contains arm64 only (Apple Silicon); Intel Mac users should build from source.

## Feedback

Please open a GitHub issue for problems and suggestions; the development roadmap lives in `docs/c1-plan.html`.
