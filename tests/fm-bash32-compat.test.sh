#!/usr/bin/env bash
# Guards macOS system bash 3.2 compatibility for every bin/ script.
#
# On a stock Mac, `#!/usr/bin/env bash` resolves to /bin/bash 3.2.57, whose
# $( ) scanner lexes quote characters inside heredoc BODIES: an unmatched
# ', ", or ` in a heredoc that lives inside command substitution aborts the
# whole parse ("unexpected EOF while looking for matching `''"), even though
# bash 4+ parses it fine. Matched pairs and backslash-escaped quotes are fine;
# quoting the heredoc delimiter does NOT help. Minimal repro (fails 3.2 only):
#
#   DOD=$(cat <<EOF
#   Follow no-mistakes' own guidance
#   EOF
#   )
#
# Three layers of protection:
#   1. `bash -n` on every bin/ script, using /bin/bash when present - on macOS
#      that IS bash 3.2, the real reproduction environment.
#   2. A portable awk lexer that emulates the bash 3.2 quote scan over every
#      heredoc body opened inside $( ) and flags any body left in an open
#      quote state. This is what guards the pattern on Linux CI, where the
#      system bash is 4+ and `bash -n` alone would pass the broken script.
#   3. A self-test feeding the lexer known-bad and known-good fixtures, so the
#      checker itself cannot rot into a silent no-op.
# Plus an end-to-end scaffold run of fm-brief.sh under the system bash, since
# the brief scaffolder is where this bug actually bit.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-bash32-tests.XXXXXX")

# Prefer the system bash: on macOS it is the 3.2 interpreter this suite exists
# to guard. On Linux it is a modern bash, and layer 2 covers the 3.2 quirk.
SYSBASH=/bin/bash
[ -x "$SYSBASH" ] || SYSBASH=$(command -v bash) || fail "no bash found"

# --- 1. every bin/ script must parse under the system bash -------------------

for script in "$ROOT"/bin/*.sh "$ROOT"/bin/backends/*.sh; do
  if ! err=$("$SYSBASH" -n "$script" 2>&1); then
    fail "bash -n ($SYSBASH): ${script#"$ROOT"/}: $err"
  fi
done
pass "all bin/ scripts parse under $SYSBASH ($("$SYSBASH" -c 'echo "$BASH_VERSION"'))"

# --- 2. bash 3.2 heredoc-in-$( ) quote lexer ---------------------------------
#
# Detects a heredoc opened on a line where `<<` follows `$(` (with no
# intervening parens, so $(( arithmetic )) never matches), then runs the body
# through the same quote lexing bash 3.2 applies while scanning for the
# closing paren: backslash escapes the next char, ' " ` open a quote, single
# quotes close only on ', double quotes and backticks honor backslash escapes.
# A body that reaches its delimiter still inside a quote is exactly what
# bash 3.2 rejects. The program is written to a file via a top-level quoted
# heredoc so this test itself stays 3.2-clean.

CHECKER="$TMP_ROOT/heredoc-quote-check.awk"
cat > "$CHECKER" <<'AWK'
in_hd {
  line = $0
  if (dash) sub(/^\t+/, "", line)
  if (line == delim) {
    if (q != "") {
      printf "%s:%d: unbalanced %s inside $( ) heredoc body (breaks macOS bash 3.2)\n", FILENAME, oline, q
      bad = 1
    }
    in_hd = 0
    q = ""
    next
  }
  n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (q == "") {
      if (c == "\\") i++
      else if (c == "'" || c == "\"" || c == "`") q = c
    } else if (q == "'") {
      if (c == "'") q = ""
    } else {
      if (c == "\\") i++
      else if (c == q) q = ""
    }
  }
  next
}
/\$\([^()]*<</ {
  s = $0
  sub(/.*<</, "", s)
  dash = 0
  if (substr(s, 1, 1) == "-") {
    dash = 1
    s = substr(s, 2)
  }
  ch = substr(s, 1, 1)
  if (ch == "'" || ch == "\"") s = substr(s, 2)
  if (match(s, /^[A-Za-z0-9_]+/)) {
    delim = substr(s, RSTART, RLENGTH)
    in_hd = 1
    q = ""
    oline = FNR
  }
  next
}
END {
  if (in_hd) {
    printf "%s:%d: heredoc inside $( ) never closed (delimiter %s not found)\n", FILENAME, oline, delim
    bad = 1
  }
  exit bad ? 1 : 0
}
AWK

# --- 3. self-test: the lexer must catch the original bug ---------------------

BAD_FIXTURE="$TMP_ROOT/bad.sh"
cat > "$BAD_FIXTURE" <<'FIXTURE'
DOD=$(cat <<EOF
Follow no-mistakes' own guidance
EOF
)
echo "$DOD"
FIXTURE

if awk -f "$CHECKER" "$BAD_FIXTURE" >/dev/null 2>&1; then
  fail "lexer self-test: known-bad fixture (the original fm-brief.sh bug) not flagged"
fi
pass "lexer self-test: unmatched apostrophe in \$( ) heredoc is flagged"

GOOD_FIXTURE="$TMP_ROOT/good.sh"
cat > "$GOOD_FIXTURE" <<'FIXTURE'
DOD=$(cat <<EOF
he said "don't" and escaped \' both lex fine, as does $(( 1 << 2 ))
EOF
)
echo "$DOD"
FIXTURE

if ! awk -f "$CHECKER" "$GOOD_FIXTURE" >/dev/null 2>&1; then
  fail "lexer self-test: balanced/escaped quotes false-positived"
fi
pass "lexer self-test: matched and escaped quotes pass"

for script in "$ROOT"/bin/*.sh "$ROOT"/bin/backends/*.sh; do
  if ! out=$(awk -f "$CHECKER" "$script" 2>&1); then
    fail "bash 3.2 heredoc quote check: $out"
  fi
done
pass "no bin/ script has an unbalanced quote inside a \$( ) heredoc"

# --- 4. fm-brief.sh scaffolds end to end under the system bash ---------------

FM_HOME_SHIP="$TMP_ROOT/home-ship"
mkdir -p "$FM_HOME_SHIP"
if ! FM_HOME="$FM_HOME_SHIP" "$SYSBASH" "$ROOT/bin/fm-brief.sh" bash32-e2e some-repo >/dev/null 2>&1; then
  fail "fm-brief.sh ship scaffold failed under $SYSBASH"
fi
SHIP_BRIEF="$FM_HOME_SHIP/data/bash32-e2e/brief.md"
[ -f "$SHIP_BRIEF" ] || fail "ship brief not written at $SHIP_BRIEF"
grep -q '{TASK}' "$SHIP_BRIEF" || fail "ship brief missing {TASK} placeholder"
grep -q '# Definition of done' "$SHIP_BRIEF" || fail "ship brief missing definition of done"
pass "fm-brief.sh scaffolds a ship brief under $SYSBASH"

FM_HOME_SCOUT="$TMP_ROOT/home-scout"
mkdir -p "$FM_HOME_SCOUT"
if ! FM_HOME="$FM_HOME_SCOUT" "$SYSBASH" "$ROOT/bin/fm-brief.sh" bash32-scout some-repo --scout >/dev/null 2>&1; then
  fail "fm-brief.sh scout scaffold failed under $SYSBASH"
fi
SCOUT_BRIEF="$FM_HOME_SCOUT/data/bash32-scout/brief.md"
[ -f "$SCOUT_BRIEF" ] || fail "scout brief not written at $SCOUT_BRIEF"
grep -q 'report.md' "$SCOUT_BRIEF" || fail "scout brief missing report contract"
pass "fm-brief.sh scaffolds a scout brief under $SYSBASH"

echo "fm-bash32-compat: all checks passed"
