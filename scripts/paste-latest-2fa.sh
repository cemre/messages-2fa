#!/bin/zsh

# Raycast Script Command
# @raycast.schemaVersion 1
# @raycast.title Paste Latest 2FA Code
# @raycast.mode silent
# @raycast.icon 🔐
# @raycast.packageName 2FA
# @raycast.description Types the newest SMS/iMessage verification code into the focused field.
# @raycast.author cemre

# The pull path: press the Raycast hotkey and the newest code gets typed. The
# push path (a notification the moment a code arrives) lives in
# hammerspoon/twofa.lua. This one is the fallback for when that notification was
# missed or dismissed.
#
# Finding the code is delegated to find-2fa-codes.sh so the matching rules have
# a single home. Run under Raycast, which already holds Full Disk Access,
# Accessibility, and Automation->System Events.
#
# Pass --dry-run to print a masked result instead of typing anything.

set -uo pipefail

# Records run time and outcome only -- never the code itself.
LOG="$HOME/.config/raycast/scripts/.2fa-run.log"
log() { echo "$(date '+%F %T') $1" >> "$LOG"; }
log "start"

# ${0:A} resolves symlinks, so this finds the sibling script whether it is run
# from the project directory or through the symlink in Raycast's script folder.
FINDER="${0:A:h}/find-2fa-codes.sh"

MAX_AGE_MIN=${MAX_AGE_MIN:-15}   # ignore codes older than this; 2FA codes expire fast

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ ! -x "$FINDER" ]]; then
  echo "Missing $FINDER"
  log "missing-finder"
  exit 1
fi

matches=$("$FINDER" --max-age "$MAX_AGE_MIN" 2>&1)
rc=$?

if [[ $rc -ne 0 ]]; then
  echo "Can't read Messages database: $matches"
  log "db-error"
  exit 1
fi

if [[ -z "${matches//[[:space:]]/}" ]]; then
  echo "No 2FA code found in the last ${MAX_AGE_MIN}m"
  log "no-code"
  exit 1
fi

# Output is oldest-first, so the newest code is the last line; field 2 is the code.
code=$(printf '%s\n' "$matches" | tail -1 | cut -f2)

if [[ -z "$code" ]]; then
  echo "No 2FA code found in the last ${MAX_AGE_MIN}m"
  log "no-code"
  exit 1
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "would type: ${code[1]}$(printf '%*s' $((${#code} - 2)) '' | tr ' ' '*')${code[-1]} (${#code} digits)"
  exit 0
fi

# Let Raycast dismiss and hand focus back to the app underneath before typing.
sleep 0.3

out=$(osascript -e "tell application \"System Events\" to keystroke \"$code\"" 2>&1)
if [[ $? -ne 0 ]]; then
  echo "Couldn't type code: $out"
  log "keystroke-failed: $out"
  exit 1
fi

log "typed ${#code}-digit code"
echo "Typed ${#code}-digit code"
