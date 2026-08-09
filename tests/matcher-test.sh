#!/bin/zsh

# Fixture tests for the code matcher in find-2fa-codes.sh, driven through
# --stdin so no database or permissions are involved.
#
#   ./tests/matcher-test.sh
#
# Message bodies here are real-world shapes, with the digits changed.

FINDER="${0:A:h}/../scripts/find-2fa-codes.sh"
pass=0; fail=0

# check <description> <expected-code-or-NONE> <message text>
check() {
  local desc="$1" want="$2" text="$3"
  local got
  got=$(printf '1\t%s\tTEST\n' "$text" | "$FINDER" --stdin | cut -f2)
  [[ -z "$got" ]] && got="NONE"
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
    print -r -- "  ok       $desc"
  else
    fail=$((fail + 1))
    print -r -- "  FAIL     $desc"
    print -r -- "             want: $want"
    print -r -- "             got:  $got"
  fi
}

print -r -- "matcher fixtures:"

# The regression that started this: the toll-free number contains "800-632",
# which the old split-pair branch turned into the six-digit "800632" and then
# preferred over the real code.
check "phone number does not beat the real code" 753317 \
  'Provident verification code. Do not share this code with anyone:753317 Reply HELP or call 1-800-632-4600 Reply STOP to cancel Msg&Data rates may apply'

check "code with no space after colon" 488021 \
  'Provident verification code. Do not share this code with anyone:488021 Reply HELP or call 1-800-632-4600'

check "plain six-digit code" 123456 \
  'Your verification code is 123456'

check "code followed by a period" 654321 \
  'Your Apple ID code is 654321. Do not share it with anyone.'

check "eight-digit code" 12345678 \
  'Your security code: 12345678'

check "seven-digit code" 1234567 \
  'Use one-time code 1234567 to sign in'

# Split codes are deliberately unsupported -- allowing them is what let phone
# numbers in. A hyphenated code degrades to no match rather than a wrong one.
check "hyphenated code is not matched" NONE \
  'Your code is 123-456'

check "no keyword means no code, however code-shaped" NONE \
  'Package 483920 was delivered to your door'

# Four- and five-digit codes are in scope, so phone numbers have to be removed
# before matching rather than excluded by length.
check "four-digit code" 4823 \
  'Your DICE verification code is: 4823. It is made just for you.'

check "four-digit code beside a toll-free number" 7195 \
  'Name.com code: 7195. Valid for 3 minutes. Questions? Call 1-800-632-4600'

check "five-digit code" 48213 \
  'Your one-time code is 48213'

check "bare toll-free number with a keyword yields nothing" NONE \
  'For security questions call 1-800-632-4600'

check "dashed 10-digit number is not a code" NONE \
  'Your verification code expires soon, call 415-676-4600'

check "parenthesised area code is not a code" NONE \
  'For help with your security settings call (415) 676-4600'

check "dotted number is not a code" NONE \
  'Verification help: 415.676.4600'

check "local seven-digit number is not a code" NONE \
  'Call our security desk at 676-4600'

check "spaced international number is not a code" NONE \
  'Your account verification line: +1 415 676 4600'

check "year is not a code" NONE \
  'Your account security review for 2026 is complete'

check "real code still wins beside a phone number" 559213 \
  'Your verification code is 559213. Questions? call 1-800-632-4600'

check "longer digit run is not truncated into a code" NONE \
  'Your account number 12345678901234 needs verification'

check "prefers the six-digit candidate over other lengths" 998877 \
  'Your code is 998877, reference 12345678'

print -r --
if [[ $fail -eq 0 ]]; then
  print -r -- "all $pass passed"
  exit 0
else
  print -r -- "$pass passed, $fail failed"
  exit 1
fi
