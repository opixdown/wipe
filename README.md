<div align="center">

# ● wipe

Clean your screen and keyboard without shutting down.

[**Website**](https://wipemode.vercel.app) · Mac & Windows · Free and open source

</div>

<br>

## Install

**Mac** · paste in Terminal

```sh
curl -fsSL https://wipemode.vercel.app/install.sh | sh
```

**Windows** · paste in PowerShell

```powershell
irm https://wipemode.vercel.app/install.ps1 | iex
```

Then just type `wipe`.

## Use

| Command | What it does |
| --- | --- |
| `wipe` | Pick a mode from the menu |
| `wipe screen black` | Black screen, keyboard locked |
| `wipe screen white` | White screen, keyboard locked |
| `wipe keyboard` | Lock every key |
| `wipe configure` | Change the exit shortcut |

**To exit**, hold <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>X</kbd> for one second.
It also unlocks by itself after 2 minutes.

## Good to know

- On a Mac, the first run asks you to allow your terminal under **Accessibility**.
- The power button and <kbd>Ctrl</kbd> <kbd>Alt</kbd> <kbd>Del</kbd> can't be blocked. They belong to the system.

## Build

```sh
scripts/build.sh     # Mac + Windows → site/dist/
scripts/deploy.sh    # publish site/ to Vercel
```

<br>

<div align="center"><sub>MIT · made for people who hate shutting down to clean</sub></div>
