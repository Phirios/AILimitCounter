# AILimitCounter

[![CI](https://github.com/Phirios/AILimitCounter/actions/workflows/ci.yml/badge.svg)](https://github.com/Phirios/AILimitCounter/actions/workflows/ci.yml)

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
- **Color-coded** — macOS/KDE use green, yellow, orange, and red usage levels; DMS/GNOME use provider accents with a warning at 85%+
- **Session percentage** — Shown as text next to the icon with a time-remaining progress bar underneath
- **Live indicator** — Pulsing dot when the selected AI CLI is actively running; auto-increases refresh rate to 1 min
- **Dropdown details** — Usage windows, reset times, status, and manual refresh; layout varies by desktop
- **Existing CLI login** — Uses Claude Code credentials and Codex usage data without a separate app account

## Platforms

| Desktop | Implementation | Codex data source |
| --- | --- | --- |
| macOS 14+ | Swift/AppKit menu bar app | Latest local Codex session log |
| KDE Plasma 6 | Rust backend and Plasma panel widget | Default signed-in Codex account via app-server |
| GNOME Shell 49 | Native JavaScript extension | Latest local Codex session log |
| DankMaterialShell (including Hyprland and niri) | QML bar plugin and Rust helper | Default signed-in Codex account via app-server |

## How It Works

### Claude Code

Makes a minimal API request (`max_tokens: 1`, Haiku model) to `api.anthropic.com` and reads the rate limit headers:

```
anthropic-ratelimit-unified-5h-utilization: 0.32
anthropic-ratelimit-unified-7d-utilization: 0.40
anthropic-ratelimit-unified-5h-reset: 1775523600
anthropic-ratelimit-unified-7d-reset: 1775862000
```

Each check makes a small Haiku inference request. Credentials come from the macOS
keychain or Linux `~/.claude/.credentials.json`, with a legacy token-file fallback.

### Codex

The Linux helper asks `codex app-server` for `account/rateLimits/read`, using Codex’s default signed-in account and `CODEX_HOME`. It selects only the ordinary `codex` quota, excluding reserve/model buckets. This is a read-only network usage check; it does not start an inference turn. Failed checks report an error instead of falling back to another account’s session logs.

The macOS app and GNOME extension still read local `~/.codex/sessions` logs. Their
numbers reflect the latest recorded usage and may come from a different account
than the current Codex login.

## Install

### macOS download

1. Download the latest `AILimitCounter-v*.zip` from [Releases](https://github.com/Phirios/AILimitCounter/releases)
2. Unzip and move `AILimitCounter.app` to `/Applications`
3. Sign in to Claude Code with `claude auth login`, or use Codex to produce a local usage report
4. Launch the app; Claude credentials are read from the keychain and cached automatically

> **Note:** macOS may show "unidentified developer" warning on first launch. Right-click the app and select Open, then click Open in the dialog.

### macOS build from source

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
cp AILimitCounter/Info.plist "$APP/"
open "$HOME/Applications/AILimitCounter.app"
```

### macOS launch at login (optional)

For an app installed in `/Applications`:

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/AILimitCounter.app", hidden:false}'
```

## macOS Menu Bar

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

## macOS Requirements

- macOS 14+
- Swift 5.9+ for building from source
- Claude Code authenticated via `claude auth login`, or Codex with local usage reports

---

## Linux (KDE Plasma)

The Linux version combines a Rust backend with a native Plasma 6 panel widget. The widget displays the circular limits, current percentage, remaining 5-hour time bar, and live indicator directly in the panel on both X11 and Wayland.

### Install dependencies (Arch / CachyOS)

```bash
sudo pacman -S rust dbus
```

On Fedora:

```bash
sudo dnf install cargo dbus-devel pkgconf-pkg-config
```

### Build

```bash
cd linux
cargo build --release --locked
```

Binary: `linux/target/release/ai-limit-counter`

Install the backend and Plasma widget:

```bash
install -Dm755 target/release/ai-limit-counter ~/.local/bin/ai-limit-counter
kpackagetool6 --type Plasma/Applet --install plasmoid
```

### CLI login

```bash
claude auth login   # for Claude usage
codex login         # for Codex usage; sign in with ChatGPT
```

The backend reads Claude Code's local credentials automatically. For Codex, install
the CLI on PATH or in `~/.local/bin`; the helper prefers the executable on PATH.

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

## Linux (DankMaterialShell)

A [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) bar plugin lives in `dms/`, for niri and the other compositors DMS runs on. It shows a ring and the 5-hour percentage in the bar. Clicking it opens a panel with **Claude | GPT** tabs, each showing the 5-hour and weekly windows, a plan badge, a live indicator and a refresh button.

The plugin gets its numbers from the Rust helper in `linux/` (`ai-limit-counter --json <provider>`), so it shares its data sources with the KDE build:

- **Claude:** reads the OAuth token Claude Code keeps in `~/.claude/.credentials.json` (the `~/.claude/claude-menubar-token` file still works as a fallback). It polls only while Claude is the selected provider: every 5 min, or every minute while `claude` is running.
- **GPT (Codex):** asks the installed `codex` CLI for the default signed-in account’s ordinary quota every minute. Requires `codex` on PATH or in `~/.local/bin` and a ChatGPT login. Reserve/model quotas and session logs are excluded; a failed check clears the displayed Codex usage.

```bash
cd dms
./install.sh            # builds the helper into ~/.local/bin and copies the plugin to ~/.config/DankMaterialShell/plugins
```

Then in DMS open **Settings → Plugins → Scan**, enable **AI Limit Counter** and add it to the bar. The provider and the helper path can be changed in the plugin settings.

Building the helper needs `cargo`, `dbus-devel` and `pkgconf-pkg-config` (Fedora package names).

Tests: `node --test dms/tests/format.test.js` and `cargo test --manifest-path linux/Cargo.toml`

### Refresh and troubleshooting

The panel's refresh button forces a new request for the selected provider. It shows
**Updating…** while the helper runs, then updates the data age. Percentages stay the
same when the provider reports unchanged usage.

- **Could not start codex:** ensure the CLI is on PATH or in `~/.local/bin`. The
  fallback supports desktop sessions whose PATH omits that directory.
- **Codex quota request failed:** check the default Codex login. The DMS plugin
  clears old Codex numbers on failure to avoid showing another account's usage.
- **Helper not found:** run `dms/install.sh` from the repository root, or correct
  the helper path in the plugin settings.

To inspect the helper's report directly:

```bash
~/.local/bin/ai-limit-counter --json codex
~/.local/bin/ai-limit-counter --json claude
```

## Development and CI

[GitHub Actions](https://github.com/Phirios/AILimitCounter/actions/workflows/ci.yml)
runs on every push and pull request, with a manual run option:

| Job | Checks |
| --- | --- |
| Linux helper | Rust unit tests and release build with the locked dependencies |
| DMS and GNOME extensions | Formatting tests, strict GNOME schema validation, installer script syntax |
| macOS app | Swift release build |

Run the checks locally from the repository root:

```bash
cargo test --locked --manifest-path linux/Cargo.toml
cargo build --release --locked --manifest-path linux/Cargo.toml
node --test dms/tests/format.test.js
gjs -m gnome/tests/format.test.js
glib-compile-schemas --strict --dry-run gnome/ailimitcounter@firatege.github.io/schemas
bash -n dms/install.sh gnome/install.sh
# On macOS:
swift build -c release
```

These checks cover builds and automated tests. Desktop integration and visible
widget behavior still need verification in the target desktop session.

## License

MIT
