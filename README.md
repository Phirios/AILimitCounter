# AILimitCounter

<p align="center">
  <img src="assets/icon.png" width="128" alt="AILimitCounter Icon">
</p>

<p align="center">
  A native system tray app that displays your AI CLI rate limit usage in real time.
  <br>Available for <strong>macOS</strong> (Swift/AppKit) and <strong>Linux</strong> (Rust/KDE Plasma, GNOME, niri/DankMaterialShell).
</p>

<p align="center">
  <img src="assets/topbar-example.png" alt="Menu Bar Example">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift">
</p>

## Features

- **Multiple AI CLIs** — Switch between Claude Code and Codex from the menu or settings
- **Dual limit visualization** — Custom icon with an outer ring (5h session limit, App Store-style circular progress) and an inner circle (7d weekly limit, fills vertically)
- **Color-coded** — Green (<55%), Yellow (55-69%), Orange (70-84%), Red (85%+)
- **Session percentage** — Shown as text next to the icon with a time-remaining progress bar underneath
- **Live indicator** — Pulsing dot when the selected AI CLI is actively running; auto-increases refresh rate to 1 min
- **Dropdown menu** — Detailed breakdown with colored ASCII bars, reset times, and status
- **Zero config** — Reads your Claude Code OAuth token from keychain automatically

## How It Works

### Claude Code

Makes a minimal API request (`max_tokens: 1`, Haiku model) to `api.anthropic.com` and reads the rate limit headers:

```
anthropic-ratelimit-unified-5h-utilization: 0.32
anthropic-ratelimit-unified-7d-utilization: 0.40
anthropic-ratelimit-unified-5h-reset: 1775523600
anthropic-ratelimit-unified-7d-reset: 1775862000
```

Each check costs ~10 tokens (Haiku).

### Codex

Reads the latest local Codex session event from `~/.codex/sessions` and displays the `rate_limits` payload emitted by Codex. Codex checks are local-only and do not make an API request.

## Install

### Download (recommended)

1. Download the latest `AILimitCounter-v*.zip` from [Releases](https://github.com/Phirios/AILimitCounter/releases)
2. Unzip and move `AILimitCounter.app` to `/Applications`
3. Cache your Claude Code token (one-time):
```bash
security find-generic-password -s "Claude Code-credentials" -w | \
  python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])" \
  > ~/.claude/claude-menubar-token
```
4. Launch the app

> **Note:** macOS may show "unidentified developer" warning on first launch. Right-click the app and select Open, then click Open in the dialog.

### Build from source

```bash
git clone https://github.com/Phirios/AILimitCounter.git
cd AILimitCounter
swift build -c release
```

Then create the app bundle:
```bash
APP="$HOME/Applications/AILimitCounter.app/Contents"
mkdir -p "$APP/MacOS"
cp .build/release/AILimitCounter "$APP/MacOS/"
```

### Launch at login (optional)

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/AILimitCounter.app", hidden:false}'
```

## Menu Bar

```
[icon] 32% ●     ← session %, pulsing dot = claude is running
       ▓▓░░░     ← time remaining bar

Click to open:
┌─────────────────────────────────────────────┐
│ ● Claude is running                         │
│─────────────────────────────────────────────│
│ ✅ Allowed                                  │
│─────────────────────────────────────────────│
│ 5h  [██████░░░░░░░░░░░░░░] 32% ◀           │
│       Reset: in 3h 42min                    │
│─────────────────────────────────────────────│
│ 7d  [████████░░░░░░░░░░░░] 40%             │
│       Reset: in 4d 2h                       │
│─────────────────────────────────────────────│
│ Refresh Now                          ⌘R     │
│ Settings...                          ⌘,     │
│─────────────────────────────────────────────│
│ Quit                                 ⌘Q     │
└─────────────────────────────────────────────┘
```

## Requirements

- macOS 14+
- Claude Code CLI (authenticated via `claude auth login`)

---

## Linux (KDE Plasma)

The Linux version combines a Rust backend with a native Plasma 6 panel widget. The widget displays the circular limits, current percentage, remaining 5-hour time bar, and live indicator directly in the panel on both X11 and Wayland.

### Install dependencies (Arch / CachyOS)

```bash
sudo pacman -S rust dbus
```

### Build

```bash
cd linux
cargo build --release
```

Binary: `linux/target/release/ai-limit-counter`

Install the backend and Plasma widget:

```bash
install -Dm755 target/release/ai-limit-counter ~/.local/bin/ai-limit-counter
kpackagetool6 --type Plasma/Applet --install plasmoid
```

### Token setup (one-time)

```bash
security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | \
  python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])" \
  > ~/.claude/claude-menubar-token
```

Or copy from your Mac's `~/.claude/claude-menubar-token`.

### Autostart the backend with KDE

```bash
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/ai-limit-counter.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=AILimitCounter
Exec=/home/YOUR_USER/.local/bin/ai-limit-counter --server
Comment=AI CLI rate limit monitor
X-KDE-autostart-phase=2
EOF
```

Then add **AI Limit Counter** to your Plasma panel from **Enter Edit Mode → Add Widgets**.

## Linux (GNOME)

A native GNOME Shell extension (GNOME 49) lives in `gnome/`. It's independent of the KDE build and needs no compiled backend. A ring and the 5-hour percentage sit in the top bar. Clicking it opens a translucent dark drop-down with **Claude | GPT** tabs, each showing the 5-hour and weekly windows.

- **Claude:** reads the OAuth token Claude Code keeps in `~/.claude/.credentials.json` and makes the same ~10-token Haiku request as the other builds. It polls only while the Claude tab is selected (every 5 min, or every minute while `claude` is running) and when the menu opens.
- **GPT (Codex):** reads the tail of the newest `~/.codex/sessions/**/*.jsonl`. This is local only, so it costs nothing. A window whose reset time has passed is shown as reset.

```bash
cd gnome
./install.sh            # copies to ~/.local/share/gnome-shell/extensions and compiles the schema
# Wayland: log out and back in once, then:
gnome-extensions enable ailimitcounter@firatege.github.io
```

Tests: `gjs -m gnome/tests/format.test.js`

## Linux (niri / DankMaterialShell)

A [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) bar plugin lives in `dms/`, for niri and the other compositors DMS runs on. It shows a ring and the 5-hour percentage in the bar. Clicking it opens a panel with **Claude | GPT** tabs, each showing the 5-hour and weekly windows, a plan badge, a live indicator and a refresh button.

The plugin gets its numbers from the Rust helper in `linux/` (`ai-limit-counter --json <provider>`), so it shares its data sources with the KDE build:

- **Claude:** reads the OAuth token Claude Code keeps in `~/.claude/.credentials.json` (the `~/.claude/claude-menubar-token` file still works as a fallback). It polls only while Claude is the selected provider: every 5 min, or every minute while `claude` is running.
- **GPT (Codex):** reads the newest `~/.codex/sessions/**/*.jsonl`. This is local only, so it is refreshed every minute. A window whose reset time has passed is shown as reset.

```bash
cd dms
./install.sh            # builds the helper into ~/.local/bin and copies the plugin to ~/.config/DankMaterialShell/plugins
```

Then in DMS open **Settings → Plugins → Scan**, enable **AI Limit Counter** and add it to the bar. The provider and the helper path can be changed in the plugin settings.

Building the helper needs `cargo`, `dbus-devel` and `pkgconf-pkg-config` (Fedora package names).

Tests: `node --test dms/tests/format.test.js` and `cargo test --manifest-path linux/Cargo.toml`

## License

MIT
