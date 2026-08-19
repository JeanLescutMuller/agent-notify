#!/bin/bash
# Deploys the notify plugin (release_v4/) as a Claude Code user-scope plugin
# on this machine. Idempotent - safe to re-run.
#
# Each renderer lives in its own renderers.d/<name>/ folder (main executable
# + settings.json + optional install.sh for renderer-specific extra setup -
# e.g. sound-tts/install.sh deploys the Mac-side TTS listener). GUI-only,
# one-time-per-machine steps that can't be scripted at all (enabling
# iTerm2's Python API, the tic terminfo fix, tmux allow-passthrough) are
# documented in renderers.d/sound-tts/INSTALL.md and TODO.md.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/release_v4" && pwd)"
MARKETPLACE_ROOT="$HOME/.claude-templates-dev/components"
DEST="$MARKETPLACE_ROOT/plugins/notify"

echo "==> Deploying release_v4/ to $DEST"
mkdir -p "$DEST"
cp -R "$SRC"/. "$DEST"/
rm -f "$DEST/config.json"  # stale from an earlier renamed-then-reverted experiment; cp doesn't remove files no longer in source
chmod +x "$DEST/notify"
for f in "$DEST"/renderers.d/*/main; do
  # template/ is reference-only, deliberately never executable (skipped by discovery)
  [ "$(basename "$(dirname "$f")")" = "template" ] && continue
  chmod +x "$f"
done
for f in "$DEST"/renderers.d/*/install.sh; do
  [ -f "$f" ] && chmod +x "$f"
done

echo "==> Writing marketplace.json"
mkdir -p "$MARKETPLACE_ROOT/.claude-plugin"
cat > "$MARKETPLACE_ROOT/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "claude-templates-dev",
  "owner": {
    "name": "Jean Lescut-Muller"
  },
  "plugins": [
    {
      "name": "notify",
      "source": "./plugins/notify",
      "description": "Notification system for Claude Code sessions. Visual (pane bg, tab icons), sound (bell, TTS). Configure with: ! notify"
    }
  ]
}
EOF

echo "==> Registering marketplace (idempotent)"
if claude plugin marketplace list 2>/dev/null | grep -q "claude-templates-dev"; then
  echo "    already registered, skipping"
else
  claude plugin marketplace add "$MARKETPLACE_ROOT"
fi

echo "==> Enabling notify@claude-templates-dev at user scope (idempotent)"
if claude plugin list 2>/dev/null | grep -q "notify@claude-templates-dev"; then
  echo "    already installed, skipping"
else
  claude plugin install notify@claude-templates-dev --scope user
fi

echo "==> Running per-renderer install scripts (if any)"
for renderer_install in "$DEST"/renderers.d/*/install.sh; do
  [ -x "$renderer_install" ] || continue
  echo "    -> $(basename "$(dirname "$renderer_install")")/install.sh"
  "$renderer_install"
done

echo "==> Ensuring ~/.local/bin is on PATH (for the tmux menu + plain 'notify' CLI)"
if ! grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.zshrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
  echo "    added to ~/.zshrc"
else
  echo "    already present"
fi

echo "==> Done. Restart the Claude Code CLI for hooks to activate."
