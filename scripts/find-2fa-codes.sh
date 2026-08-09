#!/bin/zsh

# Finds verification codes in recent Messages history. Detection only -- this
# script has no side effects: it never touches the clipboard, types, or notifies.
# Both the Raycast pull path (paste-latest-2fa.sh) and the Hammerspoon push path
# (hammerspoon/twofa.lua) call this, so the matching rules have a single home.
#
# Output: TSV, oldest first, one line per match:
#     rowid <TAB> code <TAB> sender
#
# Exit codes:
#     0  ran fine (output may be empty -- no codes is a normal result)
#     1  could not read the Messages database (usually missing Full Disk Access)
#     2  bad arguments
#
# The caller must hold Full Disk Access. Raycast and Hammerspoon both do; a
# plain Terminal may not.

set -uo pipefail

DB="$HOME/Library/Messages/chat.db"
SINCE_ROWID=0     # 0 = no rowid floor, rely on --max-age alone
MAX_AGE_MIN=15    # 2FA codes expire fast, so old messages are noise
LOOKBACK=50       # cap rows pulled from sqlite per call
MASK=0
MAX_ROWID_ONLY=0
STDIN_MODE=0

# Only unbroken runs of this many digits count as a code. Anything split by a
# separator is rejected on purpose: "1-800-632-4600" contains "800-632", which
# an earlier version of this script happily served up as a verification code.
#
# The floor is 4 because DICE, Name.com and others really do send four-digit
# codes. That is only safe because phone numbers are removed from the text
# first -- otherwise the trailing group of every number in a message ("4600" in
# the example above) would look exactly like a code.
MIN_DIGITS=4
MAX_DIGITS=8

usage() {
  cat >&2 <<'EOF'
usage: find-2fa-codes.sh [--since-rowid N] [--max-age MINUTES] [--limit N]
                         [--mask] [--max-rowid] [--stdin]

  --since-rowid N   only consider messages with ROWID > N (default 0)
  --max-age MIN     ignore messages older than MIN minutes (default 15)
  --limit N         scan at most N recent messages (default 50)
  --mask            print codes as 1****6 -- for eyeballing results safely
  --max-rowid       print the highest message ROWID and exit; watchers use this
                    to set their starting floor so they don't fire on backlog
  --stdin           read "rowid<TAB>text<TAB>sender" lines from stdin instead of
                    the database, so the matcher can be tested against fixtures

Raising --limit and --max-age together replays the matcher over old history,
which is how to sanity-check the rules after editing them:
  find-2fa-codes.sh --max-age 525600 --limit 20000 --mask
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since-rowid)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      SINCE_ROWID="$2"; shift 2 ;;
    --max-age)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      MAX_AGE_MIN="$2"; shift 2 ;;
    --limit)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      LOOKBACK="$2"; shift 2 ;;
    --mask) MASK=1; shift ;;
    --max-rowid) MAX_ROWID_ONLY=1; shift ;;
    --stdin) STDIN_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! "$SINCE_ROWID" =~ ^[0-9]+$ ]] || [[ ! "$MAX_AGE_MIN" =~ ^[0-9]+$ ]] || [[ ! "$LOOKBACK" =~ ^[0-9]+$ ]]; then
  echo "--since-rowid, --max-age and --limit must be non-negative integers" >&2
  exit 2
fi

# Requires an OTP-ish keyword before trusting any digits, so a street number or
# order number in an unrelated text is never offered as a code. Reads
# "rowid<TAB>text<TAB>sender" on stdin, writes "rowid<TAB>code<TAB>sender".
match_codes() {
  MASK=$MASK MIN=$MIN_DIGITS MAX=$MAX_DIGITS /usr/bin/perl -ne '
    BEGIN {
      # A code is a run of digits with no digit on either side. The surrounding
      # characters are otherwise unconstrained, so "code:481902 Reply" and
      # "code is 481902." both work.
      $CODE = qr/(?<!\d)(\d{$ENV{MIN},$ENV{MAX}})(?!\d)/;
      $KEYWORD = qr/\b(?:code|otp|passcode|pass ?code|verification|verify|security|authentication|auth|2fa|one[- ]?time|token|pin)\b/i;

      # Phone numbers are deleted from the text before any code matching, so
      # their digit groups can never be offered as a code. Longest shapes come
      # first: alternation is first-match-wins, so putting the seven-digit local
      # form earlier would bite off the tail of a full number and leave the area
      # code stranded as a false candidate.
      $PHONE = qr/
          \+?\d{1,3}[-.\s]?\(?\d{3}\)?[-.\s]\d{3}[-.\s]\d{4}   # +1 (415) 676-4600, 1-800-632-4600
        | \(?\d{3}\)?[-.\s]\d{3}[-.\s]\d{4}                    # (415) 676-4600, 415.676.4600
        | (?<!\d)\d{3}[-.]\d{4}(?!\d)                          # 676-4600 local; separator only,
      /x;                                                      # a space here would eat real codes
    }
    chomp;
    my ($rowid, $text, $sender) = split /\t/, $_, 3;
    next unless defined $text && length $text;
    $sender = "" unless defined $sender;
    next unless $text =~ $KEYWORD;

    (my $scrubbed = $text) =~ s/$PHONE//g;

    my @c;
    while ($scrubbed =~ /$CODE/g) { push @c, $1 }

    # Only reachable now that the floor is 4: a bare year is the one four-digit
    # shape common enough in ordinary messages to be worth excluding by hand.
    @c = grep { !/^(?:19|20)\d\d$/ } @c;
    next unless @c;

    # Six digits is the overwhelmingly common OTP shape, so prefer it when a
    # message offers several candidates.
    my ($six) = grep { length($_) == 6 } @c;
    my $code = defined $six ? $six : $c[0];

    if ($ENV{MASK}) {
      $code = substr($code, 0, 1) . ("*" x (length($code) - 2)) . substr($code, -1);
    }
    print "$rowid\t$code\t$sender\n";
  '
}

if [[ $STDIN_MODE -eq 1 ]]; then
  match_codes
  exit 0
fi

if [[ $MAX_ROWID_ONLY -eq 1 ]]; then
  max=$(sqlite3 "file:$DB?mode=ro" -readonly "SELECT COALESCE(MAX(ROWID), 0) FROM message;" 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "Can't read Messages database: $max" >&2
    exit 1
  fi
  echo "$max"
  exit 0
fi

# Apple stores `date` as nanoseconds since 2001-01-01, so shift it to unix epoch
# before comparing. Tabs and newlines are stripped from the body so one message
# can never span or split a TSV field.
#
# `text IS NOT NULL` skips the ~18% of messages that carry their body in
# attributedBody instead. Verified against a year of history: zero verification
# codes land there, so decoding that blob would be cost with no benefit.
#
# The inner query takes the NEWEST $LOOKBACK rows, the outer one flips them back
# to oldest-first. Ordering ASC before the LIMIT would keep the oldest rows in
# the window and drop the newest -- i.e. throw away the code you are waiting for.
raw=$(sqlite3 "file:$DB?mode=ro" -readonly \
  "SELECT rid || char(9) || txt || char(9) || sender FROM (
     SELECT m.ROWID AS rid,
            replace(replace(replace(m.text, char(10), ' '), char(13), ' '), char(9), ' ') AS txt,
            COALESCE(h.id, '') AS sender
     FROM message m
     LEFT JOIN handle h ON m.handle_id = h.ROWID
     WHERE m.is_from_me = 0
       AND m.text IS NOT NULL AND m.text != ''
       AND m.ROWID > $SINCE_ROWID
       AND (m.date/1000000000 + strftime('%s','2001-01-01')) > (strftime('%s','now') - $((MAX_AGE_MIN * 60)))
     ORDER BY m.ROWID DESC
     LIMIT $LOOKBACK
   ) ORDER BY rid ASC;" 2>&1)

if [[ $? -ne 0 ]]; then
  echo "Can't read Messages database: $raw" >&2
  exit 1
fi

[[ -z "${raw//[[:space:]]/}" ]] && exit 0

printf '%s\n' "$raw" | match_codes
