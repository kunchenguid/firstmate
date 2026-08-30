#!/usr/bin/env bash
# fm-usage-wall.sh - the provider usage wall: see it coming, diagnose it when it
# lands, and read back what was in flight when it did.
#
# Usage: fm-usage-wall.sh headroom [--json]
#        fm-usage-wall.sh diagnose <task-id> [--endpoint-only]
#        fm-usage-wall.sh resume [--print] [--out <path>]
#
# A provider usage limit is not a crash, and that single confusion is what makes
# it expensive. The harness exits non-zero, the pipeline run goes terminal
# failed, every worker on that account dies inside the same minute, and the
# recorded evidence reads exactly like a fleet-wide failure. It is not one: the
# work is intact on disk, the branches are intact, and the pipeline is holding
# fix commits the worktrees never saw. Reconstructing that by hand costs an hour
# it should never cost, so the three things that hour buys are commands here:
#
#   headroom   read the gauge BEFORE dispatching, and never read an unmeasured
#              gauge as a healthy one.
#   diagnose   decide from evidence whether a stranded task hit the wall or
#              actually failed, so the two are never confused again.
#   resume     regenerate, from live durable state, exactly what a recovery
#              needs to know about every task in flight.
#
# This command decides NOTHING about what to run. It reports; firstmate and the
# captain choose. There is deliberately no budgeting, scheduling, throttling, or
# admission policy here, and the `tight` label below is presentation only - it
# never gates, blocks, or reorders a dispatch.
#
# The recovery PROCEDURE is not here either: .agents/skills/usage-limit-recovery
# owns it. This script owns the data that procedure reads. Neither restates the
# other.
#
# --- headroom ---------------------------------------------------------------
#
# Reads `quota-axi`'s default TOON, which is the surface AGENTS.md section 4
# already makes the dispatch-facing one, and reads exactly the layout a
# floor-compliant build emits: `quota[]` (the account percentage, its bounding
# window `limitedBy`, and that window's `resetsAt`), `exhaustion[]` (the runway
# `usableRunwaySeconds` and its own bounding window `limitingWindowId`), and
# `attention[]` (the kind, detail, and remedy for a provider with no measurable
# window). Each number therefore carries the window that bounds IT, and the
# runway's window is named only when it differs from the percentage's.
#
# `exhaustion[]` and `attention[]` are SPARSE - an empty table renders with a
# zero count and no field list at all - so a provider with no exhaustion row has
# an UNKNOWN runway, never a zero one.
#
# The TOON block is parsed BY FIELD NAME out of its own declared header, never
# by column position, so a provider, window, or field added upstream shifts
# nothing.
#
# Per provider a reading is `ok`, `tight`, or `wall`, and no reading at all is
# `unknown`. The aggregate adds one verdict the per-provider line cannot need:
# `partial`, some providers measured and healthy while others were never read.
# Precedence is wall > tight > partial > ok, and `unknown` is reserved for a
# reading nobody got. `partial` is not a hedge - on a host where one provider is
# measurable and five are not it is the NORMAL healthy reading - so it carries
# the same next-step pointer every other actionable verdict does.
#
# UNMEASURABLE IS UNKNOWN, NEVER FINE. This is the whole point of the command,
# so it is structural rather than conventional: a reading is emitted only from a
# present account-scoped `quota` row that names its provider and whose
# `effectivePercentRemaining` is a number - a decimal included, because a
# fraction is a number and refusing one would blank a gauge that was readable.
# A decimal is printed as the gauge gave it and compared as the value it is, so
# the thresholds below mean what they say for a fraction as well: `wall` needs
# the value to BE zero, and `tight` needs it at or below FM_USAGE_WALL_TIGHT_PCT.
# Every other outcome - quota-axi absent, the call timing out, neither table
# present, the percentage unreadable, the provider unnamed, the scope
# unresolved, a provider needing authentication - prints `unknown` with the
# concrete reason. There is no code path from a failed read to `ok`.
#
# And nothing this report emits is ever missing from the reading. Every name
# appearing anywhere - `quota` at any scope, `exhaustion`, `attention` - gets a
# line: measured when an account-scoped row was read, unknown with its reason
# otherwise. That is swept from the report's own names rather than enumerated
# shape by shape, because enumerating kept leaving one more way to be missed.
# A row carrying no provider at all has no name to be swept by, so ONE accounting
# pass over every table the reading consults counts what the name sweep cannot
# reach and reports it as a single `unattributable-row` line. That pass, rather
# than a guard per table, is what makes the rule hold: a rule about names alone
# let such a row vanish under a summary reading `measured=1 unknown=0`, and a
# guard written per table left `exhaustion` - which no loop enumerates - doing
# the same. No emitted row is discarded unaccounted for, which is what makes
# `unknown=0` mean everything the gauge reported was read.
#
# It never prompts. `quota-axi` returns auth_required and unknown headroom until
# the operator approves keychain access once, and the command that does that
# (`quota-axi --allow-keychain-prompt`) blocks on a GUI dialog - fatal on the
# session-start path, which runs inside a bounded session-open hook. So this
# command runs quota-axi WITHOUT that flag, always, and names the flag in the
# unknown line as the one-time operator action instead.
#
# It REFUSES a below-floor build, loudly, before parsing anything, naming both
# the installed version and the floor in the unknown line. bin/fm-quota-axi-lib.sh
# owns FM_QUOTA_AXI_MIN, the version extraction, and the comparison;
# bin/fm-bootstrap.sh owns turning a failing check into the operator MISSING
# diagnostic. Builds below the floor emit a different report layout entirely, so
# reading one would mean declaring a build unsupported and then reading it
# anyway; the summary still carries `build=below-floor(<min>)` so the refusal and
# the build label agree. docs/usage-limit-survivability.md owns the reasoning.
#
# A build that could not be READ is a third state, `build=unknown`, never
# `below-floor`: the comparator treats an empty string as incompatible, so
# labelling straight off it would print a definite claim about a version nobody
# measured. The four build labels are therefore `below-floor(<min>)`, `unknown`,
# `unavailable` (no gauge at all), and nothing when the build clears the floor.
#
# --- diagnose ---------------------------------------------------------------
#
# Answers one question about one task: is this stranding a usage wall?
# Evidence, cheapest first, stopping at the first positive:
#   1. the recorded endpoint's captured output (the harness prints the limit
#      line into its own terminal before exiting);
#   2. the no-mistakes step logs of the run attributed to this task's worktree
#      (the 2026-08-23 incident's evidence was here and NOT in the run status:
#      both the review and test step logs ended on the vendor limit line, while
#      `status: failed` looked like a code verdict and was not one).
#
# Verdicts are deliberately three, not two:
#   wall          a signature matched AND the same evidence carries the harness's
#                 own non-zero exit on another line; the quoted line and its
#                 source are printed. That corroboration is required because this
#                 command's evidence sources can contain this repository's own
#                 documentation OF this command - see first_wall_line.
#   no-signature  evidence was read and nothing matched, or nothing matched with
#                 corroboration. This is NOT a claim that the task crashed - only
#                 that no corroborated wall signature is present in what was
#                 readable.
#   unknown       the evidence could not be read at all. A step log that yielded
#                 nothing to read lands here (`reason=step-log-unreadable`),
#                 never on `no-signature`, because "nothing matched" is a claim
#                 about evidence that was actually read.
# A partial scan discloses both of its gaps separately: `unread=` names evidence
# that was ATTEMPTED and yielded nothing - the read failed, or it succeeded with
# no content at all, which `axi logs` does for a step that never produced one -
# and `unscanned=` names logs the budget never reached. `unread=` covers the
# ENDPOINT as well as the step logs, under the same `endpoint` token `checked=`
# uses, with the concrete reason trailing the line: a wedged terminal costs the
# whole capture bound and then contributes no evidence, so a verdict that named
# only the step logs it did read would look cleaner than the evidence behind it.
#
# A task with NO endpoint recorded is not an unread endpoint and never carries
# the token. Nothing was attempted, so there is no gap for a reader to close;
# saying otherwise points them at evidence that does not exist, which is the
# same false precision as labelling a percentage with a window it did not come
# from. The absence is still stated, as a trailing reason without the token.
# The three states are kept apart by endpoint_evidence's own status.
# Diagnose
# always attempts at least one log, so budget truncation reaches a reader here as
# `unscanned=` rather than as a reason slug of its own; the reason
# `scan-budget-exhausted` belongs to the digest's fleet-wide scan
# (bin/fm-session-start.sh), where a task genuinely can go unreached entirely.
# A negative therefore never hardens into "it really failed", which matters
# because the signature table below is only as complete as the vendor phrasings
# actually observed.
#
# --- resume -----------------------------------------------------------------
#
# Regenerates the resume record from live durable state. The record is GENERATED,
# never hand-authored, and that is the design point: a hand-written plan is stale
# the moment anything moves, is lost with the session that wrote it, and only
# exists at all if someone remembered to write it. Everything this record needs
# is already on disk and none of it dies with the agent - task metadata,
# worktrees, branches, merge posture, delivered instructions, open captain calls
# - so regenerating on demand is not merely as good as a pre-wall snapshot, it is
# strictly better: it cannot be stale, and it is available to a session that has
# never seen the wall coming.
#
# It composes rather than re-parses: bin/fm-fleet-snapshot.sh is the declared
# owner of structured fleet state and supplies identity, merge posture, current
# state, endpoint, PR, and open captain calls. This command adds only what that
# snapshot does not carry and a recovery needs: the worktree's branch, head, and
# dirty count; the attributed pipeline run and its branch custody; and the
# steering records the worker has and has not acknowledged.
#
# Read-only apart from its own output file. It acquires no lock, drains no wakes,
# touches no task, and never runs `no-mistakes axi sync`, `respond`, or any other
# state-changing pipeline command - returning custody belongs to the worker that
# owns the branch (AGENTS.md section 7), not to the process writing a record
# about it.
#
# Tunables (env):
#   FM_USAGE_WALL_QUOTA_TIMEOUT     bound on the WHOLE headroom reading (default
#                                   20s), shared cumulatively by the version and
#                                   report calls rather than granted to each, so
#                                   one reading can never cost a caller more
#                                   than this and read as unmeasurable when it
#                                   was readable
#   FM_USAGE_WALL_NM_TIMEOUT        bound on each no-mistakes read (default 20s)
#   FM_USAGE_WALL_SCAN_BUDGET       bound on diagnose's whole step-log scan
#                                   (default 60s), so its cost is a constant
#                                   rather than growing with failed-step count
#   FM_USAGE_WALL_SNAPSHOT_TIMEOUT  bound on the fleet snapshot (default 300s)
#   FM_USAGE_WALL_CAPTURE_LINES     endpoint lines scanned by diagnose (default 200)
#   FM_USAGE_WALL_CAPTURE_TIMEOUT   bound on diagnose's endpoint capture (default
#                                   15s), because a tmux server whose socket
#                                   still exists but is wedged never answers and
#                                   this command runs on the recovery path. That
#                                   default is for a direct invocation, which has
#                                   no outer bound; a caller that bounds this
#                                   command defaults it below its own bound
#                                   through fm_inner_bound in bin/fm-timeout-lib.sh
#   FM_USAGE_WALL_TIGHT_PCT         percent at or below which a reading is
#                                   labelled tight (default 20)
#   FM_USAGE_WALL_TIGHT_RUNWAY_SECS runway at or below which a reading is
#                                   labelled tight (default 3600)
#   FM_USAGE_WALL_NOW               fixed UTC stamp for the record (tests)
#
# Exit status: 0 when a verdict or record was produced, 2 on a usage error, 1 on
# an internal failure. A verdict of `unknown` is a successful report of an
# unmeasurable condition, not an error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-quota-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-headroom-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-headroom-lib.sh"
# Sourced at top level, not lazily: the run helpers are read inside command
# substitutions, and a library sourced inside one dies with its subshell.
# fm-nm-run-lib.sh sources nothing itself, so this costs nothing on the
# headroom path.
# shellcheck source=bin/fm-nm-run-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

QUOTA_TIMEOUT=${FM_USAGE_WALL_QUOTA_TIMEOUT:-20}
NM_TIMEOUT=${FM_USAGE_WALL_NM_TIMEOUT:-20}
SCAN_BUDGET=${FM_USAGE_WALL_SCAN_BUDGET:-60}
SNAPSHOT_TIMEOUT=${FM_USAGE_WALL_SNAPSHOT_TIMEOUT:-300}
CAPTURE_LINES=${FM_USAGE_WALL_CAPTURE_LINES:-200}
CAPTURE_TIMEOUT=${FM_USAGE_WALL_CAPTURE_TIMEOUT:-15}
TIGHT_PCT=${FM_USAGE_WALL_TIGHT_PCT:-20}
TIGHT_RUNWAY=${FM_USAGE_WALL_TIGHT_RUNWAY_SECS:-3600}

die() { printf 'fm-usage-wall: %s\n' "$1" >&2; exit "${2:-2}"; }

usage() {
  cat <<'EOF'
usage: fm-usage-wall.sh headroom [--json]
       fm-usage-wall.sh diagnose <task-id> [--endpoint-only]
       fm-usage-wall.sh resume [--print] [--out <path>]

headroom  Report provider headroom from quota-axi before dispatching.
          Unmeasurable headroom reports `unknown` with its reason; it is never
          reported as healthy, and this command never prompts for credentials.
diagnose  Decide from evidence whether one task's stranding is a provider usage
          wall rather than a crash. --endpoint-only skips the pipeline step logs
          and downgrades every negative to `unknown`.
resume    Regenerate the resume record from live durable state and write it to
          state/resume-record.md. --print also writes the record to stdout.

Load the usage-limit-recovery skill for the recovery procedure itself.
EOF
}

positive_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0) die "$1 must be a positive integer" ;;
  esac
}
non_negative_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*) die "$1 must be a non-negative integer" ;;
  esac
}
positive_int FM_USAGE_WALL_QUOTA_TIMEOUT "$QUOTA_TIMEOUT"
positive_int FM_USAGE_WALL_NM_TIMEOUT "$NM_TIMEOUT"
positive_int FM_USAGE_WALL_SCAN_BUDGET "$SCAN_BUDGET"
positive_int FM_USAGE_WALL_SNAPSHOT_TIMEOUT "$SNAPSHOT_TIMEOUT"
positive_int FM_USAGE_WALL_CAPTURE_LINES "$CAPTURE_LINES"
positive_int FM_USAGE_WALL_CAPTURE_TIMEOUT "$CAPTURE_TIMEOUT"
non_negative_int FM_USAGE_WALL_TIGHT_PCT "$TIGHT_PCT"
non_negative_int FM_USAGE_WALL_TIGHT_RUNWAY_SECS "$TIGHT_RUNWAY"

# --- usage-wall signatures --------------------------------------------------
#
# Vendor phrasings that positively identify a provider usage limit, as extended
# regular expressions matched case-insensitively. Provenance matters more than
# breadth here: an over-broad pattern turns an ordinary failure into a false
# "not your fault" verdict, which is worse than no verdict at all, so this table
# stays limited to limit-exhaustion wording and deliberately excludes transient
# transport wording such as HTTP 429 or "rate limited", which a harness retries
# and survives.
#
#   1-2  observed verbatim in the 2026-08-23 incident's review and test step
#        logs ("You've hit your weekly limit - resets Aug 26 at 10am
#        (Europe/Rome)") and in its 5-hour-window counterpart.
#   3    `session` observed verbatim on 2026-08-27 in this repo's own pipeline
#        log ("You've hit your session limit - resets 1:40am
#        (America/Los_Angeles)"), which stranded a run whose step log this
#        command then read as `no-signature`. That miss is why the rule below
#        says to diagnose a real wall rather than only a fixture: the table is
#        only ever as complete as the phrasings actually observed, which is also
#        why a negative is `no-signature` and never "it crashed".
#   4-6  the neighbouring exhaustion phrasings of the same vendor family.
# A phrasing that is not here yields `no-signature`, which this command
# explicitly does not treat as proof of a crash. Add a pattern only with an
# observed line to justify it, and extend tests/fm-usage-wall.test.sh with it.
USAGE_WALL_PATTERNS='hit your (weekly|session|[0-9]+-hour|five-hour|daily|monthly) limit'
USAGE_WALL_PATTERNS="$USAGE_WALL_PATTERNS|usage limit reached"
USAGE_WALL_PATTERNS="$USAGE_WALL_PATTERNS|hit your usage limit"
USAGE_WALL_PATTERNS="$USAGE_WALL_PATTERNS|you have (reached|hit) your (usage|weekly|monthly) limit"
USAGE_WALL_PATTERNS="$USAGE_WALL_PATTERNS|quota exceeded"

# A harness that hit the wall does not merely print about it - it dies. These are
# the non-zero-exit lines the harness itself emits on the way out, and a wall
# verdict requires one of them in the same evidence as the phrasing above.
# Deliberately concrete rather than descriptive: a phrase like "non-zero exit" is
# what this repository's own prose says ABOUT the harness, while `exit status 1`
# is what the harness itself prints, and only the second can corroborate.
USAGE_WALL_EXIT_PATTERNS='exit(ed with)? status [1-9]'
USAGE_WALL_EXIT_PATTERNS="$USAGE_WALL_EXIT_PATTERNS|exit(ed with)? code [1-9]"

# first_wall_line: print the first usage-wall signature line in <evidence>, but
# ONLY when that evidence also carries the harness's own non-zero exit on a
# different line. Both evidence paths go through here, so neither the endpoint
# capture nor a step log can produce a lone-phrase wall.
#
# Why corroboration, preserved because it is not obvious: this detector's
# evidence sources - a pane capture and a pipeline step log - can contain THIS
# REPOSITORY'S OWN DOCUMENTATION OF THE DETECTOR, because the recovery skill and
# the verification record quote the vendor phrasings verbatim, and the digest
# runs `diagnose --endpoint-only` automatically for every endpoint it cannot read
# as alive. A crewmate merely reading or working on this surface would otherwise
# get `wall source=endpoint` plus "this is a provider usage limit, not a crash -
# the work is intact" on a task that genuinely failed.
#
# The two error directions are not symmetric. A MISSED wall is self-correcting:
# whoever is reading carries on and finds the real cause. A FALSE wall asserts
# the work is intact and STOPS the reading. A confident wrong verdict is strictly
# worse than an honest unknown, so only the POSITIVE is tightened here; the
# negative stays `no-signature`, which is explicitly not proof the work crashed.
#
# It costs no true positive on record: every real detection - the 2026-08-23
# review and test step logs, and the 2026-08-27 run that stranded this very
# surface - carries the harness's non-zero exit on its own line right after the
# limit line. The corroborating line must NOT itself carry a limit phrasing,
# which is what separates the harness's two emitted lines from a sentence of
# prose that narrates both facts at once.
#
# It is a whole-evidence rule, deliberately not a proximity or window one: a
# narrowed window trades a real detection for an accident of layout.
#
# THE GAP THIS LEAVES OPEN, measured rather than assumed. The method first,
# because the first answer here was wrong by sampling: a 200-line capture window
# reads as a wall exactly when some limit line and some exit line that does not
# itself carry a limit phrasing lie within 199 lines of each other, which is
# decidable per file from the two line-number sets without sliding a window at
# all. By that test THREE tracked files still read as a wall - the verification
# record, which quotes a real step log verbatim; THIS FILE, whose header above
# quotes a limit phrasing while a later line carries an independent exit phrase;
# and tests/fm-usage-wall.test.sh, whose fixtures build the vendor lines from the
# same real text. The detector's own source trips the detector. Anyone editing
# this function is already reading the text that causes it, which is why the gap
# is recorded here and not only in the feature document.
#
# Revisit it if the vendor emits the phrasing and the exit on one line, if a
# real transcript turns up a multi-line wall being missed, or if a FOURTH tracked
# file starts reading as a wall. The open question behind it, which widening this
# disclosure again will not answer, is
# whether a wall verdict should be authoritative only where a structural signal
# exists - the harness's own non-zero exit together with the vendor's final line
# in a pipeline step log - and be demoted to a non-asserting hint on the pane
# path, where only a screen scrape is available.
# docs/usage-limit-survivability.md owns the rule and this residual in full.
first_wall_line() {  # <evidence>
  local evidence=${1:-}
  printf '%s\n' "$evidence" |
    grep -i -E -- "$USAGE_WALL_EXIT_PATTERNS" 2>/dev/null |
    grep -q -i -v -E -- "$USAGE_WALL_PATTERNS" 2>/dev/null || return 0
  printf '%s\n' "$evidence" | grep -m1 -i -E -- "$USAGE_WALL_PATTERNS" 2>/dev/null || true
}

# --- TOON block parsing -----------------------------------------------------
#
# Reads one self-describing TOON block by name and prints the requested fields
# as TSV, in the requested order, resolved BY FIELD NAME from the block's own
# declared header. An absent field prints "-", so a caller never silently reads
# a neighbouring column. Quoted fields (a value containing a comma, colon, or
# space) are honoured.
#
# "-" MEANS "no value for this field in this row", and it is deliberately
# ambiguous between three ways that happens: the header never declared the
# field, the row is shorter than the header, or the cell is declared and empty.
# A reader of a VALUE needs the same thing from all three - there is nothing to
# read - so they are not separated here. A caller that must tell "the layout
# changed" from "this row is incomplete" cannot do it from this output, and
# must not assume it can: the empty `provider` cell that let a row vanish from
# the reading looked exactly like a renamed `provider` field to everything
# downstream.
toon_block() {  # <block-name> <comma-separated-field-names> ; TOON on stdin
  awk -v block="$1" -v want="$2" '
    function unquote(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      if (s ~ /^".*"$/) { s = substr(s, 2, length(s) - 2) }
      return s
    }
    function split_row(line, out,   i, c, n, cur, inq) {
      n = 0; cur = ""; inq = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") { inq = !inq; cur = cur c; continue }
        if (c == "," && !inq) { out[++n] = unquote(cur); cur = ""; continue }
        cur = cur c
      }
      out[++n] = unquote(cur)
      return n
    }
    # ONE header-parsing path, reached from both the "not in a block" and the
    # "this line ended the block" branches. They were copies, and they had
    # already diverged by the one line that clears the index map: a second block
    # of the same name reached through the other branch inherited the FIRST
    # header field positions, so a field the second header does not declare was
    # read from a stale column and reported as measured. Two same-named blocks
    # separated by a non-indented line - the sparse `exhaustion[0]:` a live
    # report emits - is exactly that shape. Clearing and repopulating happen
    # here, once, so a third copy cannot appear.
    function read_header(line,   hdr, nf, i, fields) {
      if (line !~ "^" block "\\[[0-9]+\\]\\{[^}]*\\}:[ \t]*$") { return 0 }
      hdr = line
      sub(/^[^{]*\{/, "", hdr)
      sub(/\}.*$/, "", hdr)
      delete idx
      nf = split(hdr, fields, ",")
      for (i = 1; i <= nf; i++) { idx[fields[i]] = i }
      return 1
    }
    BEGIN { nw = split(want, wantf, ","); inblock = 0 }
    {
      if (!inblock) {
        inblock = read_header($0)
        next
      }
      if ($0 !~ /^[ \t]+[^ \t]/) {
        inblock = read_header($0)
        next
      }
      n = split_row($0, vals)
      out = ""
      for (i = 1; i <= nw; i++) {
        v = "-"
        if ((wantf[i] in idx) && idx[wantf[i]] <= n && vals[idx[wantf[i]]] != "") {
          v = vals[idx[wantf[i]]]
        }
        out = out (i > 1 ? "\t" : "") v
      }
      print out
    }
  '
}

# --- headroom ---------------------------------------------------------------

# humanize_secs: whole-unit runway, e.g. 4828 -> 1h20m.
humanize_secs() {  # <seconds>
  local s=$1 h m
  case "$s" in ''|*[!0-9]*) printf '%s' "$s"; return 0 ;; esac
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"; else printf '%dm' "$m"; fi
}

cmd_headroom() {
  local json=0 out rc quota_version build_state=ok build_note='' rowcount
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown headroom option: $1" ;;
    esac
    shift
  done

  if ! command -v quota-axi >/dev/null 2>&1; then
    headroom_unmeasurable 'quota-axi is not installed' \
      'install it with npm install -g quota-axi to get a reading' "$json"
    return 0
  fi
  # ONE cumulative budget for the whole reading, spent across both quota-axi
  # calls rather than granted to each. A per-call bound made the worst case
  # 2 x QUOTA_TIMEOUT while both callers bound the whole command at or below
  # that total, so a working gauge answering each call inside its own bound
  # still blew the caller's and printed `unknown` for a gauge that was fully
  # readable - a false unmeasurable in the one surface built to prevent them.
  # The version is labelling and the report is the reading, so the version gets
  # at most a quarter of the budget and can never starve the report.
  local version_raw version_bound started spent report_bound
  version_bound=$((QUOTA_TIMEOUT / 4))
  [ "$version_bound" -ge 1 ] || version_bound=1
  started=$(date +%s)
  version_raw=$(fm_run_timed "$version_bound" quota-axi --version 2>/dev/null </dev/null) || version_raw=
  spent=$(($(date +%s) - started))
  # An UNREAD version is not an old one. bin/fm-quota-axi-lib.sh owns both the
  # extraction and the comparison, and its comparator returns "incompatible" for
  # an empty string, so labelling straight off it would print `below-floor` for a
  # current build whose `--version` merely timed out - a definite claim about a
  # fact never measured, in the surface whose whole rule is that an unmeasured
  # read is unknown. The three states are kept apart.
  quota_version=$(fm_quota_axi_version_string "$version_raw")
  if [ -z "$quota_version" ]; then
    quota_version=unknown
    build_state=unknown
  elif ! fm_quota_axi_version_at_least "$version_raw"; then
    # A version that was READ and found older than the floor. The refusal itself
    # is below, so the label and the verdict can only ever agree.
    build_state=below-floor
  fi
  build_note=$(fm_headroom_build_note "$build_state")

  # A below-floor gauge is REFUSED here rather than parsed. This command reads
  # the table layout a floor-compliant build emits; older builds emit a
  # different one entirely, so parsing them would mean declaring a build
  # unsupported and then reading it anyway. Refusing loudly - naming the
  # installed version and the floor - is the honest answer, because a reading
  # that looks fine from a build we reject is the exact failure this surface
  # exists to prevent.
  if [ "$build_state" = below-floor ]; then
    headroom_unmeasurable \
      "quota-axi ${quota_version} is below the supported floor ${FM_QUOTA_AXI_MIN}, and its report layout is not the one this gauge reads" \
      "upgrade quota-axi to ${FM_QUOTA_AXI_MIN} or newer, then re-read; until then no provider headroom is measured" \
      "$json" "$quota_version" "$build_state"
    return 0
  fi

  report_bound=$((QUOTA_TIMEOUT - spent))
  if [ "$report_bound" -le 0 ]; then
    headroom_unmeasurable "quota-axi did not answer within ${QUOTA_TIMEOUT}s" \
      'treat every provider as unproven when deciding what to dispatch' "$json" "$quota_version" "$build_state"
    return 0
  fi
  # No --allow-keychain-prompt, ever: it blocks on a GUI dialog, and this runs
  # inside session start's bounded session-open hook.
  out=$(fm_run_timed "$report_bound" quota-axi 2>/dev/null </dev/null)
  rc=$?
  if [ "$rc" -eq 124 ]; then
    headroom_unmeasurable "quota-axi did not answer within ${QUOTA_TIMEOUT}s" \
      'treat every provider as unproven when deciding what to dispatch' "$json" "$quota_version" "$build_state"
    return 0
  fi
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    headroom_unmeasurable "quota-axi exited $rc with no readable report" \
      'treat every provider as unproven when deciding what to dispatch' "$json" "$quota_version" "$build_state"
    return 0
  fi

  # The floor-compliant layout. Two different windows answer two different
  # questions and each number carries its own: `limitedBy` with `resetsAt`
  # bounds the PERCENTAGE, and exhaustion's `limitingWindowId` with
  # `usableRunwaySeconds` bounds the RUNWAY. They usually agree, which is why
  # pairing the percentage with the runway's window stayed invisible until a
  # five-hour window at 85% sat beside a seven-day window at 35%.
  #
  # `exhaustion` and `attention` are SPARSE: an empty table renders with count
  # zero and no row fields, and a provider with no row is simply absent. A
  # missing exhaustion row therefore means an UNKNOWN runway, never a zero one,
  # and must never let a provider read as healthy on evidence nobody produced.
  # `quota` lists only providers with a measurable window; every other provider
  # appears in `attention` alone, which is where its reason and remedy live.
  #
  # `headroom_tables` names every table this reading consults, in ONE place, and
  # the accounting pass below reads that list rather than the tables by hand. A
  # table joins the reading by joining this list, and is accounted for by
  # construction from that moment - which is the point. `exhaustion` was
  # consulted only by per-provider lookups and by a name sweep that silently
  # discarded rows carrying no name, so a row reporting zero usable runway was
  # thrown away under a `verdict=ok ... unknown=0` summary. That was the third
  # table to lose the same invariant, each time because the guard was written
  # per table instead of once over all of them.
  local quota exhaustion attention
  local -a headroom_tables=(quota exhaustion attention)
  quota=$(printf '%s\n' "$out" | toon_block quota \
    'provider,scope,effectivePercentRemaining,runway,confidence,limitedBy,resetsAt')
  exhaustion=$(printf '%s\n' "$out" | toon_block exhaustion \
    'provider,scope,usableRunwaySeconds,limitingWindowId')
  attention=$(printf '%s\n' "$out" | toon_block attention 'provider,scope,kind,detail,remedy')
  if [ -z "$quota" ] && [ -z "$attention" ]; then
    headroom_unmeasurable 'quota-axi printed no quota or attention block' \
      'treat every provider as unproven when deciding what to dispatch' "$json" "$quota_version" "$build_state"
    return 0
  fi

  local measured=0 tight=0 wall=0 unknown=0 unattributable=0 rows='' summary_verdict
  while IFS="$(printf '\t')" read -r provider scope pct runway conf win resets; do
    # A row nobody can attribute is not a reading: `- ok pct=84` is a healthy
    # dispatch gauge for a provider no one can act on. This loop only declines
    # to READ it; the accounting pass below is what makes sure it was not
    # silently dropped, for this table and every other one at once.
    case "$provider" in ''|'-') continue ;; esac
    # One account-level reading per provider. A model-scoped row bounds only that
    # model (quota-axi owns that relationship) and is not the dispatch gauge.
    case "$scope" in
      all_models|unresolved) ;;
      *) continue ;;
    esac
    local verdict detail runway_s runway_win pct_int pct_frac pct_exact
    # Sparse by design: a provider with no exhaustion row has an UNKNOWN runway,
    # never a zero one, so the lookup misses rather than defaulting.
    runway_s=$(printf '%s\n' "$exhaustion" | awk -F'\t' -v p="$provider" -v sc="$scope" '$1 == p && $2 == sc { print $3; exit }')
    runway_win=$(printf '%s\n' "$exhaustion" | awk -F'\t' -v p="$provider" -v sc="$scope" '$1 == p && $2 == sc { print $4; exit }')
    [ -n "$runway_s" ] || runway_s='-'
    [ -n "$runway_win" ] || runway_win='-'
    [ -n "$resets" ] || resets='-'
    case "$win" in ''|'-') win=$runway_win ;; esac
    # A row is only a READING if its percentage is a NUMBER. `toon_block` yields
    # `-` for a field the header never declared or a row left empty, and an
    # upstream rename of `effectivePercentRemaining` renames it for every row at
    # once, so an unguarded row would count as measured and compare its way to
    # `ok` - a clean dispatch gauge for a provider nobody measured.
    #
    # A number, not an integer. Observed builds emit whole percentages, but
    # rejecting `34.5` would blank a gauge that was fully readable on a build
    # that clears the floor - the same false-unmeasurable this command exists to
    # remove, arriving from the opposite direction and invisible to the
    # below-floor refusal because the build is supported. So a decimal is
    # accepted, reported verbatim, and compared as the value it is: the integer
    # part and the fractional digits are kept apart, and the thresholds below
    # read both. Rounding either way would make the line and the label disagree
    # about the same number.
    pct_int=''; pct_frac=''
    case "$pct" in
      ''|*[!0-9.]*|*.*.*|.) ;;
      *.*)
        case "${pct%%.*}${pct#*.}" in
          ''|*[!0-9]*) ;;
          *) pct_int=${pct%%.*}; [ -n "$pct_int" ] || pct_int=0; pct_frac=${pct#*.} ;;
        esac
        ;;
      *) pct_int=$pct ;;
    esac
    if [ -z "$pct_int" ]; then
      unknown=$((unknown + 1))
      rows="$rows$provider	unknown	reason=$(headroom_unknown_reason "$scope" unreadable_percent) status=unreadable_percent detail=effectivePercentRemaining is not a number ($pct)"$'\n'
      continue
    fi
    measured=$((measured + 1))
    # `pct_exact` is 1 when the value has no fractional remainder, which is what
    # separates a boundary from a value just past it. Both thresholds are read
    # from the whole value, not from its integer part: `wall` is the claim that
    # this provider has ALREADY stopped, so 0.4% remaining is the tightest
    # possible reading and still not a stopped one, and `tight` is defined as
    # AT OR BELOW FM_USAGE_WALL_TIGHT_PCT, so 20.9 is not tight at a threshold
    # of 20 while 20.0 is. FM_USAGE_WALL_TIGHT_PCT is validated as a whole
    # number above, so comparing the integer part and then the remainder is the
    # exact comparison rather than an approximation of one.
    pct_exact=0
    [ -z "${pct_frac//0/}" ] && pct_exact=1
    if [ "$pct_int" -eq 0 ] && [ "$pct_exact" -eq 1 ]; then
      verdict=wall; wall=$((wall + 1))
    elif [ "$pct_int" -lt "$TIGHT_PCT" ] ||
      { [ "$pct_int" -eq "$TIGHT_PCT" ] && [ "$pct_exact" -eq 1 ]; }; then
      verdict=tight; tight=$((tight + 1))
    elif [ "$runway_s" != '-' ] && [ -z "${runway_s//[0-9]/}" ] && [ "$runway_s" -le "$TIGHT_RUNWAY" ]; then
      verdict=tight; tight=$((tight + 1))
    else
      verdict=ok
    fi
    detail="pct=$pct bound=$win resets=$resets"
    if [ "$runway_s" != '-' ] && [ -z "${runway_s//[0-9]/}" ]; then
      detail="$detail runway=$(humanize_secs "$runway_s")"
    else
      detail="$detail runway=unknown($runway)"
    fi
    # The reset time is the half that bites: paired with the wrong window it
    # makes an operator wait out a window that is not the one holding them up.
    # So the runway's window is named whenever it differs from the one bounding
    # the percentage. This layout carries a reset only for the percentage's own
    # window, so the runway's is reported as unknown rather than borrowed from
    # the other window or quietly left out - naming what is not known is the
    # whole contract here.
    if [ "$runway_win" != '-' ] && [ "$runway_win" != "$win" ]; then
      detail="$detail runway_bound=$runway_win runway_resets=unknown"
    fi
    detail="$detail confidence=$conf"
    rows="$rows$provider	$verdict	$detail"$'\n'
  done <<EOF
$quota
EOF

  # Providers with no measurable window never appear in `quota` at all - they
  # exist only in `attention`, which is where their reason and remedy live. A
  # provider missing from `quota` is UNMEASURED, and saying so is the point.
  #
  # Deduped against the rows this reading ACTUALLY emitted rather than against
  # every name in `quota`, and read account-scope-first rather than filtered to
  # account scope. The quota loop reports only account-scoped rows, so matching a
  # provider by name alone - or dropping its attention row for being model-scoped
  # - let a provider whose only rows are model-scoped fall through both loops and
  # vanish, leaving the summary free to read `ok` while a provider quota-axi
  # flagged had no line at all. Ordering account scope first keeps the
  # account-level reason the one that gets printed when both exist.
  while IFS="$(printf '\t')" read -r provider scope kind reason remedy; do
    case "$provider" in ''|'-') continue ;; esac
    printf '%s\n' "$rows" | awk -F'\t' -v p="$provider" '$1 == p { found = 1 } END { exit !found }' && continue
    local ahint='' areason ascope=''
    unknown=$((unknown + 1))
    areason=$(headroom_unknown_reason "$scope" "$kind")
    case "$scope" in all|all_models|unresolved) ;; *) ascope=" scope=$scope" ;; esac
    # Both, never one instead of the other. The remedy is the gauge's own
    # advice and the keychain command is the action this surface owes the
    # operator - the only thing that unblocks the reading at all - so an
    # upstream string appearing in `remedy` must not be able to displace it.
    case "$kind" in
      auth_required) ahint=" - approve local credential access once with quota-axi --allow-keychain-prompt, then re-read" ;;
    esac
    case "$remedy" in ''|'-'|none) ;; *) ahint="$ahint - $remedy" ;; esac
    rows="$rows$provider	unknown	reason=$areason status=$kind$ascope detail=$reason$ahint"$'\n'
  done <<EOF
$(printf '%s\n' "$attention" | awk -F'\t' '
    $2 == "all" || $2 == "all_models" || $2 == "unresolved" { print; next }
    { rest = rest $0 "\n" }
    END { printf "%s", rest }')
EOF

  # THE INVARIANT: every ROW the gauge emitted, in every table this reading
  # consults, is either reported or accounted for as unreported with a reason -
  # and if any row was discarded, the reading may not describe itself as fully
  # measured. That is what makes `unknown=0` mean everything the gauge reported
  # was read.
  #
  # It is enforced by ONE accounting pass over `headroom_tables` rather than by
  # a guard per table, because a guard per table is what kept reopening this.
  # Each round closed the table in front of it and left the next one open:
  # attention filtered to account scope missed a provider flagged at model
  # scope; deduping by name missed a provider whose only quota row is
  # model-scoped; a name-shaped rule missed a quota row carrying no name at all;
  # and `exhaustion`, which no loop enumerates, kept losing rows to a sweep that
  # dropped unnamed ones silently. Here every row from every listed table is
  # sorted into exactly one of two piles - named, and therefore swept below by
  # name, or unattributable, and therefore counted - so a table added upstream
  # is covered the moment it joins `headroom_tables`, with nothing else to
  # remember.
  #
  # An empty TABLE is not an emitted row: `toon_block` prints nothing for a
  # sparse block, and `printf` then yields one blank line. A real row always
  # carries one field per name asked for - four at the fewest - so `NF > 1`
  # tells a row from that blank line without knowing which table it came from.
  local table_rows mentioned mprovider mscopes msources mreason tname
  table_rows=$(
    for tname in "${headroom_tables[@]}"; do
      printf '%s\n' "${!tname}" | awk -F'\t' -v t="$tname" 'NF > 1 { print $1 "\t" $2 "\t" t }'
    done
  )
  unattributable=$(printf '%s\n' "$table_rows" |
    awk -F'\t' 'NF > 1 && ($1 == "" || $1 == "-") { n++ } END { print n + 0 }')
  mentioned=$(
    printf '%s\n' "$table_rows" | awk -F'\t' 'NF > 1 && $1 != "" && $1 != "-"' | awk -F'\t' '
      { if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 }
        if (!(($1 SUBSEP $2) in scope_seen)) {
          scope_seen[$1 SUBSEP $2] = 1
          scopes[$1] = (scopes[$1] == "" ? $2 : scopes[$1] "," $2)
        }
        if (!(($1 SUBSEP $3) in src_seen)) {
          src_seen[$1 SUBSEP $3] = 1
          sources[$1] = (sources[$1] == "" ? $3 : sources[$1] "," $3)
        } }
      END { for (i = 1; i <= n; i++) print order[i] "\t" scopes[order[i]] "\t" sources[order[i]] }'
  )
  while IFS="$(printf '\t')" read -r mprovider mscopes msources; do
    [ -n "$mprovider" ] || continue
    printf '%s\n' "$rows" | awk -F'\t' -v p="$mprovider" '$1 == p { found = 1 } END { exit !found }' && continue
    unknown=$((unknown + 1))
    # The reason has to be true of THIS provider, not of the common case. A
    # provider named only in `exhaustion` has a limiting window and a usable
    # runway - the gauge reported both - so `no-measurable-window` would
    # contradict the detail printed beside it. What it is actually missing is a
    # quota row at all, which is a different absence from having one at model
    # scope only.
    case "$msources" in
      *quota*) mreason=$(headroom_unknown_reason "$mscopes" not_reported_quota) ;;
      *exhaustion*) mreason=$(headroom_unknown_reason "$mscopes" not_reported_exhaustion) ;;
      *) mreason=$(headroom_unknown_reason "$mscopes" not_reported) ;;
    esac
    rows="$rows$mprovider	unknown	reason=$mreason status=not_reported scope=$mscopes detail=named only in $msources, with no account-level quota row and nothing in attention"$'\n'
  done <<EOF
$mentioned
EOF

  # The report parsed but named no provider this reading could attribute a line
  # to - an upstream rename of `provider` leaves every row unnamed at once, the
  # same class of layout change the percentage guard above exists for. That is
  # the same condition as a gauge that could not be read, and it leaves through
  # the same single exit - otherwise the text emitter names the reason and the
  # JSON emitter returns an empty one, and `fm-usage-wall-headroom.v1` stops
  # meaning one shape. A provider that IS named can no longer arrive here: the
  # sweep above gives it a line whatever scope it appeared at.
  rowcount=$(printf '%s' "$rows" | grep -c . 2>/dev/null) || rowcount=0
  if [ "$rowcount" -eq 0 ]; then
    headroom_unmeasurable no-named-provider-row \
      'treat every provider as unproven when deciding what to dispatch' "$json" "$quota_version" "$build_state"
    return 0
  fi

  # Rows the gauge emitted that no name could be attached to. Some reading DID
  # come back - the exit above owns the case where none did - so these belong in
  # it, as one line rather than one per row: their number is the fact, and there
  # is nothing to tell them apart by. Counting them here is what stops the
  # summary claiming a complete measurement over a row it threw away.
  if [ "$unattributable" -gt 0 ]; then
    unknown=$((unknown + 1))
    rows="$rows(unattributable rows)	unknown	reason=$(headroom_unknown_reason '' unattributable_row) status=unattributable_row detail=$unattributable row(s) in the report carried no provider, so no reading could be attributed to them"$'\n'
  fi

  # Verdict precedence: wall > tight > partial > ok, with unknown reserved for a
  # reading nobody got. `wall` outranks `tight` because they are different
  # states, not degrees of one: tight means a dispatch may still land, wall
  # means that provider has already stopped and every worker on it is down.
  # Collapsing the second into the first would leave the aggregate line - and
  # `--json`'s `.verdict`, the field a programmatic reader branches on - unable
  # to express the one condition this command exists to announce. `partial` is
  # that same rule one level up: some providers measured and healthy, others
  # never read at all, which is neither `ok` nor `unknown` and must not borrow
  # either one's meaning.
  if [ "$measured" -eq 0 ]; then
    summary_verdict=unknown
  elif [ "$wall" -gt 0 ]; then
    summary_verdict=wall
  elif [ "$tight" -gt 0 ]; then
    summary_verdict=tight
  elif [ "$unknown" -gt 0 ]; then
    summary_verdict=partial
  else
    summary_verdict=ok
  fi

  if [ "$json" -eq 1 ]; then
    headroom_json "$summary_verdict" "$measured" "$tight" "$wall" "$unknown" \
      "$quota_version" "$build_state" "$rows"
    return 0
  fi
  while IFS="$(printf '\t')" read -r provider verdict detail; do
    [ -n "$provider" ] || continue
    printf 'HEADROOM: %s %s %s\n' "$provider" "$verdict" "$detail"
  done <<EOF
$rows
EOF
  printf 'HEADROOM_SUMMARY: verdict=%s measured=%d tight=%d wall=%d unknown=%d source=quota-axi/%s%s\n' \
    "$summary_verdict" "$measured" "$tight" "$wall" "$unknown" "$quota_version" "$build_note"
  if [ "$wall" -gt 0 ]; then
    printf 'HEADROOM_NOTE: %d provider(s) are AT the wall, not merely low - work on them has already stopped. Load the usage-limit-recovery skill.\n' "$wall"
  fi
  if [ "$unknown" -gt 0 ] || [ "$measured" -eq 0 ]; then
    printf 'HEADROOM_NOTE: an unknown provider is UNMEASURED, not healthy - treat its headroom as unproven when deciding what to dispatch.\n'
  fi
  # `partial` carries the pointer too. It is the honest mixed reading, and on a
  # host where most providers are unmeasurable it is the COMMON reading rather
  # than an edge case, so leaving it without a next step would drop the pointer
  # exactly where it is read most.
  case "$summary_verdict" in
    wall|tight|unknown|partial)
      printf 'HEADROOM_NEXT: %s/bin/fm-usage-wall.sh resume regenerates the resume record for the work now in flight.\n' "$FM_ROOT"
      ;;
  esac
}

headroom_unknown_reason() {  # <scope> <provider-status>
  case "$2" in
    auth_required) printf 'auth-required' ; return 0 ;;
    error) printf 'provider-read-failed' ; return 0 ;;
    unreadable_percent) printf 'unreadable-percent' ; return 0 ;;
    not_reported_quota) printf 'no-account-level-row' ; return 0 ;;
    not_reported_exhaustion) printf 'no-quota-row' ; return 0 ;;
    unattributable_row) printf 'unattributable-row' ; return 0 ;;
  esac
  case "$1" in
    unresolved) printf 'unresolved-scope' ;;
    *) printf 'no-measurable-window' ;;
  esac
}

# headroom_json_prefix: the single owner of the `fm-usage-wall-headroom.v1` key
# set, up to the opening of `providers`. Both emitters below go through it, so
# one schema id can only ever mean one shape: a consumer that branches on the
# id never has to discover which keys the path it happened to hit included.
# `reason` is present on every path and is empty when the read succeeded;
# `build` and `below_floor` are present on every path too.
headroom_json_prefix() {  # <verdict> <measured> <tight> <wall> <unknown> <source> <build-state> <reason>
  printf '{"schema":"fm-usage-wall-headroom.v1","verdict":"%s","measured":%d,"tight":%d,"wall":%d,"unknown":%d,' \
    "$1" "$2" "$3" "$4" "$5"
  printf '"source":"%s","build":"%s","below_floor":%s,"reason":"%s","providers":[' \
    "$(json_escape "$6")" "$(json_escape "$7")" \
    "$([ "$7" = below-floor ] && printf true || printf false)" \
    "$(json_escape "$8")"
}

# headroom_unmeasurable: the single exit for every path that could not read a
# gauge at all. There is deliberately no path from here to `ok`.
headroom_unmeasurable() {  # <reason> <advice> <json> [<version>] [<build-state>]
  local reason=$1 advice=$2 json=$3 version=${4:-unavailable} build=${5:-unavailable}
  if [ "$json" -eq 1 ]; then
    headroom_json_prefix unknown 0 0 0 1 "quota-axi/$version" "$build" "$reason"
    printf ']}\n'
    return 0
  fi
  # bin/fm-headroom-lib.sh owns the text shape, because the callers that could
  # not run this command at all have to print the same four lines.
  fm_headroom_unmeasurable_text "$reason" "$advice" "$version" "$build"
}

json_escape() {  # <text>
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g'
}

headroom_json() {  # <verdict> <measured> <tight> <wall> <unknown> <version> <build-state> <rows>
  local verdict=$1 measured=$2 tight=$3 wall=$4 unknown=$5 version=$6 build=$7 rows=$8 first=1
  headroom_json_prefix "$verdict" "$measured" "$tight" "$wall" "$unknown" \
    "quota-axi/$version" "$build" ''
  while IFS="$(printf '\t')" read -r provider pverdict detail; do
    [ -n "$provider" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"provider":"%s","verdict":"%s","detail":"%s"}' \
      "$(json_escape "$provider")" "$(json_escape "$pverdict")" "$(json_escape "$detail")"
  done <<EOF
$rows
EOF
  printf ']}\n'
}

# --- diagnose ---------------------------------------------------------------

load_backend_lib() {
  [ -n "${FM_USAGE_WALL_BACKEND_LOADED:-}" ] && return 0
  # shellcheck source=bin/fm-backend.sh disable=SC1091
  . "$SCRIPT_DIR/fm-backend.sh"
  FM_USAGE_WALL_BACKEND_LOADED=1
}

# endpoint_evidence: the first usage-wall line in the recorded endpoint's
# captured output, with the capture's own status and, when it failed, the
# concrete reason it failed. The caller needs all three to tell "read it,
# nothing there" from "could not read it, and here is why".
#
# The capture is BOUNDED like every other read in this command. A pane capture
# is a bare `tmux capture-pane`, which blocks forever against a server whose
# socket still exists but is wedged - and this command is what an agent runs by
# hand once a provider wall has stranded a worker, precisely the state in which
# a backend is most likely to be wedged rather than absent. Unbounded, it would
# hang with no verdict at all on the one path that exists to produce one.
# bin/fm-fleet-snapshot.sh bounds this same call the same way; the reason text
# comes from fm_run_timed_reason, the one owner of what a non-zero bounded exit
# actually means, so a timeout is never reported as something else.
#
# `unrecorded` is a third status rather than a flavour of `unreadable`, because
# a capture that was never attempted and one that resisted are different facts
# and the caller discloses them differently. Collapsing them reported a task
# that never had a terminal as one whose terminal could not be read.
endpoint_evidence() {  # <meta> <task-id> -> "readable|unreadable|unrecorded\t<reason>\t<line>"
  local meta=$1 id=$2 backend target capture rc line
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  if [ -z "$target" ]; then
    printf 'unrecorded\tno endpoint is recorded for this task\t\n'
    return 0
  fi
  # shellcheck disable=SC2016 # Positional parameters expand inside the child bash, not here.
  capture=$(fm_run_timed "$CAPTURE_TIMEOUT" bash -c \
    '. "$1"; fm_backend_capture "$2" "$3" "$4" "$5"' \
    fm-usage-wall-capture "$SCRIPT_DIR/fm-backend.sh" "$backend" "$target" \
    "$CAPTURE_LINES" "fm-$id" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'unreadable\t%s\t\n' \
      "$(fm_run_timed_reason "$rc" "$CAPTURE_TIMEOUT" 'endpoint capture')"
    return 0
  fi
  if [ -z "$capture" ]; then
    printf 'unreadable\tthe endpoint capture returned nothing to read\t\n'
    return 0
  fi
  line=$(first_wall_line "$capture")
  printf 'readable\t\t%s\n' "$line"
}

# attributed_run: the no-mistakes run report that belongs to <worktree>, or
# nothing when none is attributable.
#
# It asks the bare `no-mistakes axi` overview rather than `axi status`, because
# the two are scoped differently and only one of them answers this question:
# `axi status` reports the repo's active-or-most-recent run, which on a repo
# with several worktrees validating at once is routinely another task's run,
# while the bare overview reports the invoking worktree's own `active_run`.
#
# Provenance of the `runs` fallback below, because a bare "verified" claim with
# no version on it is how two tracked files came to disagree about this one
# surface. Verified 2026-08-27 against no-mistakes v1.57.0: `no-mistakes axi
# --help` documents the bare invocation as "shows the current state" and lists
# abort/logs/respond/run/status/sync - no runs-listing subcommand. bin/fm-crew-state.sh
# records the same absence against v1.32.2, so the two agree rather than
# conflict; neither observation has ever shown a `runs` table under `axi`.
# The fallback parse is kept anyway and is deliberately shaped so it costs
# nothing to be wrong: when the overview carries no such table the parse yields
# nothing, attribution ends at `unknown reason=no-attributed-run`, and no
# further call is made. It is tolerance for a shape upstream may print, not a
# claim that it does; tests/fm-usage-wall.test.sh exercises the path with a
# fixture that serves one, so the tolerance itself is known to still work.
#
# Attribution binds on the run's BRANCH, and the head relationship is reported
# separately as evidence rather than used to discard the run. That split is
# deliberate. bin/fm-nm-run-lib.sh's shared rule requires the run head to be
# resolvable in the worktree, and a stranded run's head very often is NOT: the
# pipeline commits its fixes in its own gate copy, so those commits exist
# nowhere in the task's local copy. Discarding the run there would hide exactly
# the state a recovery most needs to see. This command reports rather than acts,
# so it names the run AND the head relationship and lets the reader judge.
attributed_run() {  # <worktree>
  local wt=$1 overview wt_branch run_id
  wt_branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || wt_branch=
  [ -n "$wt_branch" ] || return 1
  overview=$(fm_nm_run "$wt" "$NM_TIMEOUT" axi) || overview=
  [ -n "$overview" ] || return 1

  case "$overview" in
    *active_run:*)
      if [ "$(fm_nm_strip_quotes "$(fm_nm_field "$overview" branch)")" = "$wt_branch" ]; then
        printf '%s\n' "$overview"
        return 0
      fi
      ;;
  esac

  run_id=$(printf '%s\n' "$overview" | toon_block runs 'id,branch,status,head' |
    awk -F'\t' -v b="$wt_branch" '$2 == b { print $1; exit }')
  [ -n "$run_id" ] || return 1
  overview=$(fm_nm_run "$wt" "$NM_TIMEOUT" axi status --run "$run_id") || overview=
  [ -n "$overview" ] || return 1
  printf '%s\n' "$overview"
}

# head_binding: how the attributed run's head relates to the local copy. The
# binding RULE stays owned by bin/fm-nm-run-lib.sh; this only names the cases it
# separates, including the one it rejects, because `pipeline-only` is the
# signature of a run holding commits the local copy never received.
head_binding() {  # <worktree> <run-head>
  local wt=$1 run_head=$2 local_full
  [ -n "$run_head" ] && [ "$run_head" != '-' ] || { printf 'unknown'; return 0; }
  # An unreadable copy fails the lookup below exactly as a copy missing the
  # commit does, so without this gate it would read `pipeline-only` - a definite
  # claim that the run holds commits this copy does not have, about a copy
  # nobody could read, carrying a warning not to rebuild from its head.
  worktree_git_readable "$wt" || { printf 'unknown'; return 0; }
  if ! git -C "$wt" rev-parse --verify --quiet "${run_head}^{commit}" >/dev/null 2>&1; then
    printf 'pipeline-only'
    return 0
  fi
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { printf 'unknown'; return 0; }
  if [ "$local_full" = "$(git -C "$wt" rev-parse "${run_head}^{commit}" 2>/dev/null)" ]; then
    printf 'equal'
  elif fm_nm_head_matches_worktree "$wt" "$run_head"; then
    printf 'pipeline-ahead'
  else
    printf 'diverged'
  fi
}

# Every failed or cancelled step, in pipeline order. Deliberately uncapped: a
# cap here silently decides which evidence counts, and a run whose fourth failed
# step is the one carrying the vendor limit line would return `no-signature` -
# the verdict this command defines as "read and nothing matched". The scan is
# bounded by time instead (SCAN_BUDGET), which bounds cost without ever deciding
# in advance that some evidence does not matter, and what the budget cut is
# disclosed as `unread=` rather than folded into a clean result.
failed_steps() {  # <axi-status-toon>
  toon_steps "$1" | awk -F'\t' '$2 == "failed" || $2 == "cancelled" { print $1 }'
}

last_step() {  # <axi-status-toon>
  toon_steps "$1" | awk -F'\t' '$1 != "" { last = $1 } END { if (last != "") print last }'
}

# toon_steps: "<step>\t<status>" for every row of `axi status`'s steps block.
# A row is recognized structurally - indented, and a bare token followed by a
# comma - so a neighbouring indented key/value block is never read as a step.
toon_steps() {  # <axi-status-toon>
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*steps\[[0-9]+\]\{/ { inblock = 1; next }
    !inblock { next }
    $0 !~ /^[[:space:]]+[^[:space:]:]+,/ { inblock = 0; next }
    {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      n = split(line, f, ",")
      if (n >= 2) { print f[1] "\t" f[2] }
    }
  '
}

cmd_diagnose() {
  local id='' endpoint_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --endpoint-only) endpoint_only=1 ;;
      -h|--help) usage; return 0 ;;
      -*) die "unknown diagnose option: $1" ;;
      *) [ -z "$id" ] || die "diagnose takes exactly one task id"; id=$1 ;;
    esac
    shift
  done
  [ -n "$id" ] || die "diagnose requires a task id"

  load_backend_lib
  local meta="$STATE/$id.meta"
  if [ ! -f "$meta" ]; then
    printf 'USAGE_WALL: %s unknown reason=no-durable-record checked=none\n' "$id"
    printf 'USAGE_WALL_NEXT: %s has no local record in this home; reconcile ownership before concluding anything about it.\n' "$id"
    return 0
  fi

  local checked='' evidence status reason line wt endpoint_unread='' endpoint_note=''
  evidence=$(endpoint_evidence "$meta" "$id")
  status=${evidence%%	*}
  evidence=${evidence#*	}
  reason=${evidence%%	*}
  line=${evidence#*	}
  line=${line%$'\n'}
  case "$status" in
    readable) checked=endpoint ;;
    unrecorded) endpoint_note=$reason ;;
    *) endpoint_unread=endpoint; endpoint_note=$reason ;;
  esac
  if [ "$status" = readable ] && [ -n "$line" ]; then
    wall_verdict "$id" endpoint "$line"
    return 0
  fi

  if [ "$endpoint_only" -eq 1 ]; then
    # A cheap scan that found nothing proves nothing: the 2026-08-23 evidence was
    # in the pipeline step logs, not the terminal. So an endpoint-only negative
    # is reported as unknown, never as a clean bill of health.
    # An endpoint that could not be read at all names WHY beside the verdict.
    # "The capture did not complete within 15s" and "there is no endpoint
    # recorded" send a reader to two different places, and a bare
    # `checked=none` sends them to neither. The disclosure is the same shape
    # every other verdict here uses, so a reader who learned `unread=` from the
    # recovery skill finds it on every path that has one.
    printf 'USAGE_WALL: %s unknown reason=endpoint-only-scan-inconclusive checked=%s%s%s\n' \
      "$id" "${checked:-none}" "${endpoint_unread:+ unread=$endpoint_unread}" \
      "${endpoint_note:+ - $endpoint_note}"
    printf 'USAGE_WALL_NEXT: run %s/bin/fm-usage-wall.sh diagnose %s for the pipeline step logs before treating this as a crash.\n' "$FM_ROOT" "$id"
    return 0
  fi

  wt=$(fm_meta_get_local "$meta" worktree)
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    diagnose_inconclusive "$id" "${checked:-none}" no-local-copy 'the pipeline logs need a readable local copy to read them from' \
      "$endpoint_unread" '' "$endpoint_note"
    return 0
  fi

  local run steps step log_line=''
  run=$(attributed_run "$wt") || run=
  if [ -z "$run" ]; then
    diagnose_inconclusive "$id" "${checked:-none}" no-attributed-run 'no pipeline run is attributed to this local copy' \
      "$endpoint_unread" '' "$endpoint_note"
    return 0
  fi
  local run_id
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$run" id)")
  steps=$(failed_steps "$run")
  [ -n "$steps" ] || steps=$(last_step "$run")
  if [ -z "$steps" ]; then
    diagnose_inconclusive "$id" "${checked:-none}" no-readable-steps "pipeline run $run_id lists no readable steps" \
      "$endpoint_unread" '' "$endpoint_note"
    return 0
  fi
  # `unread` and `unscanned` are separate lists on purpose. A log that failed to
  # read and a log nothing ever looked at are different facts: the first says
  # the evidence resisted, the second says the budget ran out before reaching
  # it. Folding the second into the first reported a read that never happened as
  # one that failed, and reported `step-log-unreadable` for steps nothing had
  # attempted - the same unmeasured-read-as-something-definite this command
  # exists to refuse.
  local readable=0 unread='' unscanned='' logs bound spent
  spent=0
  for step in $steps; do
    bound=$((SCAN_BUDGET - spent))
    [ "$bound" -gt "$NM_TIMEOUT" ] && bound=$NM_TIMEOUT
    if [ "$bound" -le 0 ]; then
      unscanned="${unscanned:+$unscanned,}$step"
      continue
    fi
    local started
    started=$(date +%s)
    # fm_nm_run_checked, not fm_nm_run: the fail-open variant discards the read's
    # exit status, so a log that could not be read at all was indistinguishable
    # from one read cleanly with no match - and `checked=` then named a step
    # nothing had ever looked at. The status decides which of the two this is.
    # The exit status alone is not enough: `axi logs` exits 0 with NO output for
    # a step that never produced one (a cancelled or skipped step), and counting
    # that as a read listed a step nothing looked at in `checked=` and let the
    # scan settle on `no-signature` - the verdict this header defines as evidence
    # that WAS read. Empty output is therefore no evidence, not a clean read.
    if logs=$(fm_nm_run_checked "$wt" "$bound" axi logs --run "$run_id" --step "$step" --full) \
      && [ -n "$logs" ]; then
      readable=$((readable + 1))
      checked="${checked:+$checked,}step-log:$step"
      log_line=$(first_wall_line "$logs")
      if [ -n "$log_line" ]; then
        wall_verdict "$id" "step-log:$step" "$log_line"
        return 0
      fi
    else
      unread="${unread:+$unread,}$step"
    fi
    spent=$((spent + $(date +%s) - started))
  done
  # One combined list, built once and printed the same way by both verdicts
  # below. The endpoint and a step log that resisted are the same fact - evidence
  # that was attempted and yielded nothing - so they belong in one `unread=`.
  # Composing it per verdict is how the token came to name only the endpoint on
  # the one verdict that means nothing was read at all, while the step logs sat
  # in prose beside it: two `unread` statements on one line with different
  # contents, and a reader who trusts the token re-reads the terminal and stops.
  local unread_all=$unread
  [ -z "$endpoint_unread" ] || unread_all="$endpoint_unread${unread:+,$unread}"
  # The first step is always attempted: SCAN_BUDGET and NM_TIMEOUT are both
  # validated positive and nothing is spent before it, so `readable -eq 0` means
  # every attempt failed and `unread` is never empty here. Budget truncation
  # after that shows up as `unscanned`, which is disclosed beside the failure
  # rather than replacing it - a different fact from what was attempted and
  # yielded nothing, and kept in its own list for that reason.
  if [ "$readable" -eq 0 ]; then
    diagnose_inconclusive "$id" "${checked:-none}" step-log-unreadable \
      "no step log of pipeline run $run_id could be read" \
      "$unread_all" "$unscanned" "$endpoint_note"
    return 0
  fi
  printf 'USAGE_WALL: %s no-signature checked=%s run=%s%s%s%s\n' "$id" "$checked" "$run_id" \
    "${unread_all:+ unread=$unread_all}" "${unscanned:+ unscanned=$unscanned}" \
    "${endpoint_note:+ - $endpoint_note}"
  printf 'USAGE_WALL_NEXT: no usage-limit signature is present in what was readable; this is not proof the work crashed, so keep reading the evidence itself.\n'
}

diagnose_inconclusive() {  # <id> <checked> <reason-slug> <detail> [<unread>] [<unscanned>] [<endpoint-note>]
  printf 'USAGE_WALL: %s unknown reason=%s checked=%s%s%s - %s%s\n' "$1" "$3" "$2" \
    "${5:+ unread=$5}" "${6:+ unscanned=$6}" "$4" "${7:+; $7}"
  printf 'USAGE_WALL_NEXT: the evidence that separates a usage wall from a crash could not be read; do not record a failure until it can.\n'
}

wall_verdict() {  # <id> <source> <line>
  local capped=$3
  [ "${#capped}" -le 200 ] || capped="${capped:0:200} [truncated]"
  printf 'USAGE_WALL: %s wall source=%s line="%s"\n' "$1" "$2" "$capped"
  printf 'USAGE_WALL_NEXT: this is a provider usage limit, not a crash - the work is intact. Load the usage-limit-recovery skill before touching the task.\n'
}

# fm_meta_get_local: meta lookup that does not require the backend library, so
# `diagnose` can report on a task whose backend cannot even be sourced.
fm_meta_get_local() {  # <meta-file> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

# --- resume -----------------------------------------------------------------

now_stamp() {
  if [ -n "${FM_USAGE_WALL_NOW:-}" ]; then
    printf '%s' "$FM_USAGE_WALL_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# branch_sync_field: one scalar from `axi status`'s branch_sync block, which is
# printed only when the pipeline has something to say about branch ownership.
# Scoped to that block so a same-named key elsewhere in the report (`status:`
# exists at run level too) can never be read as custody.
#
# NOT for `state`: bin/fm-nm-run-lib.sh declares itself the owner of that one
# key and this file already sources it. Two readers of the same contract is how
# the fallbacks in this change drifted apart once already, so `state` goes
# through fm_nm_branch_sync_state and this helper covers only the nested keys
# that library does not expose.
branch_sync_field() {  # <axi-status-toon> <key>
  printf '%s\n' "$1" | awk -v key="$2" '
    /^[[:space:]]*branch_sync:[[:space:]]*$/ { inblock = 1; next }
    inblock && $0 ~ /^[^[:space:]]/ { inblock = 0 }
    inblock {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (index(line, key ":") == 1) {
        v = substr(line, length(key) + 2)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        gsub(/^"|"$/, "", v)
        if (v != "") { print v; exit }
      }
    }
  '
}

# worktree_git_readable: can git read this directory as a repository at all?
#
# The one gate in front of every git read of a local copy, because the failure
# is silent in both directions otherwise: `git status --porcelain` prints
# nothing for a directory git cannot read, and the count of nothing is `0` - a
# clean, measured, FALSE answer about a repository nobody could read. A copy
# whose directory exists but whose git metadata is gone (pruned, relocated) is
# exactly the half-state a post-wall recovery walks into, so it is the state
# this record most has to get right. One gate rather than a check per fact, for
# the same reason the headroom accounting is one pass rather than one guard per
# table: a fact added later is covered without anyone remembering to add it.
worktree_git_readable() {  # <worktree>
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}

git_fact() {  # <worktree> <readable|branch|head|dirty|unpushed>
  local wt=$1 v
  if [ "$2" = readable ]; then
    worktree_git_readable "$wt" && printf 'yes' || printf 'no'
    return 0
  fi
  worktree_git_readable "$wt" || { printf 'unknown'; return 0; }
  case "$2" in
    branch)
      v=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || v=
      [ -n "$v" ] || v='(detached)'
      ;;
    head) v=$(git -C "$wt" rev-parse --short HEAD 2>/dev/null) || v='-' ;;
    dirty) v=$(git -C "$wt" status --porcelain 2>/dev/null | grep -c .) || v=0 ;;
    unpushed)
      # A branch the pipeline pushed often has no configured upstream, so fall
      # back to the remote branch of the same name before giving up. "not
      # pushed" is a real answer and must never be reported as zero unpushed
      # commits.
      local branch
      branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=
      v=$(git -C "$wt" rev-list --count '@{upstream}..HEAD' 2>/dev/null) || v=
      if [ -z "$v" ] && [ -n "$branch" ]; then
        v=$(git -C "$wt" rev-list --count "origin/$branch..HEAD" 2>/dev/null) || v=
      fi
      [ -n "$v" ] || v='(branch not on origin)'
      ;;
    *) v='-' ;;
  esac
  printf '%s' "$v"
}

# steering_fact: how many steering records this task has, by state. The inbox
# layout and the record-name rule belong to bin/fm-task-inbox-lib.sh, which
# declares itself their one owner, so both are asked of it rather than
# re-derived; a future layout change there then reaches this consumer instead of
# leaving it quietly reporting "0 acknowledged, 0 still unread" on a recovery
# record. cmd_resume sources that library, which is why this is safe to call.
steering_fact() {  # <task-id> <unread|acknowledged>
  local id=$1 dir n=0 entry
  case "$2" in
    unread) dir=$(fm_task_inbox_dir "$STATE" "$id") ;;
    acknowledged) dir=$(fm_task_inbox_handled_dir "$STATE" "$id") ;;
    *) printf '0'; return 0 ;;
  esac
  for entry in "$dir"/*; do
    [ -f "$entry" ] || continue
    fm_task_inbox_seq_of "${entry##*/}" >/dev/null 2>&1 || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}

cmd_resume() {
  local print=0 out="$STATE/resume-record.md" snapshot rc tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --print) print=1 ;;
      --out) shift; [ $# -gt 0 ] || die "--out requires a path"; out=$1 ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown resume option: $1" ;;
    esac
    shift
  done
  command -v jq >/dev/null 2>&1 || die "jq is required to read the fleet snapshot" 1
  # Sourced here rather than at the top of the file: bin/fm-task-inbox-lib.sh
  # pulls in bin/fm-backend.sh, and only `resume` needs the inbox layout, so the
  # `headroom` path keeps the backend graph off it exactly as load_backend_lib
  # intends. One source per invocation, ahead of the record composition, because
  # steering_fact runs inside command substitutions that a source would not
  # outlive.
  # shellcheck source=bin/fm-task-inbox-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-task-inbox-lib.sh"

  snapshot=$(fm_run_timed "$SNAPSHOT_TIMEOUT" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 124 ]; then
    die "the fleet snapshot did not finish within ${SNAPSHOT_TIMEOUT}s; no record was written so the previous one is still readable" 1
  fi
  [ "$rc" -eq 0 ] && [ -n "$snapshot" ] \
    || die "the fleet snapshot could not be read (exit $rc); no record was written so the previous one is still readable" 1

  mkdir -p "$(dirname "$out")" 2>/dev/null || true
  # Staged BESIDE the destination, never in TMPDIR: across a filesystem boundary
  # `mv` degrades to copy-then-unlink, and a reader during regeneration then sees
  # a truncated record. A same-directory rename is the only form that keeps the
  # guarantee below.
  tmp=$(mktemp "$(dirname "$out")/.fm-resume-record.XXXXXX") || die "could not create a temporary file beside $out" 1
  # A record is published whole or not at all: a half-written record read during
  # a recovery is worse than the previous complete one.
  resume_body "$snapshot" > "$tmp" || { rm -f "$tmp"; die "the record could not be composed" 1; }
  mv "$tmp" "$out" || { rm -f "$tmp"; die "the record could not be published to $out" 1; }

  if [ "$print" -eq 1 ]; then
    cat "$out"
  else
    printf '%s\n' "$out"
  fi
}

RESUME_DUP_WORKTREES=""

resume_body() {  # <snapshot-json>
  local snapshot=$1 count
  count=$(printf '%s' "$snapshot" | jq -r '.tasks | length')
  printf '# Resume record\n\n'
  printf 'generated: %s\n' "$(now_stamp)"
  printf 'home: %s\n' "$FM_HOME"
  printf 'source: bin/fm-usage-wall.sh resume\n'
  printf 'tasks in flight: %s\n\n' "$count"
  printf 'This record is GENERATED from live durable state. Do not hand-edit it; regenerate it.\n'
  printf 'It carries state only. The recovery procedure is owned by the usage-limit-recovery skill.\n'
  printf 'Nothing here is a merge authorisation: each task keeps the posture recorded on its own line.\n\n'
  if [ "$count" = 0 ]; then
    printf 'No task metadata is present in this home, so no work is in flight to resume.\n'
    return 0
  fi

  # Two tasks recording the SAME local copy is a live hazard during recovery -
  # resuming either one lands both in the same checkout - so it is named on both
  # rows rather than left for the reader to notice by comparing paths.
  RESUME_DUP_WORKTREES=$(printf '%s' "$snapshot" |
    jq -r '[.tasks[] | select(.paths.worktree.path != null) | .paths.worktree.path]
           | group_by(.) | map(select(length > 1) | .[0]) | .[]')

  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    resume_task "$snapshot" "$id"
  done < <(printf '%s' "$snapshot" | jq -r '.tasks[].id')
}

resume_task() {  # <snapshot-json> <task-id>
  local snapshot=$1 id=$2
  local meta="$STATE/$id.meta"
  # One field per LINE, never one row of tab-separated fields: bash collapses
  # runs of tabs when IFS is whitespace, so an empty field in a TSV row silently
  # shifts every field after it. A recovery record that quietly reports the
  # wrong branch or the wrong merge posture is worse than no record.
  local -a f=()
  local line
  while IFS= read -r line; do
    f+=("$line")
  done < <(printf '%s' "$snapshot" | jq -r --arg id "$id" '
    .tasks[] | select(.id == $id) |
    (.kind // "-"), (.mode // "-"), (.yolo // "-"), (.harness // "-"), (.backend // "-"),
    (.endpoint.target // "-"),
    (if .endpoint.exists == null then "unknown" elif .endpoint.exists then "present" else "absent" end),
    (.paths.worktree.path // "-"),
    (if .paths.worktree.present then "present" else "absent" end),
    (.current_state.raw // "-"),
    (.pr.url // "-"),
    (((.hints.open_decisions // []) | map("\(.key) (\(.verb))") | join("; ")) | if . == "" then "-" else . end),
    ((.remote.host // "-") | tostring)')
  # Exactly thirteen, in both directions. jq -r prints one line per field, so a
  # value carrying a newline adds an array element and shifts every field after
  # it - a record that reports another task's prose as this one's pull request
  # rather than saying it could not be read.
  if [ "${#f[@]}" -ne 13 ]; then
    printf '## %s\n\n' "$id"
    printf -- '- RECORD INCOMPLETE: this task could not be read out of the fleet snapshot; read %s directly before acting on it.\n\n' "$meta"
    return 0
  fi
  local kind=${f[0]} mode=${f[1]} yolo=${f[2]} harness=${f[3]} backend=${f[4]}
  local target=${f[5]} endpoint=${f[6]} wt=${f[7]} wt_present=${f[8]}
  local state=${f[9]} pr=${f[10]} decisions=${f[11]} remote=${f[12]}

  printf '## %s\n\n' "$id"
  printf -- '- kind: %s\n' "$kind"
  printf -- '- merge posture: mode=%s yolo=%s (%s)\n' "$mode" "$yolo" "$(posture_note "$yolo")"
  printf -- '- runtime: harness=%s model=%s effort=%s backend=%s\n' \
    "$harness" "$(dash "$(fm_meta_get_local "$meta" model)")" \
    "$(dash "$(fm_meta_get_local "$meta" effort)")" "$backend"
  if [ "$remote" != '-' ] && [ -n "$remote" ]; then
    printf -- '- remote host: %s (its own home reconciles this work; do not drive it from here)\n' "$remote"
  fi
  printf -- '- endpoint: %s (%s)\n' "$target" "$endpoint"

  if [ "$wt_present" = present ]; then
    printf -- '- local copy: %s\n' "$wt"
    if printf '%s\n' "${RESUME_DUP_WORKTREES:-}" | grep -Fqx -- "$wt"; then
      printf -- '  - SHARED: another task in this home records the same local copy; resolve which one owns it before resuming either\n'
    fi
    # The directory being there is not the same fact as git being able to read
    # it. Saying so once beats printing four unknowns and leaving a reader to
    # work out which failure produced them.
    if [ "$(git_fact "$wt" readable)" = yes ]; then
      local branch head dirty unpushed
      branch=$(git_fact "$wt" branch)
      head=$(git_fact "$wt" head)
      dirty=$(git_fact "$wt" dirty)
      unpushed=$(git_fact "$wt" unpushed)
      printf -- '- branch: %s head: %s uncommitted: %s unpushed commits: %s\n' \
        "$branch" "$head" "$dirty" "$unpushed"
      resume_pipeline_line "$wt"
    else
      printf -- '- branch: unknown head: unknown uncommitted: unknown unpushed commits: unknown\n'
      printf -- '  - the directory is present but git cannot read it as a repository, so nothing about its contents was measured; it may have been pruned or moved\n'
      printf -- '- pipeline: not read (the local copy is not a readable repository)\n'
    fi
  else
    printf -- '- local copy: %s (absent)\n' "$wt"
    printf -- '- pipeline: not read (no local copy to read it from)\n'
  fi

  printf -- '- pull request: %s\n' "$pr"
  printf -- '- current state: %s\n' "$state"
  printf -- '- open captain calls: %s\n' "$([ "$decisions" = '-' ] && printf '(none)' || printf '%s' "$decisions")"
  printf -- '- delivered instructions: %s acknowledged, %s still unread by the worker\n\n' \
    "$(steering_fact "$id" acknowledged)" "$(steering_fact "$id" unread)"
}

resume_pipeline_line() {  # <worktree>
  local wt=$1 run run_id run_status run_head failed custody next binding
  run=$(attributed_run "$wt") || run=
  if [ -z "$run" ]; then
    printf -- '- pipeline: no run is attributed to this local copy\n'
    return 0
  fi
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$run" id)")
  run_status=$(fm_nm_strip_quotes "$(fm_nm_field "$run" status)")
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$run" head)")
  failed=$(failed_steps "$run" | tr '\n' ',' | sed 's/,$//')
  custody=$(fm_nm_branch_sync_state "$run")
  next=$(branch_sync_field "$run" code)
  binding=$(head_binding "$wt" "$run_head")
  printf -- '- pipeline: run=%s status=%s failed-steps=%s custody=%s next-action=%s head=%s (%s)\n' \
    "$run_id" "$(dash "$run_status")" "$(dash "$failed")" "$(dash "$custody")" "$(dash "$next")" \
    "$(dash "$run_head")" "$binding"
  case "$custody" in
    pipeline_owned*|blocked_pipeline_owned*)
      printf -- '  - the pipeline owns this branch; settle custody through its next-action before any new work on it\n'
      ;;
  esac
  case "$binding" in
    pipeline-only|pipeline-ahead)
      printf -- '  - the run holds commits this local copy does not have; rebuilding from the local head would silently redo work that already exists\n'
      ;;
  esac
}

posture_note() {  # <yolo>
  case "$1" in
    on) printf 'firstmate may merge green, in-scope work itself' ;;
    *) printf 'the captain approves every merge' ;;
  esac
}

dash() {  # <value>
  if [ -z "${1:-}" ]; then printf -- '-'; else printf '%s' "$1"; fi
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  headroom) shift; cmd_headroom "$@" ;;
  diagnose) shift; cmd_diagnose "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) printf 'fm-usage-wall: unknown command: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
