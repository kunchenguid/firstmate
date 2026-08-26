#!/usr/bin/env bash
# fm-regel-eval.sh - the rule gate, v2 (Flottenordnung v2, Phase B).
#
# v1 asked "does every rule line carry an anchor?". v2 asks the honest
# questions instead: does the named reader EXIST, is it REGISTERED where it
# claims to read, does the cited anchor EXIST in the ledger, does a new rule
# come with the post-incident ladder, and is anything out there still pointing
# at rules and sections that are gone. A gate that only counts anchors is a
# green light nobody earned (L03).
#
# Usage:
#   fm-regel-eval.sh check [options]     structure gate, fast, no test runs
#   fm-regel-eval.sh run   [options]     check, then the golden suites
#   fm-regel-eval.sh --help
#
# Options (all optional, all defaulting under the root):
#   --regelwerk <file>   default <root>/AGENTS.md
#   --regeln <dir>       default <root>/regeln
#   --ledger <file>      default <root>/data/forensik-2026-08/lehren-ledger.md
#   --manifest <file>    default <root>/tests/regel-eval.manifest.tsv
#   --scharf             arm the gate for this run (see TOR CONTRACT)
#
# Root: every path resolves under ${FM_REGEL_EVAL_ROOT:-<this script's repo>}
# (FM_ROOT_OVERRIDE is honoured as the older spelling), so the whole gate can
# be pointed at a fixture tree without touching the live repo.
#
# TOR CONTRACT
#   Scharfschalt-Flag $FM_HOME/state/.tor-regel-eval-scharf, checked first.
#   Absent => the gate still REPORTS everything it finds and exits 0: this TOR
#   is invoked deliberately (by hand, by bin/fm-lint.sh), so "silent passage"
#   can only mean "does not block the caller" - a lint that prints nothing is
#   the blind green this file exists to prevent. Armed (or --scharf, or
#   FM_REGEL_EVAL_SCHARF=1) => FATAL findings exit 1.
#   Refusals are LOUD: every FATAL names the source it read and the Ausweg.
#   Every run writes one line via fm_tor_log (state/tor-log/regel-eval.jsonl).
#
# WHAT check ENFORCES
#   1. AGENTS.md: <= 60 lines; every "Reader:" names at least one bin/ file and
#      every named file exists and is executable; no pointer at a .claude/
#      skills name (skills are craft, not law); every HRn cited in regeln/
#      exists as an HR heading in AGENTS.md.
#   2. regeln/: `bin/fm-regeln ingest --strikt-v2 --ohne-index` as a parse and
#      validation probe when the venv is already there (fail-open to WARNUNG
#      otherwise - this gate must also run in a bare environment, where a local
#      YAML parse plus a v2 mandatory-field check stands in). Independently of
#      writ-fm: every Lnn anchor exists as "### Lnn " in the ledger and every
#      HRn anchor exists in AGENTS.md. The caps in regeln/VERFASSUNG.yaml are
#      counted here too (core set, context set, context set per geltung) - a
#      budget nobody counts is a wish.
#   3. Reader registration: leser hook:<path> must exist, be runnable, AND be
#      wired into .claude/settings.json; leser tor:<path> / werkzeug:<path>
#      must exist, be runnable, AND own a colocated tests/<name>.test.sh.
#   4. Expiry: a past `verfall` whose status is not `abgelaufen` is a WARNUNG
#      (ingest sets the status); an incident-born rule (it carries `leiter:`)
#      without a `verfall:` is FATAL.
#   5. Manifest rows are well-formed and every test: target exists. Anchors
#      cited in AGENTS.md and regeln/ with no manifest row are coverage debt,
#      ratcheted against tests/regel-eval.schuld-stand: growing debt is FATAL,
#      shrinking debt asks for the stand file to be lowered.
#   6. Dead-reference lint over .agents/skills/, .claude/skills/ and docs/:
#      "AGENTS.md section N" pointers, rule IDs that no longer exist in
#      regeln/, and bin/ paths that do not exist - ratcheted against
#      tests/regel-eval.deadref-stand exactly like the coverage debt.
#   7. Diff gate: a rule id ADDED in the working diff (staged + unstaged +
#      untracked) needs leiter:, verfall: and quelle: order:<id> - the
#      post-incident ladder from AGENTS.md, in the refusal itself.
#
# WHAT run ADDS
#   8. The golden suite: every unique test: target from the manifest.
#   9. The golden retrieval suite tests/regel-retrieval-golden.tsv
#      (prompt<TAB>expected-rule-id): each prompt goes through
#      `bin/fm-regeln query --geltung firstmate`; the expected id must appear.
#      Missing file or missing venv => skipped, with the reason named.
#
# Manifest (default tests/regel-eval.manifest.tsv), tab-separated:
#   <row-id>\t<anchors>\t<claim>\t<enforcement>
#   enforcement: test:<repo-relative test file> | probe:<one-line command> |
#                prose:<where the duty lives until it is mechanized>
#
# NOT read here: regeln/ABGESCHAFFT.md. The graveyard cites the anchors of
# rules that FELL; counting them as coverage debt would bill us for knowledge
# we deliberately buried.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_REGEL_EVAL_ROOT:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TOR_NAME="regel-eval"
FLAG="$STATE/.tor-$TOR_NAME-scharf"

REGELWERK="$FM_ROOT/AGENTS.md"
REGELN_DIR="$FM_ROOT/regeln"
LEDGER="$FM_ROOT/data/forensik-2026-08/lehren-ledger.md"
MANIFEST="$FM_ROOT/tests/regel-eval.manifest.tsv"
SCHULD_STAND="$FM_ROOT/tests/regel-eval.schuld-stand"
DEADREF_STAND="$FM_ROOT/tests/regel-eval.deadref-stand"
GOLDEN_RETRIEVAL="$FM_ROOT/tests/regel-retrieval-golden.tsv"
SETTINGS="$FM_ROOT/.claude/settings.json"
AGENTS_MAX_LINES=60
SCHARF="${FM_REGEL_EVAL_SCHARF:-}"

if [ -f "$SCRIPT_DIR/fm-tor-log-lib.sh" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-tor-log-lib.sh"
else
  fm_tor_log() { :; }
fi

# The header block above IS the help text: everything up to `set -u`.
usage() { sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'; }

TAB=$(printf '\t')
FATALS=0
WARNS=0
RULES_TSV=""
RULE_CHECKS_LIVE=1

fatal() { echo "FATAL: $*"; FATALS=$((FATALS + 1)); }
warnung() { echo "WARNUNG: $*"; WARNS=$((WARNS + 1)); }
hinweis() { echo "hinweis: $*"; }
melde() { echo "$*"; }

parse_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --regelwerk) REGELWERK="${2:-}"; shift 2 ;;
      --regeln) REGELN_DIR="${2:-}"; shift 2 ;;
      --ledger) LEDGER="${2:-}"; shift 2 ;;
      --manifest) MANIFEST="${2:-}"; shift 2 ;;
      --scharf) SCHARF=1; shift ;;
      *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
    esac
  done
}

# --- rule extraction -------------------------------------------------------
# One TSV row per rule, so every later check reads the rulebook exactly once.
# Columns: KIND file id anker leser verfall status leiter quelle
#          missing-fields verbindlichkeit geltung
# The cap document (no `rules:` key) yields one CAPS row instead:
#   CAPS file missing-cap-keys kern_max kontext_max_je_geltung kontext_max_gesamt
extract_rules() {
  [ -d "$REGELN_DIR" ] || { fatal "rule directory missing: $REGELN_DIR (Ausweg: create regeln/ or point --regeln at it)"; return 1; }
  RULES_TSV=$(python3 - "$REGELN_DIR" 2>/dev/null <<'PY'
import glob, os, sys
try:
    import yaml
except Exception:
    sys.exit(3)

PFLICHT = ("id", "geltung", "verbindlichkeit", "anker", "quelle", "leser",
           "trigger", "statement")
CAPS = ("kern_max", "kern_token_max", "topk", "brief_token_max")
DECKEL = ("kern_max", "kontext_max_je_geltung", "kontext_max_gesamt")


def flat(value):
    return " ".join(str(value).split())


def row(*cols):
    print("\t".join(flat(c) if c not in (None, "") else "-" for c in cols))


directory = sys.argv[1]
for path in sorted(glob.glob(os.path.join(directory, "*.yaml"))):
    name = os.path.basename(path)
    try:
        with open(path, encoding="utf-8") as handle:
            doc = yaml.safe_load(handle)
    except Exception as exc:  # noqa: BLE001 - the message is the finding
        row("PARSEFEHLER", name, str(exc))
        continue
    if not isinstance(doc, dict):
        row("PARSEFEHLER", name, "top level is not a mapping")
        continue
    if "rules" not in doc:
        fehlend = [c for c in CAPS if not isinstance(doc.get(c), int)]
        werte = [doc.get(c) if isinstance(doc.get(c), int) else "-"
                 for c in DECKEL]
        row("CAPS", name, ",".join(fehlend) or "-", *werte)
        continue
    rules = doc.get("rules")
    if not isinstance(rules, list):
        row("PARSEFEHLER", name, "'rules' is not a list")
        continue
    for entry in rules:
        if not isinstance(entry, dict):
            row("PARSEFEHLER", name, "a rules entry is not a mapping")
            continue
        anker = entry.get("anker")
        if isinstance(anker, str):
            anker = [t.strip() for t in anker.split(",") if t.strip()]
        elif isinstance(anker, list):
            anker = [str(t).strip() for t in anker if str(t).strip()]
        else:
            anker = []
        fehlend = [f for f in PFLICHT
                   if entry.get(f) in (None, "", [], {})]
        verfall = entry.get("verfall")
        row("RULE", name, entry.get("id") or "-", " ".join(anker) or "-",
            entry.get("leser") or "-",
            "-" if verfall in (None, "", "null") else verfall,
            entry.get("status") or "-",
            "ja" if entry.get("leiter") else "-",
            entry.get("quelle") or "-",
            ",".join(fehlend) or "-",
            entry.get("verbindlichkeit") or "-",
            entry.get("geltung") or "-")
PY
  )
  local rc=$?
  if [ "$rc" -eq 3 ]; then
    warnung "python3 without PyYAML - rule-level checks (fields, anchors, readers, expiry, diff gate) are SKIPPED (Ausweg: install pyyaml, or run this gate where fm-regeln's venv lives)"
    RULE_CHECKS_LIVE=0
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    warnung "no usable python3 - rule-level checks (fields, anchors, readers, expiry, diff gate) are SKIPPED (Ausweg: install python3 with pyyaml)"
    RULE_CHECKS_LIVE=0
    return 0
  fi
  return 0
}

rule_rows() { [ -n "$RULES_TSV" ] && printf '%s\n' "$RULES_TSV" | awk -F'\t' '$1 == "RULE"'; }

# --- 1. AGENTS.md ----------------------------------------------------------
check_agents() {
  if [ ! -f "$REGELWERK" ]; then
    fatal "rulebook missing: $REGELWERK (Ausweg: restore AGENTS.md or point --regelwerk at it)"
    return 0
  fi
  local lines
  lines=$(wc -l < "$REGELWERK" | tr -d ' ')
  if [ "$lines" -gt "$AGENTS_MAX_LINES" ]; then
    fatal "AGENTS.md has $lines lines (limit $AGENTS_MAX_LINES, its own closing rule: 'a new line needs a reader, or it goes into regeln/'; Ausweg: move the line into regeln/*.yaml or delete one)"
  else
    melde "AGENTS.md: $lines line(s) (limit $AGENTS_MAX_LINES)"
  fi

  local reader_lines=0 reader_paths=0 line no path
  while IFS= read -r line; do
    no=${line%%:*}
    reader_lines=$((reader_lines + 1))
    local found=0
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      path=${path%.}
      found=$((found + 1))
      reader_paths=$((reader_paths + 1))
      if [ ! -e "$FM_ROOT/$path" ]; then
        fatal "AGENTS.md line $no names a reader that does not exist: $path (source: the 'Reader:' clause itself; Ausweg: build it, rename it, or drop the claim)"
      elif ! reader_runnable "$path"; then
        fatal "AGENTS.md line $no names a reader that is not $(reader_runnable_wort "$path"): $path (Ausweg: chmod +x $path)"
      fi
    done < <(printf '%s\n' "$line" | grep -oE 'bin/[A-Za-z0-9._-]+' || true)
    if [ "$found" -eq 0 ]; then
      fatal "AGENTS.md line $no says 'Reader:' but names no bin/ file (source: 'This file holds ONLY rules with a named mechanical reader'; Ausweg: name the reader or move the line into regeln/)"
    fi
  done < <(grep -n 'Reader:' "$REGELWERK" || true)
  melde "AGENTS.md: $reader_lines Reader clause(s), $reader_paths named reader file(s) checked for existence and executability"

  local skillrefs
  skillrefs=$(grep -nE '\.claude/skills|\.agents/skills|skills/[a-z]' "$REGELWERK" || true)
  if [ -n "$skillrefs" ]; then
    while IFS= read -r line; do
      fatal "AGENTS.md points at a skill: ${line:0:120} (source: 'Skills are craft, not law: they may cite rule IDs, never restate rules'; Ausweg: name the mechanical reader instead)"
    done <<< "$skillrefs"
  fi

  [ "$RULE_CHECKS_LIVE" -eq 1 ] || return 0
  local agents_hrs cited_hr hr
  agents_hrs=" $(grep -oE '\*\*HR[0-9]+' "$REGELWERK" | grep -oE 'HR[0-9]+' | sort -u | tr '\n' ' ')"
  cited_hr=$(rule_rows | awk -F'\t' '{print $4}' | tr ' ' '\n' | grep -E '^HR[0-9]+$' | sort -u)
  for hr in $cited_hr; do
    case "$agents_hrs" in
      *" $hr "*) ;;
      *) fatal "regeln/ cites anchor $hr but AGENTS.md has no such hard rule heading (Ausweg: fix the anchor, or restore the hard rule in AGENTS.md)" ;;
    esac
  done
  [ -z "$cited_hr" ] || melde "anchors: $(printf '%s' "$cited_hr" | tr '\n' ' ') cited from regeln/, all present as AGENTS.md hard rules"
}

# --- 2. regeln/: parse probe and anchor existence --------------------------
writ_venv_bin() {
  local data_dir="${WRIT_DATA_DIR:-$FM_HOME/state/writ-fm}"
  printf '%s\n' "$data_dir/venv/bin/writ-light"
}

writ_ready() {
  local model_dir="${WRIT_MODEL_DIR:-$HOME/.local/share/writ-fm/model}"
  [ -x "$FM_ROOT/bin/fm-regeln" ] || return 1
  [ -x "$(writ_venv_bin)" ] || return 1
  [ -d "$model_dir" ] && [ -n "$(ls -A "$model_dir" 2>/dev/null)" ] || return 1
  return 0
}

check_regeln_parse() {
  if writ_ready; then
    local out rc
    out=$(cd "$FM_ROOT" && bin/fm-regeln ingest --strikt-v2 --ohne-index 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
      melde "regeln: fm-regeln ingest --strikt-v2 --ohne-index accepted the rulebook"
    else
      fatal "fm-regeln ingest --strikt-v2 --ohne-index rejected regeln/: $(printf '%s' "$out" | tail -n 5 | tr '\n' ' | ') (Ausweg: fix the rule the message names)"
    fi
  else
    warnung "fm-regeln/venv/model not available - falling back to a local YAML parse plus the v2 mandatory-field check (Ausweg: run bin/fm-regeln ingest once to bootstrap, then re-run this gate for the full validation)"
  fi

  [ "$RULE_CHECKS_LIVE" -eq 1 ] || return 0
  local file msg id fehlend n=0
  while IFS="$TAB" read -r _kind file msg _rest; do
    fatal "regeln/$file does not parse as YAML: $msg (Ausweg: fix the YAML; nothing downstream can read this file)"
  done < <(printf '%s\n' "$RULES_TSV" | awk -F'\t' '$1 == "PARSEFEHLER"')
  while IFS="$TAB" read -r _kind file fehlend _rest; do
    [ "$fehlend" = "-" ] && continue
    fatal "regeln/$file is missing cap key(s): $fehlend (source: regeln/VERFASSUNG.yaml is the single owner of every cap number; Ausweg: restore the key)"
  done < <(printf '%s\n' "$RULES_TSV" | awk -F'\t' '$1 == "CAPS"')
  while IFS="$TAB" read -r file id fehlend; do
    n=$((n + 1))
    [ "$fehlend" = "-" ] && continue
    fatal "rule $id (regeln/$file) is missing v2 field(s): $fehlend (source: 'A rule exists only with: a documented failure it prevents, a named reader, and an expiry when incident-born'; Ausweg: fill them in or delete the rule)"
  done < <(rule_rows | awk -F'\t' '{print $2 "\t" $3 "\t" $10}')
  melde "regeln: $n rule(s) read"
}

# The cap document declares the budget; without a reader that counts, the
# budget is a wish. Counted here rather than only inside writ-fm's ingest,
# because this gate must also hold in a bare tree where writ-fm cannot run.
check_deckel() {
  [ "$RULE_CHECKS_LIVE" -eq 1 ] || return 0
  local caps kern_max je_geltung gesamt kern kontext geltung n
  caps=$(printf '%s\n' "$RULES_TSV" | awk -F'\t' '$1 == "CAPS" {print; exit}')
  if [ -z "$caps" ]; then
    fatal "no cap document in ${REGELN_DIR#"$FM_ROOT"/} (source: 'All caps live in regeln/VERFASSUNG.yaml (captain class)'; Ausweg: restore VERFASSUNG.yaml)"
    return 0
  fi
  kern_max=$(printf '%s' "$caps" | cut -f4)
  je_geltung=$(printf '%s' "$caps" | cut -f5)
  gesamt=$(printf '%s' "$caps" | cut -f6)

  kern=$(rule_rows | awk -F'\t' '$11 == "kern"' | wc -l | tr -d ' ')
  kontext=$(rule_rows | awk -F'\t' '$11 == "kontext"' | wc -l | tr -d ' ')

  case "$kern_max" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$kern" -gt "$kern_max" ]; then
        fatal "the core set holds $kern rules, cap kern_max is $kern_max (source: regeln/VERFASSUNG.yaml, captain class - 'Over-cap additions require a demotion in the same commit'; Ausweg: demote one core rule to kontext or hinweis with fm-regeln streich, or get the captain's word for a higher cap)"
      else
        melde "caps: core set $kern/$kern_max, context set $kontext/${gesamt:--}"
      fi
      ;;
  esac
  case "$gesamt" in
    ''|*[!0-9]*) ;;
    *)
      [ "$kontext" -le "$gesamt" ] || fatal "the context set holds $kontext rules, cap kontext_max_gesamt is $gesamt (source: regeln/VERFASSUNG.yaml; Ausweg: demote one rule per addition - one in, one out, recorded in regeln/ABGESCHAFFT.md)"
      ;;
  esac
  case "$je_geltung" in
    ''|*[!0-9]*) return 0 ;;
  esac
  while IFS=' ' read -r n geltung; do
    [ -n "$geltung" ] || continue
    [ "$n" -le "$je_geltung" ] || fatal "geltung '$geltung' holds $n context rules, cap kontext_max_je_geltung is $je_geltung (source: regeln/VERFASSUNG.yaml; Ausweg: demote one rule of this geltung in the same commit)"
  done < <(rule_rows | awk -F'\t' '$11 == "kontext" {print $12}' | sort | uniq -c | tr -s ' ' | sed 's/^ //')
}

check_anchors() {
  [ "$RULE_CHECKS_LIVE" -eq 1 ] || return 0
  local cited anker id file ok=0
  if [ ! -f "$LEDGER" ]; then
    fatal "lessons ledger missing: $LEDGER (Ausweg: restore it or point --ledger at it; without it no Lnn anchor can be verified)"
    return 0
  fi
  while IFS="$TAB" read -r file id cited; do
    [ "$cited" = "-" ] && continue
    for anker in $cited; do
      case "$anker" in
        L[0-9][0-9])
          if grep -q "^### $anker " "$LEDGER"; then
            ok=$((ok + 1))
          else
            fatal "rule $id (regeln/$file) cites anchor $anker, which has no '### $anker ' entry in $LEDGER (Ausweg: write the lesson into the ledger, or re-anchor the rule to a lesson that exists)"
          fi
          ;;
        HR[0-9]*) ok=$((ok + 1)) ;;
        *) fatal "rule $id (regeln/$file) has anchor '$anker' in neither accepted form (Lnn ledger lesson or HRn hard rule); Ausweg: use an existing anchor" ;;
      esac
    done
  done < <(rule_rows | awk -F'\t' '{print $2 "\t" $3 "\t" $4}')
  melde "anchors: $ok anchor citation(s) resolved against the ledger and AGENTS.md"
}

# --- 3. reader registration -------------------------------------------------
hook_registered() {
  local path="$1"
  [ -f "$SETTINGS" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty' "$SETTINGS" 2>/dev/null \
      | grep -qF "$path" && return 0
    return 1
  fi
  grep -qF "$path" "$SETTINGS"
}

# A reader must be runnable at the point of action. For a *-lib.sh that means
# readable and sourceable - a sourced library is run by its caller, and
# chmod +x on it would only teach the wrong convention.
reader_runnable() {
  local path="$1"
  case "$(basename "$path")" in
    *-lib.sh) [ -r "$FM_ROOT/$path" ] ;;
    *) [ -x "$FM_ROOT/$path" ] ;;
  esac
}

reader_runnable_wort() {
  case "$(basename "$1")" in
    *-lib.sh) printf 'readable\n' ;;
    *) printf 'executable\n' ;;
  esac
}

# Colocated test of a reader, in the three shapes this repo actually uses:
# tests/<name>.test.sh, tests/<name-without--lib>.test.sh, and - for a reader
# whose cases are split by aspect - tests/<name>-<aspect>.test.sh.
colocated_test() {
  local base kandidat
  base=$(basename "${1%.sh}")
  for kandidat in "tests/$base.test.sh" "tests/${base%-lib}.test.sh"; do
    [ -f "$FM_ROOT/$kandidat" ] && { printf '%s\n' "$kandidat"; return 0; }
  done
  for kandidat in "$FM_ROOT/tests/$base"-*.test.sh; do
    [ -f "$kandidat" ] || continue
    printf 'tests/%s\n' "$(basename "$kandidat")"
    return 0
  done
  return 1
}

check_leser() {
  [ "$RULE_CHECKS_LIVE" -eq 1 ] || return 0
  local file id leser art path n=0
  while IFS="$TAB" read -r file id leser; do
    n=$((n + 1))
    art=${leser%%:*}
    path=${leser#*:}
    case "$art" in
      retrieval) continue ;;
      hook|tor|werkzeug) ;;
      *)
        fatal "rule $id (regeln/$file) names reader '$leser' of unknown kind (accepted: hook:|tor:|werkzeug:|retrieval; Ausweg: name one of them)"
        continue
        ;;
    esac
    if [ ! -e "$FM_ROOT/$path" ]; then
      fatal "rule $id (regeln/$file) names reader $leser, but $path does not exist (Ausweg: build the reader, or demote the rule with fm-regeln streich - a rule without a reader does not exist)"
      continue
    fi
    if ! reader_runnable "$path"; then
      fatal "rule $id (regeln/$file) names reader $leser, but $path is not $(reader_runnable_wort "$path") (Ausweg: chmod +x $path)"
      continue
    fi
    if [ "$art" = "hook" ]; then
      if ! hook_registered "$path"; then
        fatal "rule $id (regeln/$file) names hook reader $path, which is NOT registered in ${SETTINGS#"$FM_ROOT"/} (Ausweg: wire it into the matching hooks array, or change the reader kind - an unregistered hook never runs)"
      fi
    else
      if ! colocated_test "$path" >/dev/null; then
        fatal "rule $id (regeln/$file) names reader $path without a colocated test tests/$(basename "${path%.sh}").test.sh (Ausweg: write it - a gate with no red case proves nothing, L03)"
      fi
    fi
  done < <(rule_rows | awk -F'\t' '$5 != "-" {print $2 "\t" $3 "\t" $5}')
  melde "readers: $n rule reader(s) checked (existence, executability, hook registration, colocated test)"
}

# --- 4. expiry and the incident ladder --------------------------------------
check_verfall() {
  [ "$RULE_CHECKS_LIVE" -eq 1 ] || return 0
  local file id verfall status leiter today
  today=$(date -u +%Y-%m-%d)
  while IFS="$TAB" read -r file id verfall status leiter; do
    if [ "$leiter" = "ja" ] && [ "$verfall" = "-" ]; then
      fatal "rule $id (regeln/$file) is incident-born (it carries leiter:) but has no verfall: (source: 'a rule exists only with ... an expiry when incident-born'; Ausweg: set verfall: YYYY-MM-DD)"
    fi
    [ "$verfall" = "-" ] && continue
    case "$verfall" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) fatal "rule $id (regeln/$file) has verfall '$verfall', not a YYYY-MM-DD date (Ausweg: write a date or null)"; continue ;;
    esac
    if [ "$verfall" \< "$today" ] && [ "$status" != "abgelaufen" ]; then
      warnung "rule $id (regeln/$file) expired on $verfall but its status is '$status' (Ausweg: run bin/fm-regeln ingest - it sets the status; then commit the rulebook)"
    fi
  done < <(rule_rows | awk -F'\t' '{print $2 "\t" $3 "\t" $6 "\t" $7 "\t" $8}')
}

# --- 5. manifest and the coverage-debt ratchet ------------------------------
cited_anchors() {
  {
    [ -f "$REGELWERK" ] && grep -oE '\bL[0-9][0-9]\b' "$REGELWERK"
    [ -d "$REGELN_DIR" ] && cat "$REGELN_DIR"/*.yaml 2>/dev/null | grep -oE '\bL[0-9][0-9]\b'
  } 2>/dev/null | sort -u
}

read_stand() {
  local file="$1"
  if [ -f "$file" ]; then
    tr -cd '0-9' < "$file"
  else
    printf ''
  fi
}

ratchet() {
  # ratchet <label> <count> <stand-file> <ausweg>
  local label="$1" count="$2" file="$3" ausweg="$4" stand
  stand=$(read_stand "$file")
  if [ -z "$stand" ]; then
    # No debt needs no ratchet file; debt without one is an unbounded promise.
    if [ "$count" -eq 0 ]; then
      melde "$label: 0 (no ratchet file needed)"
      return 0
    fi
    fatal "$label: $count open item(s) and no ratchet file ${file#"$FM_ROOT"/} (Ausweg: seed it with the current count: echo $count > ${file#"$FM_ROOT"/})"
    return 0
  fi
  if [ "$count" -gt "$stand" ]; then
    fatal "$label GREW: $count (ratchet stand $stand, ${file#"$FM_ROOT"/}) - $ausweg"
  elif [ "$count" -lt "$stand" ]; then
    hinweis "$label shrank to $count (stand $stand) - lower the ratchet: echo $count > ${file#"$FM_ROOT"/}"
  else
    melde "$label: $count (ratchet stand $stand, unchanged)"
  fi
}

check_manifest() {
  local id anchors claim enforcement target n=0 prose=0
  if [ ! -f "$MANIFEST" ]; then
    fatal "manifest missing: $MANIFEST (Ausweg: create it, or point --manifest at it)"
    return 0
  fi
  while IFS="$TAB" read -r id anchors claim enforcement; do
    case "$id" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    if [ -z "$anchors" ] || [ -z "$claim" ] || [ -z "$enforcement" ]; then
      fatal "manifest row '$id' is missing a field (needs id, anchors, claim, enforcement; Ausweg: complete the row)"
      continue
    fi
    case "$enforcement" in
      test:*)
        target=${enforcement#test:}
        [ -f "$FM_ROOT/$target" ] || fatal "manifest row '$id' names a missing test: $target (Ausweg: write it, or change the row to prose: and disclose the debt)"
        ;;
      probe:*) ;;
      prose:*) prose=$((prose + 1)) ;;
      *) fatal "manifest row '$id' has an unknown enforcement '$enforcement' (test:|probe:|prose:)" ;;
    esac
  done < "$MANIFEST"
  melde "manifest: $n row(s), $prose still prose-only (enforcement debt, disclosed, not a breach)"

  local mapped unmapped count
  mapped=$(awk -F'\t' '$1 !~ /^#/ {print $2}' "$MANIFEST" 2>/dev/null | grep -oE '\bL[0-9][0-9]\b' | sort -u)
  unmapped=$(comm -23 <(cited_anchors) <(printf '%s\n' "$mapped") | tr '\n' ' ')
  unmapped=${unmapped% }
  count=0
  [ -n "$unmapped" ] && count=$(printf '%s\n' "$unmapped" | wc -w | tr -d ' ')
  [ "$count" -eq 0 ] || melde "coverage debt: anchors cited in AGENTS.md/regeln with no manifest row: $unmapped"
  ratchet "coverage debt" "$count" "$SCHULD_STAND" \
    "every new anchor needs a manifest row whose case is red without the rule and green with it (Ausweg: add the row, or drop the anchor)"
}

# --- 6. dead-reference lint --------------------------------------------------
grep_targets() {
  local d
  for d in .agents/skills .claude/skills docs; do
    [ -d "$FM_ROOT/$d" ] && printf '%s\n' "$FM_ROOT/$d"
  done
}

search_tree() {
  # search_tree <extended-regex>
  local pattern="$1" dirs
  dirs=$(grep_targets)
  [ -n "$dirs" ] || return 0
  if command -v rg >/dev/null 2>&1; then
    # shellcheck disable=SC2086 # dirs is a deliberate whitespace-separated list
    rg --no-heading --line-number --no-messages -e "$pattern" $dirs 2>/dev/null || true
  else
    # shellcheck disable=SC2086
    grep -rnE --binary-files=without-match "$pattern" $dirs 2>/dev/null || true
  fi
}

check_deadrefs() {
  local findings="" known_ids="" line hit
  if [ "$RULE_CHECKS_LIVE" -eq 1 ]; then
    known_ids=" $(rule_rows | awk -F'\t' '{print $3}' | sort -u | tr '\n' ' ')"
  fi

  hit=$(search_tree 'AGENTS\.md section [0-9]|section [0-9]+ of AGENTS')
  [ -n "$hit" ] && findings="$findings$hit"$'\n'

  # Repo-relative pointers only: a match preceded by "/" belongs to some other
  # tree (~/.local/bin/...), and a match ending in "-" or "." is a truncated
  # placeholder (bin/fm-procevent-<adapter>.sh) - neither is a dead reference.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local path
    while IFS= read -r path; do
      path=${path#*bin/}
      path="bin/${path%.}"
      case "$path" in bin/|*-|*.) continue ;; esac
      [ -e "$FM_ROOT/$path" ] && continue
      findings="$findings$line"$'\n'
      break
    done < <(printf '%s\n' "$line" | grep -oE '(^|[^/A-Za-z0-9._-])bin/[A-Za-z0-9._-]+' || true)
  done < <(search_tree '(^|[^/A-Za-z0-9._-])bin/fm-[A-Za-z0-9._-]+')

  if [ -n "$known_ids" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      local rid
      rid=$(printf '%s' "$line" | grep -oE '\b[A-Z][A-Z0-9]+-[A-Z0-9]+-[0-9]{3}\b' | head -n 1)
      [ -n "$rid" ] || continue
      case "$known_ids" in
        *" $rid "*) ;;
        *) findings="$findings$line"$'\n' ;;
      esac
    done < <(search_tree '\b[A-Z][A-Z0-9]+-[A-Z0-9]+-[0-9]{3}\b')
  fi

  local count=0
  findings=$(printf '%s' "$findings" | grep -v '^$' | sort -u)
  [ -n "$findings" ] && count=$(printf '%s\n' "$findings" | wc -l | tr -d ' ')
  if [ "$count" -gt 0 ]; then
    melde "dead references in .agents/skills/, .claude/skills/, docs/:"
    printf '%s\n' "$findings" | sed 's/^/  /'
  fi
  ratchet "dead references" "$count" "$DEADREF_STAND" \
    "skills may cite rule IDs, never sections of AGENTS.md and never a tool that is gone (Ausweg: delete the pointer, or restore what it points at)"
}

# --- 7. diff gate for newly adopted rules -----------------------------------
# Staged + unstaged against HEAD, deliberately NOT untracked: a rule file that
# is not yet `git add`ed is a draft on someone's disk, and the moment it is
# added it lands in `git diff HEAD` and meets this gate before any commit.
new_rule_ids() {
  git -C "$FM_ROOT" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$FM_ROOT" diff HEAD -- 'regeln/*.yaml' 2>/dev/null \
    | grep -E '^\+[^+]' | grep -oE '\bid:[[:space:]]*[A-Za-z0-9._-]+' \
    | sed 's/^id:[[:space:]]*//' | sort -u
}

check_neuaufnahme() {
  [ "$RULE_CHECKS_LIVE" -eq 1 ] || return 0
  local neu id file verfall leiter quelle row n=0
  neu=$(new_rule_ids)
  [ -n "$neu" ] || { melde "diff gate: no newly added rule id in regeln/*.yaml"; return 0; }
  for id in $neu; do
    row=$(rule_rows | awk -F'\t' -v want="$id" '$3 == want {print; exit}')
    [ -n "$row" ] || continue
    n=$((n + 1))
    file=$(printf '%s' "$row" | cut -f2)
    verfall=$(printf '%s' "$row" | cut -f6)
    leiter=$(printf '%s' "$row" | cut -f8)
    quelle=$(printf '%s' "$row" | cut -f9)
    local fehlt=""
    [ "$leiter" = "ja" ] || fehlt="$fehlt leiter:"
    [ "$verfall" = "-" ] && fehlt="$fehlt verfall:"
    case "$quelle" in order:*) ;; *) fehlt="$fehlt quelle:order:<id>" ;; esac
    if [ -n "$fehlt" ]; then
      fatal "new rule $id (regeln/$file) is adopted without:$fehlt - the post-incident ladder in AGENTS.md is: sharpen an existing gate + golden row -> data amendment (MANDAT pattern, no-go line) -> tool fix -> only then a new context rule, and that last rung costs a captain word, an expiry and a leiter note (Ausweg: take a lower rung, or record the order and fill leiter:/verfall:/quelle: order:<id>)"
    fi
  done
  melde "diff gate: $n newly added rule(s) checked against the post-incident ladder"
}

# --- 8./9. the golden suites -------------------------------------------------
run_suite() {
  local target total=0 failed=0
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    total=$((total + 1))
    if bash "$FM_ROOT/$target" >/dev/null 2>&1; then
      echo "PASS: $target"
    else
      echo "FAIL: $target"
      failed=$((failed + 1))
    fi
  done < <(awk -F'\t' '$1 !~ /^#/ && $4 ~ /^test:/ {sub(/^test:/, "", $4); print $4}' "$MANIFEST" | sort -u)
  echo "golden suite: $total test file(s), $failed failed"
  [ "$failed" -eq 0 ]
}

run_retrieval() {
  local prompt want out total=0 failed=0
  if [ ! -f "$GOLDEN_RETRIEVAL" ]; then
    melde "golden retrieval: skipped - ${GOLDEN_RETRIEVAL#"$FM_ROOT"/} does not exist"
    return 0
  fi
  if ! writ_ready; then
    melde "golden retrieval: skipped - fm-regeln venv/model not available in this environment"
    return 0
  fi
  while IFS="$TAB" read -r prompt want; do
    case "$prompt" in ''|'#'*) continue ;; esac
    [ -n "$want" ] || continue
    total=$((total + 1))
    out=$(cd "$FM_ROOT" && bin/fm-regeln query --geltung firstmate "$prompt" 2>&1)
    if printf '%s' "$out" | grep -qF "$want"; then
      echo "PASS: retrieval '$prompt' -> $want"
    else
      echo "FAIL: retrieval '$prompt' did not surface $want in the top-k"
      failed=$((failed + 1))
    fi
  done < "$GOLDEN_RETRIEVAL"
  echo "golden retrieval: $total prompt(s), $failed failed"
  [ "$failed" -eq 0 ]
}

# --- driver -----------------------------------------------------------------
run_checks() {
  extract_rules
  check_agents
  check_regeln_parse
  check_deckel
  check_anchors
  check_leser
  check_verfall
  check_manifest
  check_deadrefs
  check_neuaufnahme
}

verdikt_and_exit() {
  local mode="$1"
  local armed=0
  if [ -n "$SCHARF" ] || [ -f "$FLAG" ]; then armed=1; fi
  if [ "$FATALS" -eq 0 ]; then
    melde "regel-eval: gate passed ($WARNS warning(s))"
    fm_tor_log "$TOR_NAME" "$mode" gruen - "0 fatal, $WARNS warn"
    return 0
  fi
  melde "regel-eval: $FATALS FATAL finding(s), $WARNS warning(s) - the rulebook does not pass its own gate"
  if [ "$armed" -eq 1 ]; then
    fm_tor_log "$TOR_NAME" "$mode" rot "fix the findings above" "$FATALS fatal, $WARNS warn"
    return 1
  fi
  melde "regel-eval: TOR UNARMED ($FLAG missing) - findings reported, exit code suppressed (Ausweg: arm with 'touch $FLAG', or run with --scharf)"
  fm_tor_log "$TOR_NAME" "$mode" warn "arm with touch $FLAG" "$FATALS fatal but unarmed"
  return 0
}

cmd="${1:-check}"
case "$cmd" in
  check)
    shift || true
    parse_flags "$@"
    run_checks
    verdikt_and_exit check
    exit $?
    ;;
  run)
    shift || true
    parse_flags "$@"
    run_checks
    verdikt_and_exit run || exit 1
    rc=0
    run_suite || rc=1
    run_retrieval || rc=1
    exit "$rc"
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
