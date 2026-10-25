<div align="center">

# ● wipe

**Clean your screen and keyboard without shutting down.**

[Website](https://wipemode.vercel.app) · [Download](https://github.com/opixdown/wipe/releases/latest) · Mac & Windows · Free

</div>

---

## Contents

- [Install](#install)
- [Usage](#usage)
- [Modes](#modes)
- [Exit shortcut](#exit-shortcut)
- [Safety](#safety)
- [Project structure](#project-structure)
- [Build from source](#build-from-source)
- [License](#license)

## Install

**Mac**: paste into Terminal

```sh
curl -fsSL https://wipemode.vercel.app/install.sh | sh
```

**Windows**: paste into PowerShell

```powershell
irm https://wipemode.vercel.app/install.ps1 | iex
```

From then on, open a terminal and type `wipe`.

> **Mac, first run:** macOS asks you to allow your terminal under **System Settings → Privacy & Security → Accessibility**. Turn it on and wipe carries on by itself.

## Usage

| Command | What it does |
| --- | --- |
| `wipe` | Open the menu |
| `wipe screen black` | Black screen, keyboard locked |
| `wipe screen white` | White screen, keyboard locked |
| `wipe keyboard` | Lock every key |
| `wipe configure` | Change the exit shortcut |
| `wipe preview` | See the keyboard screen without locking anything |
| `wipe help` | Show all commands |

Options: `-t, --timeout <seconds>` sets how long until wipe unlocks by itself (default 120, max 1800).

## Modes

| Mode | Good for |
| --- | --- |
| **Black** | Dust and smudges show up best on black |
| **White** | Streaks and fingerprints, for a final pass |
| **Keyboard** | Wiping the keys. Every press is swallowed, including brightness, volume and media keys |

All three lock the keyboard, start instantly and cover every display.

## Exit shortcut

Hold <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>X</kbd> for one second. A ring fills while you hold it.

To change it, run `wipe configure`, press the new combination, then <kbd>↵</kbd> to save. It must include <kbd>Ctrl</kbd>, <kbd>⌥</kbd>/<kbd>Alt</kbd> or <kbd>⌘</kbd>/<kbd>Win</kbd>, so you can't hit it by accident while wiping. The setting is saved in `~/.config/wipe/config.json` on Mac and `%AppData%\wipe\config.json` on Windows.

## Safety

You can't get stuck in wipe:

- It **unlocks by itself** after the timeout (2 minutes by default).
- A **watchdog** releases the keyboard within about 2.5 seconds if wipe ever stops responding.
- If the terminal window is closed, wipe **quits right away**.
- The power button, Touch ID and <kbd>Ctrl</kbd> <kbd>Alt</kbd> <kbd>Del</kbd> belong to the system. wipe never blocks them.

## Project structure

```
wipe/
├── macos/        Mac app (Swift): CGEventTap keyboard lock + AppKit screens
├── windows/      Windows app (Go): low-level keyboard hook + Win32 screens
├── site/         website and installers, deployed to Vercel
│   ├── index.html
│   ├── install.sh     Mac installer
│   └── install.ps1    Windows installer
├── scripts/
│   ├── build.sh       build every binary into site/dist/
│   ├── deploy.sh      publish site/ to Vercel
│   └── release.sh     attach binaries to a GitHub release
└── .github/workflows/build.yml   CI: builds both apps on every push
```

## Build from source

You need Swift (Xcode Command Line Tools) for Mac and Go 1.21+ for Windows.

```sh
scripts/build.sh      # → site/dist/wipe-macos, wipe-windows-amd64.exe, wipe-windows-arm64.exe
scripts/deploy.sh     # publish the website and installers
scripts/release.sh    # create a GitHub release for the current version
```

To work on one platform only:

```sh
swift run --package-path macos wipe preview
cd windows && GOOS=windows go build .
```

The version number lives in `macos/Sources/wipe/main.swift` and `windows/main.go`.

## License

[MIT](LICENSE)
