# FocusMouse

A lightweight macOS menu bar app that automatically focuses the window under your mouse cursor — like X11 focus-follows-mouse, but for macOS.

## Features

- **Focus follows mouse** — windows gain focus as your cursor moves over them
- **Stage Manager aware** — hovering recent-app thumbnails never activates them
- **Optional window raise** — bring focused windows to front automatically
- **Configurable delays** — fine-tune focus and raise timing (0–1000ms)
- **App exclusions** — exclude specific apps from auto-focus
- **Launch at login** — runs silently in the background
- **Update notifications** — checks GitHub releases and opens the validated release page
- **Menu bar only** — no dock icon clutter (configurable)
- **Command shortcut guide** — hold ⌘ anywhere for a paged iPad-style guide containing 200+ macOS defaults and every shortcut exposed by the frontmost app’s native menu hierarchy
- **System HUD** — optional, click-through Liquid Glass dashboard with per-core CPU, memory, thermal pressure and CPU temperature, system power draw, fan RPM/utilization and RPM-based acoustic estimates, storage hotspots, network activity and addressing, user/OS identity, and cached update status

FocusMouse does not collect analytics, keystrokes, audio, screen contents, window titles, or file contents. It observes pointer movement and window geometry only while enabled, and uses Accessibility to focus the window under the pointer and read the frontmost app’s native menu shortcut metadata. Pointer tracking uses a listen-only event tap whose mask excludes every mouse-button down/up event. When the Command Shortcut Guide is enabled, FocusMouse observes modifier-flag changes long enough to recognize Command being held and passively observes scroll-wheel events only while the guide is visible to change pages; it does not monitor ordinary key presses or persist shortcut, modifier, or scroll activity. Both HUDs and the shortcut guide are WindowServer-level click-through panels and cannot become the key or main window. On launch it makes one HTTPS request to the project’s GitHub Releases page to check for a newer version. When System HUD network details are enabled, FocusMouse queries ipify over HTTPS for the current public IPv4 and IPv6 addresses at most once every five minutes; the addresses remain in memory and are not persisted. Storage hotspots are calculated locally from allocated-size metadata for readable user folders and cached for 30 minutes. Pending macOS updates are read from the system's cached software-update catalog without starting a new scan. Thermal, power, and fan values are sampled locally from macOS hardware services and remain in memory. The acoustic label is estimated from normalized fan RPM; FocusMouse does not access the microphone or claim a measured dBA value.

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

- Apple silicon Mac
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
- **Command Shortcut Guide** — hold Command by itself, scroll through every page of macOS defaults and the frontmost app’s native menu shortcuts, then release to dismiss
- **System HUD** — show or hide the click-through desktop dashboard
- **Appearance** — follow the system or force the HUD into Light or Dark mode
- **Window opacity** — control the actual opacity of the complete HUD window
- **Background blur** — blend the native macOS backdrop blur from clear to fully blurred
- **Network details** — show LAN, VPN, and public-address cards

## Building

Requires Swift 6.4+ and Xcode 27+ command line tools.

When keeping Xcode 27 beta alongside a stable Xcode installation, select it per command instead of changing the global developer directory:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

```bash
# Debug build
swift build

# Local arm64 build + DMG (ad-hoc signed; not for distribution)
bash scripts/build-app.sh --local
```

The build script produces and verifies an arm64-only binary for Apple silicon. Distribution builds fail closed unless a Developer ID identity and notarization profile are supplied:

```bash
FOCUSMOUSE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
FOCUSMOUSE_NOTARY_PROFILE="focusmouse-notary" \
bash scripts/build-app.sh --release
```

Release mode enables hardened runtime, signs the app and DMG, notarizes, staples the ticket, and runs Gatekeeper checks.

## License

MIT — see [LICENSE](LICENSE).
