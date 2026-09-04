# 2FA codes from Messages, without the copy-paste

macOS autofills verification codes in Safari and nowhere else. If you sign in
anywhere in Chrome, a terminal, or a native app, you are back to reading digits
off a notification and typing them by hand.

This watches Messages for incoming verification codes and puts a notification on
screen the moment one arrives. Click it and the code is typed into whatever app
you were using, followed by Return.

```
2FA code: 481902
Click to type it into Google Chrome.                     [ Options ⌄ ]
```

There is also a Raycast command for pulling the most recent code on demand,
which is the fallback for a notification you dismissed or missed.

## How it works

```
Messages ──> chat.db ──FSEvents──> twofa.lua ──> notification ──click──> keystrokes
                          │
                          └──> find-2fa-codes.sh  (all matching rules live here)
```

Three pieces, deliberately split so the matching rules have exactly one home:

| File | Role |
| --- | --- |
| `scripts/find-2fa-codes.sh` | Detection only. Reads `chat.db`, prints `rowid⇥code⇥sender`. No side effects — never types, copies, or notifies. |
| `hammerspoon/twofa.lua` | Watches for new messages, posts the notification, handles the actions. |
| `scripts/paste-latest-2fa.sh` | Raycast command. Types the newest code on a hotkey. |
| `tests/matcher-test.sh` | Fixture tests for the matcher, no database required. |

A [Hammerspoon](https://www.hammerspoon.org) config hosts the watcher because
notification action buttons require a real signed `.app` bundle — a shell script
cannot post one, and `osascript display notification` has no buttons at all.

New messages are picked up via FSEvents on `~/Library/Messages`, so the
notification lands about as fast as the one from Messages itself. A 15-second
timer runs behind it as a safety net in case a filesystem event is missed.

## What counts as a code

A message must contain an OTP-ish keyword (`code`, `otp`, `verification`,
`passcode`, `2fa`, …) before any digits in it are trusted. That alone stops
street numbers and order numbers from being offered as codes.

Then phone numbers are **deleted from the text** before matching, and what
remains is scanned for unbroken runs of 4–8 digits.

Removing phone numbers first is the whole trick. `1-800-632-4600` contains
`800-632`, and an earlier version of this script joined that into `800632` and
served it up as a six-digit verification code — beating the real one. Length
alone cannot fix this: raise the floor to six and you lose the genuine
four-digit codes that DICE, Name.com and others send.

Bare years (`19xx`, `20xx`) are excluded by hand, being the one four-digit shape
common enough in ordinary messages to matter.

Known false positives, if a message also contains a keyword: card last-four
(`card ending in 1184`) and door codes quoted inside tapback reactions
(`Liked "door code 4255"`).

## Requirements

- macOS with Messages signed in and SMS forwarding on
- [Hammerspoon](https://www.hammerspoon.org)
- [Raycast](https://raycast.com) — optional, only for the on-demand command

## Install

Clone anywhere, then link the two files Hammerspoon needs into `~/.hammerspoon`:

```bash
git clone https://github.com/cemre/messages-2fa.git && cd messages-2fa
ln -sfn "$PWD/hammerspoon/twofa.lua"      ~/.hammerspoon/twofa.lua
ln -sfn "$PWD/scripts/find-2fa-codes.sh"  ~/.hammerspoon/find-2fa-codes.sh
```

Add one line to `~/.hammerspoon/init.lua`:

```lua
twofa = require("twofa").start()
```

Optional, for the Raycast command:

```bash
ln -sfn "$PWD/scripts/paste-latest-2fa.sh" ~/.config/raycast/scripts/paste-latest-2fa.sh
```

Reload the Hammerspoon config, then grant it these — the first two are silent
failures if you skip them:

| Setting | Where | Why |
| --- | --- | --- |
| Full Disk Access | Privacy & Security | reading `chat.db` |
| Accessibility | Privacy & Security | typing the code |
| Notifications: **Alerts** | Notifications | banners hide the buttons and auto-dismiss |
| Launch at login | Hammerspoon Preferences | surviving a reboot |

Verify it loaded:

```bash
tail -1 ~/Library/Logs/2fa-watch.log     # -> "started at rowid NNNNNN"
```

Then fire a test notification from the Hammerspoon Console (menu bar → Console):

```lua
twofa.testNotify()
```

## Using it

Click the notification body to type the code into the app you were in, followed
by Return. **Options** offers **Paste** (the same thing) and **Copy**, which
puts it on the clipboard instead.

The Copy action tags the clipboard `org.nspasteboard.ConcealedType`, the
convention clipboard managers watch, so Raycast's history will not retain your
codes.

Clicking a notification's body activates the app that posted it, which would
otherwise mean the keystrokes land in Hammerspoon instead of your login form. So
the app that was in front when the code arrived is recorded, and focus is handed
back to it — but only when Hammerspoon itself ended up in front. If you moved to
some other app deliberately, the code is typed there and the window order is left
alone.

### It will not type into a chat app

Some apps transmit what you type. Typing a live code into one and pressing Return
does not fill a login form — it sends the code.

Messages is the case that bites. A code arrives while you are looking at the
conversation it arrived in, so Messages is the app that was in front, so Messages
is where focus gets handed back to on click. The code then goes into the compose
field, and Return sends it to whoever texted it to you.

So the frontmost app is checked immediately before any keystroke is emitted, and
a code is never typed into Messages, Slack, WhatsApp, Telegram, Discord, Signal,
or Hammerspoon itself. It is copied to the clipboard instead, with a message
saying so. Edit `NEVER_TYPE_INTO` at the top of `hammerspoon/twofa.lua` to add
your own.

The check runs at the last possible moment rather than at click time, so it also
covers switching to a chat app between the notification appearing and clicking
it.

## Configuration

Top of `hammerspoon/twofa.lua`:

| Setting | Default | |
| --- | --- | --- |
| `pressReturn` | `true` | turn off if a site auto-submits on the last digit |
| `maxAgeMinutes` | `15` | older codes have expired anyway |
| `safetyPollSeconds` | `15` | fallback poll behind FSEvents |
| `refocusDelay` | `0.15` | pause after restoring focus, before typing |

Top of `scripts/find-2fa-codes.sh`: `MIN_DIGITS` / `MAX_DIGITS`, default 4 and 8.

## Tests

```bash
./tests/matcher-test.sh
```

The paste-target denylist is asserted separately. It needs the `hs` modules, so
run it from the Hammerspoon Console (menu bar icon → Console):

```lua
dofile("/absolute/path/to/tests/twofa-selftest.lua")
```

Fixtures run through `--stdin`, so no database, no permissions, no waiting for a
text. To replay the matcher over your real history instead, with codes masked:

```bash
./scripts/find-2fa-codes.sh --max-age 525600 --limit 20000 --mask
```

Worth doing after touching the rules — it is how the phone-number bug above was
found and measured.

## Privacy

`chat.db` is opened read-only. Nothing leaves your machine, and there is no
network code anywhere in this repo.

`~/Library/Logs/2fa-watch.log` records timestamps and outcomes only — never a
code:

```
2026-08-09 15:12:03 notified for 6-digit code
2026-08-09 15:12:11 restoring focus to Google Chrome
2026-08-09 15:12:11 typed 6-digit code
```

Anything that can read your verification codes can take over accounts protected
by them. Read `find-2fa-codes.sh` before you run it — it is 130 lines, most of
them comments.

## Troubleshooting

**The log says `notified` but nothing appeared.** Notifications are off for
Hammerspoon, or set to Banners. This failure is silent by design: `send()`
genuinely succeeded, and an app cannot see that macOS dropped its notification.

**No buttons on the notification.** They are behind **Options**; macOS hides
notification actions until you hover.

**`Can't read Messages database`.** Hammerspoon needs Full Disk Access. After
granting it, reload the config.

**Nothing is typed when you click.** Hammerspoon needs Accessibility. macOS
discards synthetic key events from apps without it, silently.

## License

MIT
