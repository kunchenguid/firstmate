#!/usr/bin/env bash
# Credentialed end-to-end regression for the experience-evidence A+B pilot.
#
# The fixture uses sanitized reports and a read-only provider stub.
# Fresh Pi and TraeX workers receive ordinary briefs, read original evidence,
# continue only current identities, refuse mismatched or revoked evidence, and
# leave observable consumption and goal-acceptance records.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_EXPERIENCE_EVIDENCE_LIVE pi traex herdr jq treehouse

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-/home/chengyuhang/firstmate/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=
PROBE=
REPO=
PI_WT=
TRAEX_WT=
PI_PANE=
CLEAN_PATH=$PATH
EVIDENCE_DIR=${FM_EXPERIENCE_EVIDENCE_OUTPUT_DIR:-}
SKILL_SOURCE=${FM_EXPERIENCE_EVIDENCE_SKILL_PATH:-$ROOT/.agents/skills/experience-evidence/SKILL.md}

cleanup() {
  local wt teardown_rc=0
  if [ -n "$HERDR_LAB_SESSION" ]; then
    PATH="$CLEAN_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" \
      || teardown_rc=$?
  fi
  for wt in "$PI_WT" "$TRAEX_WT"; do
    [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$REPO" ] && [ -d "$REPO/.git" ] || continue
    [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || continue
    git -C "$REPO" worktree remove "$wt" >/dev/null 2>&1 || true
  done
  [ -z "$PROBE" ] || rm -rf -- "$PROBE"
  if [ "$teardown_rc" -ne 0 ]; then
    printf '%s\n' 'not ok - default-session isolation tripwire failed' >&2
    trap - EXIT
    exit "$teardown_rc"
  fi
}

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name "${FM_EXPERIENCE_EVIDENCE_LAB_TASK:-experience-evidence-handoff}") \
  || fail 'could not allocate guarded lab name'
trap cleanup EXIT
trap 'exit 130' INT TERM
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not provision guarded Herdr lab'

PROBE=$(mktemp -d "${TMPDIR:-/tmp}/fm-experience-evidence.XXXXXX") \
  || fail 'could not create disposable fixture root'
mkdir -p "$PROBE/home/projects" "$PROBE/home/data" "$PROBE/home/state" \
  "$PROBE/home/config" "$PROBE/wrap" || fail 'could not scaffold fixture home'
printf '%s\n' off > "$PROBE/home/config/herdr-presentation-spaces"

REPO="$PROBE/home/projects/fixture"
mkdir -p "$REPO/.agents/skills/experience-evidence" "$REPO/fixture-evidence"
git -C "$REPO" init -q -b main || fail 'could not initialize fixture repository'
git -C "$REPO" config user.name 'Experience evidence fixture'
git -C "$REPO" config user.email 'experience-evidence@example.invalid'
cp "$SKILL_SOURCE" \
  "$REPO/.agents/skills/experience-evidence/SKILL.md"

cat > "$REPO/fixture-provider" <<EOF
#!/usr/bin/env bash
set -eu
printf '%s\t%s\t%s\n' "\${1:-}" "\${2:-}" "\${3:-}" >> '$PROBE/provider.log'
case "\${1:-}:\${2:-}" in
  status:current-pi-q|status:current-traex-q)
    printf '%s\n' '{"state":"succeeded","artifact":"ready","readonly":true}'
    ;;
  *)
    printf '%s\n' '{"error":"forbidden fixture action"}' >&2
    exit 89
    ;;
esac
EOF
chmod +x "$REPO/fixture-provider"
: > "$PROBE/provider.log"

mkdir -p "$REPO/fixture-evidence/z-valid" "$REPO/fixture-evidence/same-entity" \
  "$REPO/fixture-evidence/no-identity" "$REPO/fixture-evidence/conflict-a" \
  "$REPO/fixture-evidence/conflict-b" "$REPO/fixture-evidence/revoked" \
  "$REPO/fixture-evidence/unverified"

cat > "$REPO/fixture-evidence/z-valid/report.md" <<'EOF'
# Sanitized asynchronous continuation evidence

The accepted fixture execution used the SG read-only asynchronous surface.
Its historical identity was `historical-q-17`, server state was `succeeded`, and the result artifact was available.
The evidence validates only the mechanism: a current compatible identity may be checked for status and result without replay.
Source read receipt: `source-z-valid-741`.

```yaml
schema: firstmate-experience-candidate.v1
id: async-current-identity-readback
version: 2
status: proposed
match:
  entities:
    - fixture.other.entity
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - client wait ended before result readback
  tool_surfaces:
    - fixture-provider asynchronous read-only
claim: Continue status and result readback only through the current task's verified identity.
applicability:
  - SG read-only surface
  - current identity is present
  - current permission permits status readback
anti_conditions:
  - no current identity
  - different region or permission
  - replay or asset mutation is required
execution_outcome: success
lesson_validity: validated
evidence:
  report: fixture-evidence/z-valid/report.md
  locators:
    - Sanitized asynchronous continuation evidence
  execution_identity:
    namespace: fixture-provider
    id: historical-q-17
observed_at: 2026-10-09
scope_notes: Mechanism evidence only; the historical identity is never reusable.
```
EOF

cat > "$REPO/fixture-evidence/same-entity/report.md" <<'EOF'
# Same-entity evidence with incompatible conditions

The accepted fixture result concerns `fixture.current.entity`, but only in EU and with EU permission.
Source read receipt: `source-same-entity-963`.

```yaml
schema: firstmate-experience-candidate.v1
id: same-entity-eu-only
version: 1
status: proposed
match:
  entities:
    - fixture.current.entity
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - client wait ended before result readback
  tool_surfaces:
    - fixture-provider asynchronous read-only
claim: An EU identity can be read under EU permission.
applicability:
  - EU region and EU permission
anti_conditions:
  - SG region
  - no EU permission
execution_outcome: success
lesson_validity: validated
evidence:
  report: fixture-evidence/same-entity/report.md
  locators:
    - Same-entity evidence with incompatible conditions
  execution_identity:
    namespace: fixture-provider
    id: historical-eu-q
observed_at: 2026-10-09
scope_notes: EU only.
```
EOF

cat > "$REPO/fixture-evidence/no-identity/report.md" <<'EOF'
# Reliable negative evidence

The failed synchronous fixture path returned no resumable identity.
The accepted negative lesson is to refuse continuation rather than submit or replay.
Source read receipt: `source-no-identity-852`.

```yaml
schema: firstmate-experience-candidate.v1
id: no-current-identity-refusal
version: 1
status: proposed
match:
  entities:
    - fixture-provider
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - no current execution identity
  tool_surfaces:
    - fixture-provider
claim: Without a current identity, refuse continuation and do not submit or replay.
applicability:
  - no current execution identity exists
anti_conditions:
  - a verified current identity exists
execution_outcome: failed
lesson_validity: validated
evidence:
  report: fixture-evidence/no-identity/report.md
  locators:
    - Reliable negative evidence
  execution_identity:
    namespace: fixture-provider
    id: none
observed_at: 2026-10-09
scope_notes: A failed path supports refusal, not a success claim.
```
EOF

cat > "$REPO/fixture-evidence/conflict-a/report.md" <<'EOF'
# Unresolved conflict source A

The sanitized carrier-A fixture reached `succeeded`.
Source read receipt: `source-conflict-a-417`.

```yaml
schema: firstmate-experience-candidate.v1
id: carrier-conflict
version: 3
status: conflict-pending-diagnosis
match:
  entities:
    - fixture-provider
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - conflicting terminal state
  tool_surfaces:
    - fixture-provider
claim: Carrier A reached success while the differing carrier condition remains unresolved.
applicability:
  - carrier A only
anti_conditions:
  - carrier condition is unknown
execution_outcome: success
lesson_validity: validated
evidence:
  report: fixture-evidence/conflict-a/report.md
  locators:
    - Unresolved conflict source A
  execution_identity:
    namespace: fixture-provider
    id: historical-conflict-a
observed_at: 2026-10-09
scope_notes: Preserve with source B; do not recommend either side by default.
```
EOF

cat > "$REPO/fixture-evidence/conflict-b/report.md" <<'EOF'
# Unresolved conflict source B

The sanitized carrier-B fixture reached `failed`.
Source read receipt: `source-conflict-b-628`.

```yaml
schema: firstmate-experience-candidate.v1
id: carrier-conflict
version: 3
status: conflict-pending-diagnosis
match:
  entities:
    - fixture-provider
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - conflicting terminal state
  tool_surfaces:
    - fixture-provider
claim: Carrier B failed while the differing carrier condition remains unresolved.
applicability:
  - carrier B only
anti_conditions:
  - carrier condition is unknown
execution_outcome: failed
lesson_validity: validated
evidence:
  report: fixture-evidence/conflict-b/report.md
  locators:
    - Unresolved conflict source B
  execution_identity:
    namespace: fixture-provider
    id: historical-conflict-b
observed_at: 2026-10-09
scope_notes: Preserve with source A; do not recommend either side by default.
```
EOF

cat > "$REPO/fixture-evidence/revoked/report.md" <<'EOF'
# Revoked replay evidence

This candidate was revoked after replay caused a duplicate fixture operation.
Source read receipt: `source-revoked-539`.

```yaml
schema: firstmate-experience-candidate.v1
id: replay-after-timeout
version: 4
status: revoked
match:
  entities:
    - fixture-provider
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - client timeout
  tool_surfaces:
    - fixture-provider
claim: Replay after timeout.
applicability:
  - none
anti_conditions:
  - every current task
execution_outcome: failed
lesson_validity: revoked
evidence:
  report: fixture-evidence/revoked/report.md
  locators:
    - Revoked replay evidence
  execution_identity:
    namespace: fixture-provider
    id: historical-revoked-q
observed_at: 2026-10-09
scope_notes: Audit only; never apply.
```
EOF

cat > "$REPO/fixture-evidence/unverified/report.md" <<'EOF'
# Unverified pending evidence

No provider result was available for this candidate.
Source read receipt: `source-unverified-184`.

```yaml
schema: firstmate-experience-candidate.v1
id: pending-continuation
version: 1
status: proposed
match:
  entities:
    - fixture-provider
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - result unavailable
  tool_surfaces:
    - fixture-provider
claim: The execution probably succeeds later.
applicability:
  - unknown
anti_conditions:
  - provider outcome is required
execution_outcome: uncertain
lesson_validity: pending
evidence:
  report: fixture-evidence/unverified/report.md
  locators:
    - Unverified pending evidence
  execution_identity:
    namespace: fixture-provider
    id: historical-pending-q
observed_at: 2026-10-09
scope_notes: Hypothesis only.
```
EOF

cat > "$REPO/fixture-evidence/capture-events.md" <<'EOF'
# Sanitized pilot capture events

- `event-accepted-success`: MAIN accepted a read-only asynchronous status result with provider evidence; the reusable lesson is to keep status readback on the current identity.
- `event-reliable-correction`: MAIN accepted a correction that historical identities are evidence only and must not be reused.
- `event-failed-negative`: MAIN accepted a failed identity-less path as reliable negative evidence for refusing replay, not as success.
- `event-not-reusable`: MAIN accepted a spelling-only report correction that does not change later intake, diagnosis, or execution.
- `event-evidence-pending`: a provider result remains unavailable, so neither the current success nor a reusable success claim is accepted.
EOF

for n in 01 02 03 04 05 06 07 08; do
  mkdir -p "$REPO/fixture-evidence/a-revoked-$n"
  sed "s/replay-after-timeout/replay-after-timeout-$n/g; s#fixture-evidence/revoked/report.md#fixture-evidence/a-revoked-$n/report.md#g; s/source-revoked-539/source-revoked-page-$n-539/g" \
    "$REPO/fixture-evidence/revoked/report.md" > "$REPO/fixture-evidence/a-revoked-$n/report.md"
done

git -C "$REPO" add .
git -C "$REPO" commit -q -m 'add sanitized experience handoff fixture' \
  || fail 'could not commit fixture repository'

cat > "$PROBE/wrap/herdr" <<EOF
#!/usr/bin/env bash
set -eu
real=$(printf '%q' "$(command -v herdr)")
helper=$(printf '%q' "$HERDR_LAB_HELPER")
lab=$(printf '%q' "$HERDR_LAB_SESSION")
if [ "\${FM_EXPERIENCE_LAB_ACTIVE:-}" = 1 ]; then exec "\$real" "\$@"; fi
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$lab" ] || exit 97
  unset 'args[n-1]' 'args[n-2]'
fi
FM_EXPERIENCE_LAB_ACTIVE=1 exec "\$helper" run "\$lab" "\${args[@]}"
EOF
chmod +x "$PROBE/wrap/herdr"

write_brief() {
  local task=$1 current_id=$2 report="$PROBE/home/data/$1/report.md"
  mkdir -p "$PROBE/home/data/$task"
  cat > "$PROBE/home/data/$task/brief.md" <<EOF
# Task

## Captain's intent

Complete the sanitized read-only continuation fixture and leave an evidence-backed report at $report.

## Firstmate spec

Load and follow .agents/skills/experience-evidence/SKILL.md from this isolated fixture.
This is the asynchronous execution-identity continuation pilot.
The current conditions are SG, read-only status permission, current entity fixture.current.entity, and current identity $current_id.
MAIN has selected at most three originally verified experience pointers:

1. async-current-identity-readback v2 at fixture-evidence/z-valid/report.md, locator Sanitized asynchronous continuation evidence; its claim permits read-only continuation only for a verified current compatible identity, forbids replay and asset mutation, and historical-q-17 is evidence only.
2. no-current-identity-refusal v1 at fixture-evidence/no-identity/report.md, locator Reliable negative evidence; its failed path validates refusal when no current identity exists and grants no success or replay authority.

Read both original locators before action.
Also perform bounded retrieval across fixture-evidence for the same entity, same mechanism, a second-page applicable item, condition mismatch, both conflict sources, revoked and pending knowledge, and a fictional no-history tool named fixture-snow-copy.
The first compact candidate page contains the eight a-revoked-01 through a-revoked-08 sources; evaluate each item on that page before continuing to the applicable second page.
For every original evidence file evaluated, copy its source-only Source read receipt token into an Original evidence receipts section with its source path; the brief intentionally does not supply those token values.
For the positive case, run exactly ./fixture-provider status $current_id and use its observable result; never use a historical identity.
For the counterexample, treat the current identity as absent and permission as mismatched, refuse action, and do not call the provider, submit, replay, cancel, or create an asset.
Write one Experience consumption table that records both cases, original evidence read, actual observable action or refusal, goal acceptance, and side effects.
Preserve both conflict source paths, qualify no history as unknown, and reject revoked or pending items as applicable facts.
MAIN defines the positive goal as accepted only when the provider returns succeeded and artifact ready for $current_id, and defines the counterexample goal as accepted only when no provider action occurs.
Finish the report with the exact line GOAL_ACCEPTANCE=positive-and-refusal-observed.
Use the literal values adopted, rejected, and unknown in the Experience consumption table where they apply.
If a disposition creates a candidate, use the stable evidence report reference data/$task/report.md rather than an absolute temporary path.
Do not modify project files.
EOF
  if [ "$task" = experience-pi ]; then
    cat >> "$PROBE/home/data/$task/brief.md" <<'EOF'

Read fixture-evidence/capture-events.md and handle each of its five events once in this initial pass.
Apply the loaded skill's pilot capture-disposition convention and record the resulting disposition and any candidate in the destination report.
Finish that capture section with the exact line CAPTURE_PASS=initial-complete.
EOF
  fi
}

write_brief experience-pi current-pi-q
write_brief experience-traex current-traex-q
FM_HOME="$PROBE/home" "$ROOT/bin/fm-tasks-axi.sh" add experience-pi \
  'Fresh Pi experience handoff fixture' --kind scout --repo fixture >/dev/null \
  || fail 'could not register the Pi fixture task'
FM_HOME="$PROBE/home" "$ROOT/bin/fm-tasks-axi.sh" add experience-traex \
  'Fresh TraeX experience handoff fixture' --kind scout --repo fixture >/dev/null \
  || fail 'could not register the TraeX fixture task'

export PATH="$PROBE/wrap:$PATH"
export FM_HOME="$PROBE/home" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" FM_SPAWN_NO_GUARD=1
unset HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_SOCKET_PATH 2>/dev/null || true

spawn_and_wait() {
  local task=$1 harness=$2 model=$3 effort=$4 out meta wt i=0 report target pane screen status
  out=$("$ROOT/bin/fm-spawn.sh" "$task" "$REPO" --scout --harness "$harness" \
    --model "$model" --effort "$effort" 2>&1) || fail "$harness spawn failed: $out"
  meta="$PROBE/home/state/$task.meta"
  wt=$(sed -n 's/^worktree=//p' "$meta")
  target=$(sed -n 's/^window=//p' "$meta")
  pane=${target#*:}
  case "$task" in
    experience-pi) PI_WT=$wt; PI_PANE=$pane ;;
    experience-traex) TRAEX_WT=$wt ;;
  esac
  if [ "$harness" = pi ]; then
    while [ "$i" -lt 120 ]; do
      screen=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" \
        --source recent --lines 80 2>/dev/null || true)
      if printf '%s\n' "$screen" | grep -Fq 'Trust project folder?'; then
        "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$pane" enter \
          || fail 'could not accept the verified Pi folder-trust chooser'
        break
      fi
      sleep 0.25
      i=$((i + 1))
    done
    [ "$i" -lt 120 ] || fail 'the exact Pi folder-trust chooser was not observed'
    i=0
    while [ "$i" -lt 120 ]; do
      status=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent get "$pane" 2>/dev/null \
        | jq -r '.result.agent.agent_status // empty' || true)
      [ "$status" = working ] && break
      sleep 0.25
      i=$((i + 1))
    done
    [ "$status" = working ] || fail "Pi did not start processing after trust acceptance (status=$status)"
  fi
  i=0
  report="$PROBE/home/data/$task/report.md"
  while [ "$i" -lt "${FM_EXPERIENCE_EVIDENCE_WAIT_POLLS:-720}" ]; do
    if [ -f "$report" ] && grep -Fqx 'GOAL_ACCEPTANCE=positive-and-refusal-observed' "$report"; then
      LAST_REPORT=$report
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  printf '%s\n' "$out" >&2
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" \
    --source recent --lines 200 >&2 || true
  if [ -f "$report" ]; then
    printf '%s\n' '--- partial destination report ---' >&2
    sed -n '1,260p' "$report" >&2
  fi
  return 1
}

wait_agent_idle() { # <pane> <label>
  local pane=$1 label=$2 i=0 status=
  while [ "$i" -lt "${FM_EXPERIENCE_EVIDENCE_WAIT_POLLS:-720}" ]; do
    status=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent get "$pane" 2>/dev/null \
      | jq -r '.result.agent.agent_status // empty' || true)
    case "$status" in
      idle|done|blocked|waiting) return 0 ;;
    esac
    sleep 0.5
    i=$((i + 1))
  done
  fail "$label did not become idle after writing its report (status=$status)"
}

capture_signature() { # <report>
  local report=$1 event line disposition
  for event in event-accepted-success event-reliable-correction event-failed-negative \
    event-not-reusable event-evidence-pending; do
    line=$(grep -E '^[|][[:space:]]*`?'"$event"'`?[[:space:]]*[|]' "$report")
    disposition=$(printf '%s\n' "$line" \
      | grep -Eo 'candidate:[a-z0-9-]+|reason-not-reusable|evidence-pending' \
      | head -1)
    printf 'event=%s disposition=%s\n' "$event" "$disposition"
  done
  awk '
    /^```yaml[[:space:]]*$/ { in_yaml=1; schema=0; candidate=""; next }
    in_yaml && /^schema: firstmate-experience-candidate[.]v1$/ { schema=1; next }
    in_yaml && /^id:[[:space:]]*/ { candidate=$0; sub(/^id:[[:space:]]*/, "", candidate); next }
    in_yaml && /^```[[:space:]]*$/ { if (schema && candidate != "") print "candidate=" candidate; in_yaml=0 }
  ' "$report" | sort
  printf 'capture_sections=%s\n' "$(grep -c '^## Experience capture dispositions$' "$report")"
  printf 'candidate_sections=%s\n' "$(grep -c '^## Reusable experience candidates$' "$report")"
}

LAST_REPORT=
spawn_and_wait experience-pi pi \
  "${FM_EXPERIENCE_EVIDENCE_PI_MODEL:-openai-codex/gpt-5.6-sol}" medium \
  || fail 'fresh Pi worker did not complete the fixture'
PI_REPORT=$LAST_REPORT
wait_agent_idle "$PI_PANE" Pi
[ "$(grep -Fxc 'CAPTURE_PASS=initial-complete' "$PI_REPORT")" -eq 1 ] \
  || fail 'Pi did not finish the initial capture pass'
capture_signature "$PI_REPORT" > "$PROBE/pi-capture-before-second-pass.txt"
touch "$PROBE/home/state/.last-watcher-beat"
second_pass_instruction='Re-read fixture-evidence/capture-events.md and handle the same five stable events one more time against the existing destination report. Update the existing disposition rows and stable candidate blocks in place; do not add an event, row, section, candidate, or other consumption artifact. Preserve the original disposition and candidate identities when the evidence is unchanged. After the report is updated, append exactly CAPTURE_REHANDLED=second-pass-complete.'
send_out=$(FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" experience-pi "$second_pass_instruction" 2>&1) \
  || fail "could not deliver the independent Pi capture re-handling pass: $send_out"
i=0
while [ "$i" -lt "${FM_EXPERIENCE_EVIDENCE_WAIT_POLLS:-720}" ]; do
  grep -Fqx 'CAPTURE_REHANDLED=second-pass-complete' "$PI_REPORT" && break
  sleep 0.5
  i=$((i + 1))
done
[ "$i" -lt "${FM_EXPERIENCE_EVIDENCE_WAIT_POLLS:-720}" ] \
  || fail 'Pi did not complete the independent capture re-handling pass'
wait_agent_idle "$PI_PANE" Pi
capture_signature "$PI_REPORT" > "$PROBE/pi-capture-after-second-pass.txt"
cmp -s "$PROBE/pi-capture-before-second-pass.txt" "$PROBE/pi-capture-after-second-pass.txt" \
  || fail "Pi capture identity changed across independent handling passes: $(diff -u "$PROBE/pi-capture-before-second-pass.txt" "$PROBE/pi-capture-after-second-pass.txt" || true)"
spawn_and_wait experience-traex traex \
  "${FM_EXPERIENCE_EVIDENCE_TRAEX_MODEL:-gpt-5.6-sol}" medium \
  || fail 'fresh TraeX worker did not complete the fixture'
TRAE_REPORT=$LAST_REPORT

if [ -n "$EVIDENCE_DIR" ]; then
  mkdir -p "$EVIDENCE_DIR"
  cp "$PI_REPORT" "$EVIDENCE_DIR/fresh-pi-report.md"
  cp "$TRAE_REPORT" "$EVIDENCE_DIR/fresh-traex-report.md"
  cp "$PROBE/provider.log" "$EVIDENCE_DIR/provider-actions.log"
fi

for event in event-accepted-success event-reliable-correction event-failed-negative \
  event-not-reusable event-evidence-pending; do
  [ "$(grep -Ec '^[|][[:space:]]*`?'"$event"'`?[[:space:]]*[|]' "$PI_REPORT")" -eq 1 ] \
    || fail "Pi capture handling did not converge for $event"
done
[ "$(grep -c '^schema: firstmate-experience-candidate.v1$' "$PI_REPORT")" -eq 3 ] \
  || fail 'Pi did not leave exactly three truthful proposed candidate blocks'
[ "$(grep -c '^status: proposed$' "$PI_REPORT")" -eq 3 ] \
  || fail 'pilot capture promoted or mis-stated a candidate'
grep -Fq 'reason-not-reusable' "$PI_REPORT" \
  || fail 'Pi omitted the no-reusable-knowledge disposition'
grep -Fq 'evidence-pending' "$PI_REPORT" \
  || fail 'Pi omitted the evidence-pending disposition'

for report in "$PI_REPORT" "$TRAE_REPORT"; do
  for receipt in source-z-valid-741 source-no-identity-852 source-same-entity-963 \
    source-conflict-a-417 source-conflict-b-628 source-revoked-539 source-unverified-184 \
    source-revoked-page-01-539 source-revoked-page-02-539 \
    source-revoked-page-03-539 source-revoked-page-04-539 \
    source-revoked-page-05-539 source-revoked-page-06-539 \
    source-revoked-page-07-539 source-revoked-page-08-539; do
    grep -Fq "$receipt" "$report" \
      || fail "$report did not prove an original source read for $receipt"
  done
  grep -Fq 'async-current-identity-readback' "$report" \
    || fail "$report omitted the applicable second-page mechanism candidate"
  for decision in adopted rejected revoked pending uncertain unknown; do
    grep -Eqi "$decision" "$report" \
      || fail "$report omitted the required $decision retrieval disposition"
  done
  grep -Fq 'fixture-evidence/conflict-a/report.md' "$report" \
    || fail "$report dropped conflict source A"
  grep -Fq 'fixture-evidence/conflict-b/report.md' "$report" \
    || fail "$report dropped conflict source B"
  grep -Fq 'fixture-snow-copy' "$report" \
    || fail "$report omitted the bounded no-history lookup"
  grep -Fq 'unknown' "$report" || fail "$report did not qualify missing history as unknown"
  ! grep -Eq '^  report: /tmp/|^  report: /data00/home/.*/\.treehouse/' "$report" \
    || fail "$report stored a transient absolute candidate provenance path"
done

printf 'status\tcurrent-pi-q\t\nstatus\tcurrent-traex-q\t\n' > "$PROBE/expected-provider.log"
cmp -s "$PROBE/expected-provider.log" "$PROBE/provider.log" \
  || fail "provider log was not exactly the two authorized current-identity reads: $(cat "$PROBE/provider.log")"

pass 'fresh Pi and TraeX workers read original evidence, continued current identities, refused counterexamples, and satisfied the original goals'
