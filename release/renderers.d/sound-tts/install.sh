#!/bin/bash
# Deploys notify_tts_async_say.py to iTerm2's AutoLaunch folder.
# Run automatically by the top-level install.sh - not meant to be run directly.
#
# Does NOT and cannot cover: enabling iTerm2's Python API, the tic terminfo
# fix for macOS, or allow-passthrough in ~/.tmux.conf - all manual, one-time,
# per-machine steps. See INSTALL.md in this directory.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "       skipped (sound-tts listener requires macOS/iTerm2)"
  exit 0
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOLAUNCH_DIR="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch"

mkdir -p "$AUTOLAUNCH_DIR"
cp "$SRC_DIR/notify_tts_async_say.py" "$AUTOLAUNCH_DIR/notify_tts_async_say.py"
echo "       notify_tts_async_say.py -> $AUTOLAUNCH_DIR"
echo "       (remaining manual steps, if not already done: see renderers.d/sound-tts/INSTALL.md)"
