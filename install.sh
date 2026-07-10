#!/bin/bash
# Installer for claude-code-cli-notifier. Safe to re-run.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DEST="$HOME/.claude/scripts/notify-if-away.sh"
SETTINGS="$HOME/.claude/settings.json"
HOOKS_SNIPPET="$REPO_DIR/examples/hooks.json"

echo "claude-code-cli-notifier installer"
echo

if [ "$(uname)" != "Darwin" ]; then
  echo "This tool is macOS-only (it relies on osascript, ioreg, terminal-notifier," >&2
  echo "and macOS's Do Not Disturb database — none of which exist on Linux or Windows)." >&2
  echo "Aborting." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not installed. Install it with:" >&2
  echo "  brew install jq" >&2
  exit 1
fi

if ! command -v terminal-notifier >/dev/null 2>&1; then
  echo "terminal-notifier isn't installed. It's optional (the script falls back to"
  echo "plain 'osascript' notifications without it) but recommended — it adds"
  echo "click-to-focus (clicking the notification jumps you back to that terminal tab)."
  read -r -p "Install it now with 'brew install terminal-notifier'? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    brew install terminal-notifier
  else
    echo "Skipping terminal-notifier — falling back to plain notifications."
  fi
  echo
fi

mkdir -p "$HOME/.claude/scripts"
cp "$REPO_DIR/notify-if-away.sh" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"
echo "Installed script to $SCRIPT_DEST"
echo

if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$HOME/.claude"
  jq '{hooks: .}' "$HOOKS_SNIPPET" > "$SETTINGS"
  echo "Created $SETTINGS with the notify hooks."
else
  EXISTING=$(jq '[.hooks.Stop, .hooks.Notification, .hooks.UserPromptSubmit, .hooks.PreToolUse] | map(select(. != null)) | length' "$SETTINGS" 2>/dev/null || echo 0)
  if [ "$EXISTING" -gt 0 ]; then
    echo "$SETTINGS already has Stop/Notification/UserPromptSubmit/PreToolUse hooks configured."
    echo "Not touching it automatically — merge these in by hand from examples/hooks.json:"
    echo
    cat "$HOOKS_SNIPPET"
    exit 0
  fi

  echo "About to add the notify hooks to $SETTINGS (a backup will be saved to $SETTINGS.bak first)."
  read -r -p "Proceed? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    cp "$SETTINGS" "$SETTINGS.bak"
    jq -s '.[0] * {hooks: .[1]}' "$SETTINGS" "$HOOKS_SNIPPET" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
    echo "Updated $SETTINGS (backup at $SETTINGS.bak)."
  else
    echo "Skipped. Merge these hooks into $SETTINGS by hand:"
    echo
    cat "$HOOKS_SNIPPET"
  fi
fi

echo
echo "Done. Start a new Claude Code session to pick up the hooks."
echo
echo "Optional next steps:"
echo "  - Copy config.example to ~/.config/claude-code-cli-notifier/config to customize"
echo "    thresholds, sound, or turn features off."
echo "  - Grant your terminal app Full Disk Access (System Settings > Privacy &"
echo "    Security > Full Disk Access) so the Do Not Disturb check can engage."
echo "    See README.md for details."
