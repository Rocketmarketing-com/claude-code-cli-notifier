# claude-code-notifier

Desktop notifications for [Claude Code](https://claude.com/claude-code), but
only when you're actually not watching — no noise while you're sitting there
reading the terminal.

> **macOS only.** This relies on `osascript`, `ioreg`, and macOS's Do Not
> Disturb database, none of which exist on Linux or Windows. It will not
> work on those platforms — the installer checks for macOS and refuses to
> run anywhere else.

## What it does

- **Task done / Claude needs input** → you get a notification, but only if
  you're plausibly not looking: the terminal isn't frontmost, or it's been
  idle the whole time you weren't looking.
- **Actively watching the terminal** → stays completely silent.
- **Focus / Do Not Disturb is on** → stays completely silent, no matter what.
- **You saw the first notification but then wandered off before actually
  answering** → a second, distinct "Are you there?" nudge fires after a
  configurable delay if the prompt is still unanswered — cancelled the
  instant you respond.
- Clicking a notification (macOS only, requires `terminal-notifier`) jumps
  you straight back to the exact terminal tab that session is running in.

## Requirements

- macOS
- [`jq`](https://jqlang.org/) — `brew install jq`
- [`terminal-notifier`](https://github.com/julienXX/terminal-notifier)
  (optional but recommended) — `brew install terminal-notifier`. Without it,
  notifications still work via plain `osascript`, just without click-to-focus.

## Install

```bash
git clone https://github.com/Rocketmarketing-com/claude-code-notifier.git
cd claude-code-notifier
./install.sh
```

The installer:
1. Checks you're on macOS and that `jq` is installed.
2. Offers to install `terminal-notifier` via Homebrew if it's missing.
3. Copies `notify-if-away.sh` to `~/.claude/scripts/`.
4. Adds the required hooks to `~/.claude/settings.json` — creates the file if
   it doesn't exist, or asks for confirmation and takes a `.bak` backup
   before editing an existing one. If you already have `Stop` /
   `Notification` / `UserPromptSubmit` / `PreToolUse` hooks configured, it
   won't touch your file — it prints the snippet from `examples/hooks.json`
   for you to merge in by hand instead.

Restart Claude Code (or start a new session) afterwards to pick up the hooks.

### Manual install

If you'd rather not run the installer: copy `notify-if-away.sh` to
`~/.claude/scripts/notify-if-away.sh` (`chmod +x` it), then merge the
contents of [`examples/hooks.json`](examples/hooks.json) into the `hooks` key
of your `~/.claude/settings.json`.

## Configuration

Everything is controlled by environment variables. Set them directly, or copy
[`config.example`](config.example) to `~/.config/claude-code-notifier/config`
and edit it there — the script sources that file automatically if it exists.

| Variable | Default | Purpose |
|---|---|---|
| `NOTIFY_IDLE_THRESHOLD` | `15` | Seconds the terminal must sit unfocused/idle before the immediate notification fires. |
| `NOTIFY_WAIT_NUDGE_THRESHOLD` | `60` | Seconds before the "Are you there?" follow-up nudge fires, if a prompt is still unanswered. |
| `NOTIFY_SOUND` | `Ping` | Notification sound name (see `/System/Library/Sounds`, or `default`). |
| `NOTIFY_NUDGE_TEXT` | `Are you there?` | Body text of the follow-up nudge. |
| `NOTIFY_DND_CHECK` | `1` | Set to `0` to skip the Focus/Do Not Disturb gate entirely (always notify, even during Focus). |
| `NOTIFY_IMMEDIATE_ENABLED` | `1` | Set to `0` to disable the initial "task done" / "needs you" notification entirely. |
| `NOTIFY_NUDGE_ENABLED` | `1` | Set to `0` to disable the follow-up nudge entirely — only the one immediate notification. |

Both notifications can be turned on and off independently — e.g. set
`NOTIFY_IMMEDIATE_ENABLED=0` with `NOTIFY_NUDGE_ENABLED=1` to skip the first
ping and only get notified if a prompt goes truly unanswered, or vice versa.

## Terminal app support

Frontmost-app detection works everywhere. **Window/tab-level precision** (so
switching to a *different* tab in the same app doesn't count as "watching")
currently only works for **Terminal.app** — everything else falls back to
app-level detection only (any window of that app being frontmost counts as
"watching," even an unrelated tab).

| Terminal | Frontmost detection | Tab-level precision |
|---|---|---|
| Terminal.app | ✅ | ✅ |
| iTerm2 | ✅ | ❌ (no tty exposed via its modern scripting API) |
| VS Code | ✅ | ❌ |
| Warp | ✅ | ❌ |
| Ghostty | ✅ | ❌ |
| Hyper | ✅ | ❌ |
| Other | ❌ (treated as always "not watching," i.e. you'll get notified) | ❌ |

This is a known, industry-wide unsolved scripting limitation, not a bug in
this project — see the comments in `notify-if-away.sh` if you want to try
extending it for another terminal.

## Do Not Disturb detection needs one manual step

Reading Focus/DND state requires **Full Disk Access** granted to your
terminal app (it's a TCC-protected file, even though it's your own data):

**System Settings → Privacy & Security → Full Disk Access → add your
terminal app** (Terminal, iTerm2, etc.)

Without this, the check fails *open* — it assumes you're not in Do Not
Disturb rather than silently swallowing every notification forever. Set
`NOTIFY_DND_CHECK=0` if you'd rather skip this entirely and never bother
granting the permission.

## Troubleshooting

**Notifications silently stopped working, even though System Settings looks
correct (Allow Notifications is on).**

macOS's notification daemons (`usernoted`, `NotificationCenter`,
`UserNotificationCenter`) can cache a stale, pre-permission-grant state if
they've been running for a long time. Restart them (safe, they respawn
instantly):

```bash
killall usernoted NotificationCenter UserNotificationCenter
```

**No notification at all, ever.** Confirm the script is executable
(`chmod +x ~/.claude/scripts/notify-if-away.sh`) and that your
`~/.claude/settings.json` hooks point at the right path. Test the script
directly:

```bash
echo '{"cwd":"'"$PWD"'","hook_event_name":"Stop","last_assistant_message":"test"}' \
  | ~/.claude/scripts/notify-if-away.sh
```

## Uninstall

```bash
rm ~/.claude/scripts/notify-if-away.sh
```

Then remove the `Stop`, `Notification`, `UserPromptSubmit`, and
`PreToolUse` entries this project added from `~/.claude/settings.json`
(or restore your `.bak` if `install.sh` created one).

## How it works, in more detail

The script (`notify-if-away.sh`) runs as a Claude Code hook in three modes:

- **Hook mode** (default) — invoked by the `Stop` and `Notification` hooks,
  reads the event JSON from stdin, decides whether to notify.
- **`--watch`** — a detached background process, spawned by hook mode, that
  sleeps `NOTIFY_WAIT_NUDGE_THRESHOLD` seconds and fires the "Are you
  there?" nudge if nothing has cancelled it.
- **`--clear`** — invoked by the `UserPromptSubmit` and `PreToolUse` hooks,
  cancels a pending nudge the instant you respond.

Read the comments at the top of `notify-if-away.sh` for the full decision
logic — they're kept as the source of truth alongside the code.

## Known limitations

- **macOS only.** No Linux/Windows support, and none planned — the entire
  approach depends on macOS-specific APIs.
- **Multi-monitor / multi-Space blind spot**: a terminal window that's
  *visible* on a second display or Space, but doesn't have keyboard focus,
  can't be distinguished from "not watching" via AppleScript. This is
  resolved deliberately in favor of notifying — an occasional unwanted ping
  beats missing one and drifting off distracted.
- **Tab-level precision** only works for Terminal.app — see the table above.
- If you respond right as the nudge threshold hits and Claude's next reply
  is a tool-free response that itself takes a while to generate, you can get
  one harmless extra "Are you there?" nudge. Rare, not worth the complexity
  to fully close.

## License

[MIT](LICENSE)
