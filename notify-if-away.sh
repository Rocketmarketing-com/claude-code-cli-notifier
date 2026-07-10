#!/bin/bash
# claude-code-notifier — desktop notifications for Claude Code, only when
# you're actually not watching. https://github.com/Rocketmarketing-com/claude-code-notifier
#
# macOS only: relies on osascript, ioreg, and (optionally) terminal-notifier,
# none of which exist on Linux/Windows.
#
# Notification policy:
# - Focus/DND active -> stay silent (hard gate, checked first).
# - Terminal not frontmost (or, for Terminal.app, a different tab/window is
#   frontmost) -> ping immediately, you're clearly not watching this session.
# - This session's window/tab is frontmost -> wait IDLE_THRESHOLD seconds,
#   then re-check frontmost/tab-match (catches switching away mid-wait, e.g.
#   to a browser) and system-wide idle time; only ping if you never came back
#   and/or went idle the whole time.
# - Separately, a detached background watcher fires a distinct "are you
#   there?" nudge if this same prompt/turn is STILL unanswered after
#   WAIT_NUDGE_THRESHOLD seconds -- covers the case where you were watching
#   at t=0 (so the immediate check above stayed silent) but wandered off
#   before actually answering. A marker file per session_id, holding a fresh
#   token each time this script runs in hook mode, lets a later event cancel
#   a stale watcher: --clear (wired to UserPromptSubmit and PreToolUse)
#   deletes the marker the moment you've clearly responded (typed a new
#   message, or Claude resumed calling tools after your answer).
#
# Modes:
#   (no args)   hook mode -- reads Stop/Notification JSON from stdin
#   --watch MARKER TOKEN TITLE TERM_APP BUNDLE_ID OUR_TTY
#               detached follow-up nudge (internal use, spawned by hook mode)
#   --clear     cancels a pending nudge, reads session_id from stdin
#
# Configuration (env vars, or set them in a config file -- see below):
#   NOTIFY_IDLE_THRESHOLD       seconds of inactivity before the immediate
#                                check fires                        (default: 15)
#   NOTIFY_WAIT_NUDGE_THRESHOLD seconds before the "are you there?"
#                                follow-up fires                    (default: 60)
#   NOTIFY_SOUND                notification sound name             (default: Ping)
#   NOTIFY_NUDGE_TEXT           body text for the follow-up nudge
#                                (default: "Are you there?")
#   NOTIFY_DND_CHECK            "0" to skip the Focus/DND gate entirely
#                                (default: "1")
#   NOTIFY_NUDGE_ENABLED        "0" to disable the "are you there?"
#                                follow-up entirely                 (default: "1")
#
# Config file: if $HOME/.config/claude-code-notifier/config exists (or
# $NOTIFY_CONFIG_FILE points somewhere else), it's sourced before applying
# defaults, so you can set the vars above there instead of exporting them in
# your shell. See config.example in this repo.

CONFIG_FILE="${NOTIFY_CONFIG_FILE:-$HOME/.config/claude-code-notifier/config}"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

IDLE_THRESHOLD="${NOTIFY_IDLE_THRESHOLD:-15}"
WAIT_NUDGE_THRESHOLD="${NOTIFY_WAIT_NUDGE_THRESHOLD:-60}"
SOUND="${NOTIFY_SOUND:-Ping}"
NUDGE_TEXT="${NOTIFY_NUDGE_TEXT:-Are you there?}"
DND_CHECK_ENABLED="${NOTIFY_DND_CHECK:-1}"
NUDGE_ENABLED="${NOTIFY_NUDGE_ENABLED:-1}"

# ---- shared helpers (used by both hook mode and --watch mode) ----

# Best-supported: Terminal.app (full tab-level correlation). Others get
# app-level-only frontmost detection -- see README "Terminal support".
term_app_for() {
  case "$1" in
    Apple_Terminal) echo "Terminal:com.apple.Terminal" ;;
    iTerm.app) echo "iTerm2:com.googlecode.iterm2" ;;
    vscode) echo "Code:com.microsoft.VSCode" ;;
    WarpTerminal) echo "Warp:dev.warp.Warp-Stable" ;;
    Hyper) echo "Hyper:co.zeit.hyper" ;;
    ghostty) echo "Ghostty:com.mitchellh.ghostty" ;;
    *) echo ":" ;;
  esac
}

# Requires Full Disk Access granted to your terminal app (System Settings ->
# Privacy & Security) to read this TCC-protected file. Fails open (treats
# unreadable as "not in DND") rather than silently swallowing notifications
# forever if that permission is never granted. Set NOTIFY_DND_CHECK=0 to skip
# this entirely.
is_dnd_active() {
  [ "$DND_CHECK_ENABLED" = "1" ] || return 1
  local db="$HOME/Library/DoNotDisturb/DB/Assertions.json" json
  [ -r "$db" ] || return 1
  json=$(plutil -convert json -o - "$db" 2>/dev/null) || return 1
  printf '%s' "$json" | jq -e '
    (.data // empty) | (if type == "array" then . else [.] end)
    | .[] | (.storeAssertionRecords // [])[]?
  ' >/dev/null 2>&1
}

# Prints "yes" if $1 (term app name) is frontmost and, for Terminal.app, $2
# (our tty, /dev/ttysNNN) matches the frontmost tab. Fails safe to "no" (i.e.
# notify) if any AppleScript step errors, rather than staying silent on a
# scripting hiccup.
is_our_window_frontmost() {
  local term_app="$1" our_tty="$2" frontmost front_tty
  frontmost=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)

  if [ -z "$term_app" ] || [ "$frontmost" != "$term_app" ]; then
    echo no
    return
  fi

  if [ "$term_app" = "Terminal" ] && [ -n "$our_tty" ]; then
    front_tty=$(osascript -e 'tell application "Terminal" to get tty of selected tab of front window' 2>/dev/null)
    if [ -z "$front_tty" ] || [ "$front_tty" != "$our_tty" ]; then
      echo no
    else
      echo yes
    fi
    return
  fi

  echo yes
}

# notify TITLE MESSAGE TERM_APP BUNDLE_ID OUR_TTY
notify() {
  local title="$1" message="$2" term_app="$3" bundle_id="$4" our_tty="$5"

  if ! command -v terminal-notifier >/dev/null 2>&1; then
    local esc
    esc=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')
    osascript -e "display notification \"$esc\" with title \"$title\" sound name \"$SOUND\"" 2>/dev/null
    return
  fi

  if [ "$term_app" = "Terminal" ] && [ -n "$our_tty" ]; then
    local script
    script=$(mktemp /tmp/claude-notify-focus.XXXXXX)
    cat > "$script" <<EOF
on run
  tell application "Terminal"
    repeat with w in windows
      repeat with tb in tabs of w
        if tty of tb is "$our_tty" then
          set selected of tb to true
          set index of w to 1
          activate
          return
        end if
      end repeat
    end repeat
  end tell
end run
EOF
    terminal-notifier -title "$title" -message "$message" -sound "$SOUND" \
      -execute "osascript '$script'" >/dev/null 2>&1
  elif [ -n "$bundle_id" ]; then
    terminal-notifier -title "$title" -message "$message" -sound "$SOUND" \
      -activate "$bundle_id" >/dev/null 2>&1
  else
    terminal-notifier -title "$title" -message "$message" -sound "$SOUND" >/dev/null 2>&1
  fi
}

# ---- --watch: detached background nudge for a still-unanswered prompt ----
if [ "$1" = "--watch" ]; then
  MARKER="$2"; TOKEN="$3"; TITLE="$4"; TERM_APP="$5"; BUNDLE_ID="$6"; OUR_TTY="$7"

  sleep "$WAIT_NUDGE_THRESHOLD"

  # A newer wait period (this session's next Stop/Notification) or a --clear
  # (you responded) has since overwritten/removed the marker -> stale, skip.
  [ "$(cat "$MARKER" 2>/dev/null)" = "$TOKEN" ] || exit 0

  is_dnd_active && exit 0
  [ "$(is_our_window_frontmost "$TERM_APP" "$OUR_TTY")" = "yes" ] && exit 0

  notify "$TITLE" "$NUDGE_TEXT" "$TERM_APP" "$BUNDLE_ID" "$OUR_TTY"
  exit 0
fi

# ---- --clear: cancel any watcher for this session, we're no longer waiting ----
if [ "$1" = "--clear" ]; then
  INPUT=$(cat)
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  [ -n "$SESSION_ID" ] && rm -f "/tmp/claude-notify-wait-$SESSION_ID"
  exit 0
fi

# ---- normal hook mode (Stop / Notification) ----
INPUT=$(cat)

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# Stop events carry the response in last_assistant_message; Notification
# events (e.g. AskUserQuestion / permission prompts) only have a generic
# "message" field instead.
LAST_MSG=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // .message // empty' 2>/dev/null)

PROJECT=$(basename "${CWD:-}")
[ -z "$PROJECT" ] && PROJECT="Claude Code"

TITLE="Claude Code — $PROJECT"
[ "$EVENT" = "Notification" ] && TITLE="Claude Code — $PROJECT (needs you)"

SNIPPET=$(printf '%s' "$LAST_MSG" | tr '\n' ' ' | cut -c1-80)
if [ "${#LAST_MSG}" -gt 80 ]; then
  SNIPPET="${SNIPPET}…"
fi
[ -z "$SNIPPET" ] && SNIPPET="Response ready"

IFS=: read -r TERM_APP BUNDLE_ID <<< "$(term_app_for "$TERM_PROGRAM")"

# This session's own tty. The hook's own fd 0 isn't a tty (async execution),
# but the process tree above it still carries the real controlling terminal,
# so walk up until we find it.
our_tty() {
  local pid=$PPID t
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$pid" ] && break
    t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -n "$t" ] && [ "$t" != "??" ]; then
      printf '/dev/%s\n' "$t"
      return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  return 1
}
OUR_TTY=$(our_tty)

# Start the "are you there?" watcher immediately (before the existing
# idle-threshold wait below), fully detached so it outlives this hook
# process/timeout. TERM_APP/BUNDLE_ID/OUR_TTY are passed as args rather than
# recomputed in --watch mode, since by the time it fires its process
# ancestry may no longer trace back to the controlling terminal. Skipped
# entirely if NOTIFY_NUDGE_ENABLED=0.
if [ "$NUDGE_ENABLED" = "1" ] && [ -n "$SESSION_ID" ]; then
  MARKER="/tmp/claude-notify-wait-$SESSION_ID"
  TOKEN="$$-$(date +%s%N)"
  printf '%s' "$TOKEN" > "$MARKER" 2>/dev/null
  nohup "$0" --watch "$MARKER" "$TOKEN" "$TITLE" "$TERM_APP" "$BUNDLE_ID" "$OUR_TTY" \
    >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

if is_dnd_active; then
  exit 0
fi

if [ "$(is_our_window_frontmost "$TERM_APP" "$OUR_TTY")" != "yes" ]; then
  notify "$TITLE" "$SNIPPET" "$TERM_APP" "$BUNDLE_ID" "$OUR_TTY"
  exit 0
fi

sleep "$IDLE_THRESHOLD"

if [ "$(is_our_window_frontmost "$TERM_APP" "$OUR_TTY")" != "yes" ]; then
  notify "$TITLE" "$SNIPPET" "$TERM_APP" "$BUNDLE_ID" "$OUR_TTY"
  exit 0
fi

idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')

if [ "${idle:-0}" -ge "$IDLE_THRESHOLD" ]; then
  notify "$TITLE" "$SNIPPET" "$TERM_APP" "$BUNDLE_ID" "$OUR_TTY"
fi
