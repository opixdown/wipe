#!/bin/sh
# wipe installer for macOS:  curl -fsSL https://wipemode.vercel.app/install.sh | sh
set -e

a="\033[38;5;173m"; m="\033[38;5;245m"; b="\033[1m"; r="\033[0m"
dir="$HOME/.local/bin"
mkdir -p "$dir"

printf "\n   ${a}●${r} ${b}wipe${r}  ${m}installing…${r}"
# Download beside the old copy and swap it in; overwriting a running signed binary in
# place makes macOS kill it.
curl -fsSL "https://wipemode.vercel.app/dist/wipe-macos" -o "$dir/.wipe.new"
chmod +x "$dir/.wipe.new"
mv -f "$dir/.wipe.new" "$dir/wipe"

# Make `wipe` work in new terminal windows.
case ":$PATH:" in
  *":$dir:"*) ;;
  *) grep -qs '.local/bin' "$HOME/.zshrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc" ;;
esac

printf "\r\033[K   ${a}✓${r} ${b}wipe${r}  ${m}installed — next time just type${r} wipe\n"

# Open the menu. stdin is the pipe from curl, so read keys from the terminal.
if [ -r /dev/tty ]; then exec "$dir/wipe" </dev/tty; fi
