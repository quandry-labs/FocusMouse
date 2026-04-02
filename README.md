# FocusMouse

A lightweight macOS menu bar app that automatically focuses the window under your mouse cursor — like X11 focus-follows-mouse, but for macOS.

## Features

- **Focus follows mouse** — windows gain focus as your cursor moves over them
- **Optional window raise** — bring focused windows to front automatically
- **Configurable delays** — fine-tune focus and raise timing (0–1000ms)
- **App exclusions** — exclude specific apps from auto-focus
- **Launch at login** — runs silently in the background
- **Auto-update** — checks GitHub releases and updates in-place
- **Menu bar only** — no dock icon clutter (configurable)

## Install

Download the latest `.dmg` from [Releases](https://github.com/quandry-labs/FocusMouse/releases), open it, and drag FocusMouse to Applications.

Or build from source:

```bash
git clone https://github.com/quandry-labs/FocusMouse.git
cd FocusMouse
bash scripts/build-app.sh
open build/FocusMouse.dmg
```

## Requirements

- macOS 14.0 (Sonoma) or later
- Accessibility permission (the app will prompt you)

## Usage

FocusMouse lives in your menu bar. Click the cursor icon to configure:

- **Enabled** — toggle focus-follows-mouse on/off
- **Focus Delay** — milliseconds before a window gains focus (default 200ms)
- **Raise Window** — also bring the window to front
- **Raise Delay** — milliseconds before raising (default 0ms)
- **Excluded Apps** — apps that should be ignored
- **Launch at Login** — start automatically
- **Show in Dock** — toggle dock icon visibility

## Building

Requires Swift 5.10+ and Xcode command line tools.

```bash
# Debug build
swift build

# Release build + DMG
bash scripts/build-app.sh
```

The build script produces a universal binary (arm64 + x86_64), creates a signed `.app` bundle, and packages it as a `.dmg`.

## License

MIT — see [LICENSE](LICENSE).
