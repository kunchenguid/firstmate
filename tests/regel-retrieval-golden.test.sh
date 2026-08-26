#!/usr/bin/env bash
# tests/regel-retrieval-golden.test.sh - the colocated check of the golden
# retrieval fixture tests/regel-retrieval-golden.tsv.
#
# OWNER SPLIT. bin/fm-regel-eval.sh (`run`, golden retrieval section) owns the
# armed pass/fail verdict of the suite and fixes the geltung it queries as.
# This test owns the fixture itself - the thing the gate would otherwise read
# without ever checking:
#
#   1. Shape: every data row is exactly <prompt><TAB><rule-id>, both non-empty,
#      the id in ID form. A row with a stray second tab or a missing id would
#      make the gate skip it silently (`[ -n "$want" ] || continue`), so a
#      malformed row is an invisible hole in the suite, not a loud error.
#   2. Reference: every expected id is a rule that actually EXISTS in regeln/.
#      An id nobody defines can never be delivered, so such a row would fail
#      forever - and a permanently red gate only trains people to bypass it
#      (L22). This is the check that catches a renamed or streiched rule.
#   3. Geltung: every expected id is a kern rule or a flotte rule. The fixture
#      header states this; the gate queries as firstmate, so a firstmate-only
#      id would pass the gate while being unreachable for the flotte the row
#      claims to speak for.
#   4. Retrieval (live, skipped with a named reason when the engine is absent):
#      each row's prompt goes through `bin/fm-regeln query --geltung firstmate`
#      and must deliver its expected id - mandatorily as kern, or inside topk.
#
# RED WITHOUT / GREEN WITH: cases 1-3 are run twice. Once over the real
# fixture, where they must pass; once over deliberately broken copies under
# mktemp (missing id, unknown id, narrower geltung), where each must be
# refused by name. A checker that cannot be made to fail proves nothing.
#
# Isolation: the live case ingests into a throwaway WRIT_DATA_DIR under
# mktemp, so it never writes the home's state/writ-fm/. WRIT_RULES_DIR stays
# on the real regeln/ - the fixture is a claim about those rules.
#
# Standalone: bash tests/regel-retrieval-golden.test.sh
set -u
export LC_ALL=C

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN="$REPO/tests/regel-retrieval-golden.tsv"
REGELN="$REPO/regeln"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TAB=$(printf '\t')

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }
skip() { echo "skip: $1"; }

[ -f "$GOLDEN" ] || { fail "fixture missing: $GOLDEN"; exit 1; }

# --- the checkers under test -------------------------------------------------
# Each prints its findings and returns nonzero when the fixture is bad.

pruef_form() { # <golden-file>
  local datei="$1" n=0 rc=0 zeile prompt want rest
  while IFS= read -r zeile; do
    case "$zeile" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    prompt=${zeile%%"$TAB"*}
    rest=${zeile#*"$TAB"}
    want=${rest%%"$TAB"*}
    if [ "$rest" = "$zeile" ]; then
      echo "  form: row $n has no tab: $zeile"; rc=1; continue
    fi
    if [ "$want" != "$rest" ]; then
      echo "  form: row $n has more than one tab: $zeile"; rc=1; continue
    fi
    [ -n "$prompt" ] || { echo "  form: row $n has an empty prompt"; rc=1; }
    case "$want" in
      *[!A-Z0-9-]*|'') echo "  form: row $n has no rule id in the second field: '$want'"; rc=1 ;;
    esac
  done < "$datei"
  [ "$n" -gt 0 ] || { echo "  form: fixture has no data rows"; rc=1; }
  return $rc
}

# id -> geltung over all of regeln/, read once. A rule in kern.yaml counts as
# kern regardless of its geltung line; everything else keeps its own geltung.
sammle_regeln() { # -> "<id> <geltung>" per line
  awk '
    FILENAME != vorher { vorher = FILENAME; kern = (FILENAME ~ /kern\.yaml$/) }
    /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
      if (id != "") print id, (kernrule ? "kern" : geltung)
      id = $NF; geltung = "?"; kernrule = kern
    }
    /^[[:space:]]*geltung:[[:space:]]*/ { if (id != "") geltung = $NF }
    END { if (id != "") print id, (kernrule ? "kern" : geltung) }
  ' "$REGELN"/*.yaml
}

pruef_referenz_und_geltung() { # <golden-file> <regel-tabelle>
  local datei="$1" tabelle="$2" rc=0 prompt want g
  while IFS="$TAB" read -r prompt want; do
    case "$prompt" in ''|'#'*) continue ;; esac
    [ -n "$want" ] || continue
    g=$(awk -v w="$want" '$1 == w { print $2; found = 1; exit } END { if (!found) print "" }' "$tabelle")
    if [ -z "$g" ]; then
      echo "  reference: $want is expected by a row but defined nowhere in regeln/"; rc=1; continue
    fi
    case "$g" in
      kern|flotte) ;;
      *) echo "  geltung: $want has geltung '$g' - a row may only expect a kern or flotte rule"; rc=1 ;;
    esac
  done < "$datei"
  return $rc
}

TABELLE="$TMP/regeln.tbl"
sammle_regeln > "$TABELLE"
[ -s "$TABELLE" ] || fail "could not read any rule ids out of $REGELN/*.yaml"

# --- 1-3. green with the real fixture ---------------------------------------
if out=$(pruef_form "$GOLDEN" 2>&1); then
  ok "fixture rows are well-formed (<prompt><TAB><rule-id>)"
else
  fail "the real fixture must be well-formed:"$'\n'"$out"
fi

if out=$(pruef_referenz_und_geltung "$GOLDEN" "$TABELLE" 2>&1); then
  ok "every expected id exists in regeln/ and is a kern or flotte rule"
else
  fail "the real fixture's expected ids must all resolve:"$'\n'"$out"
fi

# --- 1-3. red without: each checker must refuse a broken copy ----------------
BROKEN_FORM="$TMP/broken-form.tsv"
{ printf '# comment\n'; printf 'ein prompt ohne id\n'; } > "$BROKEN_FORM"
if pruef_form "$BROKEN_FORM" >/dev/null 2>&1; then
  fail "the form check accepted a row with no tab - it cannot fail, so it proves nothing"
else
  ok "the form check refuses a row without a tab"
fi

BROKEN_TABS="$TMP/broken-tabs.tsv"
printf 'ein prompt%sKERN-WAHR-001%snoch was\n' "$TAB" "$TAB" > "$BROKEN_TABS"
if pruef_form "$BROKEN_TABS" >/dev/null 2>&1; then
  fail "the form check accepted a row with two tabs (the gate would skip its tail silently)"
else
  ok "the form check refuses a row with a second tab"
fi

BROKEN_REF="$TMP/broken-ref.tsv"
printf 'ein prompt%sKERN-GIBTESNICHT-999\n' "$TAB" > "$BROKEN_REF"
if pruef_referenz_und_geltung "$BROKEN_REF" "$TABELLE" >/dev/null 2>&1; then
  fail "the reference check accepted an id that no rule defines"
else
  ok "the reference check refuses an id no rule defines"
fi

BROKEN_GELTUNG="$TMP/broken-geltung.tsv"
ENG_ID=$(awk '$2 != "kern" && $2 != "flotte" { print $1; exit }' "$TABELLE")
if [ -z "$ENG_ID" ]; then
  skip "geltung red-case: regeln/ currently holds no rule of narrower geltung to build the broken copy from"
else
  printf 'ein prompt%s%s\n' "$TAB" "$ENG_ID" > "$BROKEN_GELTUNG"
  if pruef_referenz_und_geltung "$BROKEN_GELTUNG" "$TABELLE" >/dev/null 2>&1; then
    fail "the geltung check accepted $ENG_ID, which is narrower than flotte"
  else
    ok "the geltung check refuses a rule narrower than flotte ($ENG_ID)"
  fi
fi

# --- 4. live retrieval -------------------------------------------------------
MODEL_DIR="${WRIT_MODEL_DIR:-$HOME/.local/share/writ-fm/model}"
VENV_BIN="${WRIT_DATA_DIR:-$REPO/state/writ-fm}/venv/bin/writ-light"
if [ ! -x "$REPO/bin/fm-regeln" ]; then
  skip "live retrieval: bin/fm-regeln is not executable here"
elif [ ! -x "$VENV_BIN" ]; then
  skip "live retrieval: no bootstrapped writ-fm venv at $VENV_BIN (run bin/fm-regeln ingest once to build it)"
elif [ ! -d "$MODEL_DIR" ] || [ -z "$(ls -A "$MODEL_DIR" 2>/dev/null)" ]; then
  skip "live retrieval: no ONNX embed model in $MODEL_DIR"
else
  DATA="$TMP/writ-data"
  mkdir -p "$DATA"
  cp -r "$(dirname "$(dirname "$VENV_BIN")")" "$DATA/venv"
  if ! ingest_out=$(cd "$REPO" && WRIT_DATA_DIR="$DATA" WRIT_RULES_DIR="$REGELN" bin/fm-regeln ingest 2>&1); then
    fail "ingest over regeln/ must pass before the suite can run:"$'\n'"$ingest_out"
  else
    ok "fm-regeln ingest --strikt-v2 accepted regeln/ ($(printf '%s' "$ingest_out" | awk '/^Regeln:/ { $1 = ""; print substr($0, 2) }'))"
    treffer=0; gesamt=0
    while IFS="$TAB" read -r prompt want; do
      case "$prompt" in ''|'#'*) continue ;; esac
      [ -n "$want" ] || continue
      gesamt=$((gesamt + 1))
      q=$(cd "$REPO" && WRIT_DATA_DIR="$DATA" WRIT_RULES_DIR="$REGELN" \
            bin/fm-regeln query --geltung firstmate "$prompt" 2>&1)
      if printf '%s' "$q" | grep -qF "$want"; then
        treffer=$((treffer + 1))
      else
        fail "retrieval did not deliver $want for: $prompt"
      fi
    done < "$GOLDEN"
    [ "$gesamt" -gt 0 ] || fail "live retrieval ran over zero rows"
    [ "$treffer" -eq "$gesamt" ] && ok "live retrieval: $treffer/$gesamt rows delivered their expected rule"
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "regel-retrieval-golden: all checks passed"
  exit 0
fi
echo "regel-retrieval-golden: $FAILS check(s) failed"
exit 1
