#!/usr/bin/env bash
# fm-chatgpt-loop.sh - Firstmate-owned ChatGPT -> worker -> ChatGPT -> worker
# orchestration state machine.
# Usage: fm-chatgpt-loop.sh init --task ID --objective-file FILE [--context-file FILE] [--thread ID]
#        fm-chatgpt-loop.sh consult --stage audit|plan [--findings-file FILE] --task ID
#        fm-chatgpt-loop.sh dispatch --stage audit|plan [--effort E] --task ID -- <fm-spawn args>
#        fm-chatgpt-loop.sh record-findings --task ID [--file FILE]
#        fm-chatgpt-loop.sh record-result --task ID --file FILE
#        fm-chatgpt-loop.sh record-worker-failure --task ID --stage audit|plan --reason TEXT
#        fm-chatgpt-loop.sh next-round --task ID
#        fm-chatgpt-loop.sh status --task ID
#        fm-chatgpt-loop.sh bridge status|start|stop
#
# Firstmate owns everything about this workflow: the per-task state file, the
# ChatGPT consultation lifecycle, worker dispatch, worker results, iteration
# between audit and planning, and the bridge daemon lifecycle. The worker is
# an ordinary worker spawn (fm-spawn.sh with a per-stage --effort selection
# defaulting to low; dispatch refuses before launching when the passthrough
# spawn args carry their own --effort) and never
# touches the bridge; nothing in the dispatch path starts, stops, or probes
# it. The prompt handoff belongs to dispatch: right after a successful spawn,
# dispatch steers the stored stage prompt (the ChatGPT-generated audit prompt
# for --stage audit, the plan for --stage plan) to that worker through
# fm-send.sh with an
# explicit FM_HOME and state root, addressed at the plain task id that must
# lead the args after --, and refuses before launching when that leading
# token is absent or not a plain task id (never a token scanned from option
# values). The spawn itself carries FM_CHATGPT_LOOP_DISPATCH_TASK=<this loop's
# task id> so bin/fm-spawn.sh's consultation gate recognizes it as the loop's own
# dispatch: a worker task with no record of its own satisfies the gate through
# this loop record's dispatch-phase stage prompt, never through the marker alone
# (bin/fm-consult-gate-lib.sh owns that rule).
# A failed spawn records last_error, leaves the phase at
# <stage>-dispatch, and
# exits nonzero; record-worker-failure likewise returns the phase to
# <stage>-dispatch (never toward the next stage) so the same stage retries
# cleanly through dispatch. The bridge is the already-installed
# codex-chatgpt-web daemon and is never installed, authenticated, or
# repaired here.
#
# State file: $FM_HOME/data/<task-id>/chatgpt-loop.json, one JSON object with
# task_id, objective, context, thread, phase, iteration, audit_prompt,
# audit_result, findings, findings_source, worker_task, plan, worker_result,
# last_error, and updated_at.
# audit_prompt stores the banner-stripped ChatGPT-generated worker audit
# prompt that audit dispatch steers; objective and context stay in state for
# the plan packet. findings_source records the prior-audit path cited to a
# plan consult, and worker_task records the task id the last dispatch handed
# the stage prompt to.
# Phases: audit-consult -> audit-dispatch -> audit-worker -> plan-consult ->
# plan-dispatch -> plan-worker -> complete. next-round increments iteration
# and returns to audit-consult so further audit/plan cycles stay possible, and
# clears the finished round's scoped fields (audit_prompt, audit_result,
# findings, findings_source, worker_task, plan, worker_result, last_error) so a
# finished round's prompt can never pass bin/fm-consult-gate-lib.sh's dispatch
# gate as the new round's consultation.
# A wrong-phase call refuses with a nonzero exit and no state change.
#
# Findings feedback is part of stage completion, never a separate afterthought:
# after the audit worker reports done, record-findings is the completion step
# that persists the worker's findings and advances audit-worker -> plan-consult
# in one state write, so a successful audit can never advance to the plan with
# empty findings and a failed record never marks the worker complete. The
# findings file defaults to the dispatched worker's report at
# $DATA/<worker_task>/report.md when --file is omitted; a missing or
# whitespace-only result is refused with the phase unchanged so the same stage
# retries. The same non-empty rule governs a prior audit cited to the plan
# consult below.
#
# The plan stage is reachable from a prior audit without a redundant
# audit-worker cycle: consult --stage plan accepts --findings-file FILE, and a
# usable file (existing, non-empty) lets the call run from audit-consult or
# audit-worker as well as plan-consult. The evidence path is recorded in
# findings_source, its content becomes findings, and the consult advances to
# plan-dispatch; a missing or empty file is refused with the phase unchanged.
# Without --findings-file the plan consult still requires plan-consult.
#
# Cited evidence never goes out as a bare reference: both prompt builders
# inline the content of every evidence path cited with the @[path] marker
# in user-controlled text (objective, context, findings), and the plan
# builder inlines its --findings-file
# the same way. Only user-controlled text is a citation source: a marker
# in model-generated text (audit prompt, audit result) is refused loudly
# instead of being resolved or sent bare. Resolution tries an absolute path as-is, then a relative path
# against the task data directory $DATA/<task-id> first and $HOME second; only
# a readable regular file is accepted. The original citation text stays
# visible in the prompt and each inlined block is delimited by the resolved
# source path. An unresolvable or unreadable citation fails prompt
# construction loudly on stderr with the attempted candidates and a nonzero
# return before the bridge is contacted, so a prompt carrying a dangling
# reference is never sent.
#
# Effort has one owner per dispatch: dispatch --effort is the per-stage
# selection and defaults to low, while the passthrough spawn args may carry
# the spawn interface's own --effort. Exactly one --effort reaches fm-spawn:
# the passthrough value is used when present, otherwise the dispatch selection
# is appended, and supplying both at once is refused as a conflict before
# launch. A duplicated or empty spawn-side --effort is refused before launch,
# including a bare --effort with no usable value and an empty --effort= value.

# The bridge keeps no conversation history keyed by thread id alone: every
# consultation is one self-contained turn, so consult assembles prior context
# into the prompt file itself. The audit consult carries the user objective
# plus Firstmate context and asks ChatGPT to generate a worker audit prompt
# rather than audit findings; the reply is stripped of any leading
# Local-tools-unavailable banner before it is stored, and a reply left empty
# by that stripping fails the consult with the phase unchanged. The plan prompt carries
# the objective, context, stored audit prompt, audit result, and worker
# findings, all explicitly included. bin/fm-chatgpt-consult.sh owns the
# transport and its fail-closed contract; this script owns state, prompts, and
# dispatch. On consult or
# bridge failure the phase is unchanged (retryable), last_error records the
# cause, and dispatch issues nothing.
#
# Test seam: FM_CHATGPT_LOOP_SPAWN overrides the fm-spawn.sh path,
# FM_CHATGPT_LOOP_CONSULT overrides the fm-chatgpt-consult.sh path, and
# FM_CHATGPT_LOOP_SEND overrides the fm-send.sh path. All three default to
# the sibling scripts beside this file. docs/configuration.md
# "ChatGPT consultation channel" owns the user-facing contract.
set -u

LIBDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-chatgpt-bridge-lib.sh
. "$LIBDIR/fm-chatgpt-bridge-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$LIBDIR/fm-pr-lib.sh"

FM_HOME="${FM_HOME:-$(cd "$LIBDIR/.." && pwd)}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SPAWN="${FM_CHATGPT_LOOP_SPAWN:-$LIBDIR/fm-spawn.sh}"
CONSULT_BIN="${FM_CHATGPT_LOOP_CONSULT:-$LIBDIR/fm-chatgpt-consult.sh}"
SEND="${FM_CHATGPT_LOOP_SEND:-$LIBDIR/fm-send.sh}"
BRIDGE_PID_FILE="$STATE/chatgpt-loop-bridge.pid"

usage() {
  printf 'usage: %s init --task ID --objective-file FILE [--context-file FILE] [--thread ID]\n' "$(basename "$0")" >&2
  printf '       %s consult --stage audit|plan [--findings-file FILE] --task ID\n' "$(basename "$0")" >&2
  printf '       %s dispatch --stage audit|plan [--effort E] --task ID -- <fm-spawn args>\n' "$(basename "$0")" >&2
  printf '       %s record-findings --task ID [--file FILE]\n' "$(basename "$0")" >&2
  printf '       %s record-result --task ID --file FILE\n' "$(basename "$0")" >&2
  printf '       %s record-worker-failure --task ID --stage audit|plan --reason TEXT\n' "$(basename "$0")" >&2
  printf '       %s next-round --task ID\n' "$(basename "$0")" >&2
  printf '       %s status --task ID\n' "$(basename "$0")" >&2
  printf '       %s bridge status|start|stop\n' "$(basename "$0")" >&2
}

loop_state_file() {
  printf '%s/%s/chatgpt-loop.json' "$DATA" "$1"
}

now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

read_field() {
  jq -r --arg k "$2" '.[$k] // empty' "$1"
}

write_field() {
  local file=$1 key=$2 value=$3 tmp
  tmp=$(mktemp) || return 1
  jq --arg k "$key" --arg v "$value" '.[$k] = $v | .updated_at = $now' --arg now "$(now_iso)" "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

need_state() {
  local file
  fm_task_id_creation_valid "$1" || { printf 'fm-chatgpt-loop: invalid task id: %s\n' "$1" >&2; return 1; }
  file=$(loop_state_file "$1")
  [ -f "$file" ] || { printf 'fm-chatgpt-loop: no loop state for task %s (run init first)\n' "$1" >&2; return 1; }
  printf '%s\n' "$file"
}

require_phase() {
  local file=$1 want=$2 actual
  actual=$(read_field "$file" phase)
  [ "$actual" = "$want" ] || { printf 'fm-chatgpt-loop: task %s is in phase %s, need %s; no state changed\n' "$3" "$actual" "$want" >&2; return 1; }
}

# require_phase_any <file> <task> <phase>...: pass only when the task's phase
# is one of the listed values. The plan consult uses it for the cited-evidence
# shortcut, where a prior audit may leave the task at audit-consult or
# audit-worker instead of the normal plan-consult.
require_phase_any() {
  local file=$1 task=$2 actual want
  shift 2
  actual=$(read_field "$file" phase)
  for want in "$@"; do
    [ "$actual" = "$want" ] && return 0
  done
  printf 'fm-chatgpt-loop: task %s is in phase %s, need one of %s; no state changed\n' "$task" "$actual" "$*" >&2
  return 1
}

# normalize_path <path>: print the path with its directory component resolved
# to a physical absolute path when that directory is inspectable. A path whose
# directory cannot be inspected is returned unchanged. A resolved citation is
# normalized before it is read so the same file always compares and prints the
# same way.
normalize_path() {
  local path=$1 dir base
  dir=$(dirname -- "$path")
  base=$(basename -- "$path")
  if [ -d "$dir" ]; then
    printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
  else
    printf '%s\n' "$path"
  fi
}

# resolve_citation <task> <cited-path>: resolve one cited evidence path and
# print the normalized path to a readable regular file. An absolute path is
# used as-is; a relative path is tried against the task data directory first
# and $HOME second. Nothing is invented: only the cited path itself is
# considered, and an unreadable result is a loud refusal naming the attempted
# candidates.
resolve_citation() {
  local task=$1 path=$2 candidate
  [ -n "$path" ] || { printf 'fm-chatgpt-loop: cited evidence path is empty\n' >&2; return 1; }
  case "$path" in
    /*)
      if [ -f "$path" ] && [ -r "$path" ]; then
        normalize_path "$path"
        return 0
      fi
      printf 'fm-chatgpt-loop: cited evidence not readable: %s\n' "$path" >&2
      return 1
      ;;
  esac
  candidate="$DATA/$task/$path"
  if [ -f "$candidate" ] && [ -r "$candidate" ]; then
    normalize_path "$candidate"
    return 0
  fi
  candidate="$HOME/$path"
  if [ -f "$candidate" ] && [ -r "$candidate" ]; then
    normalize_path "$candidate"
    return 0
  fi
  printf 'fm-chatgpt-loop: cited evidence not readable: %s (tried %s and %s)\n' "$path" "$DATA/$task/$path" "$HOME/$path" >&2
  return 1
}

# cited_paths <text>: print each unique cited evidence path in the text, one
# per line, in order of first appearance. The @[path] marker is the only
# syntax treated as a citation, so ordinary prose paths are never invented as
# sources; a cited path ends at the first ], so a ] cannot appear in it.
cited_paths() {
  printf '%s' "$1" | grep -o '@\[[^]]*\]' | sed -e 's/^@\[//' -e 's/\]$//' | awk '!seen[$0]++'
}

# refuse_model_citations <field-name> <text>: fail loudly when
# model-generated text contains anything shaped like a citation marker.
# Model output is emitted verbatim and is never a citation source, so a
# marker there is refused before the bridge is contacted instead of going
# out bare or triggering a model-directed local read.
refuse_model_citations() {
  local name=$1 text=$2
  if printf '%s' "$text" | grep -q '@\[[^]]*\]'; then
    printf 'fm-chatgpt-loop: refusing prompt: model-generated %s contains a citation marker; markers in model output are never resolved and never sent bare\n' "$name" >&2
    return 1
  fi
}

# inline_citations <task> <out> <user-text>: append one delimited evidence
# block per citation found in user-controlled text (objective, context,
# findings), after the original prompt text that cites it. Only
# user-controlled text is a citation source: model-generated fields are
# refused separately before the bridge is contacted. Every inlined
# evidence body is rescanned until no new citation appears, so a marker
# inside an inlined file is inlined or fails loudly like a top-level one.
# Each distinct citation is resolved once, which keeps citation cycles to
# one block per file. Every citation is resolved and checked readable
# before anything is written, so one unreadable or empty citation fails
# the whole prompt construction with a nonzero return instead of shipping
# a dangling reference.
inline_citations() {
  local task=$1 out=$2 text=$3 path resolved p content e seen qi
  local -a paths=() resolved_paths=() queue=()
  while IFS= read -r path; do
    queue+=("$path")
  done < <(cited_paths "$text")
  qi=0
  while [ "$qi" -lt "${#queue[@]}" ]; do
    p=${queue[$qi]}
    qi=$((qi + 1))
    seen=0
    if [ "${#paths[@]}" -gt 0 ]; then
      for e in "${paths[@]}"; do
        if [ "$e" = "$p" ]; then seen=1; break; fi
      done
    fi
    if [ "$seen" -eq 1 ]; then continue; fi
    resolved=$(resolve_citation "$task" "$p") || return 1
    paths+=("$p")
    resolved_paths+=("$resolved")
    content=$(cat "$resolved") || return 1
    while IFS= read -r path; do
      queue+=("$path")
    done < <(cited_paths "$content")
  done
  [ "${#paths[@]}" -gt 0 ] || return 0
  {
    printf '\nCited evidence (verbatim file content for each @[path] citation above):\n'
    local i
    for i in "${!paths[@]}"; do
      printf 'source: %s\n' "${resolved_paths[$i]}"
      printf -- '--- BEGIN CITED EVIDENCE: %s ---\n' "${resolved_paths[$i]}"
      cat "${resolved_paths[$i]}" || return 1
      printf -- '\n--- END CITED EVIDENCE: %s ---\n' "${resolved_paths[$i]}"
    done
  } >> "$out"
}

# findings_text <file>: print a usable findings file's content, or explain why
# it is unusable. A missing path and a whitespace-only file are both refusals,
# because an audit that records nothing must never look complete.
findings_text() {
  local file=$1 text
  [ -n "$file" ] || { printf 'fm-chatgpt-loop: no findings file given and no dispatched worker report to fall back on\n' >&2; return 1; }
  [ -f "$file" ] || { printf 'fm-chatgpt-loop: findings file not found: %s\n' "$file" >&2; return 1; }
  text=$(cat "$file") || return 1
  [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || { printf 'fm-chatgpt-loop: findings file is empty: %s\n' "$file" >&2; return 1; }
  printf '%s' "$text"
}

# persist_findings <state-file> <findings-file> <source> [phase]: atomically
# record findings and their source path, and optionally the phase, in one
# state write so a failed record can never leave a half-updated state. The
# plan consult's cited-evidence path passes no phase because the consult owns
# its own transition; record-findings passes plan-consult so a failed record
# never marks the audit worker complete.
persist_findings() {
  local file=$1 find_file=$2 source=$3 phase=${4:-} text tmp
  text=$(findings_text "$find_file") || return 1
  tmp=$(mktemp) || return 1
  if [ -n "$phase" ]; then
    jq --arg f "$text" --arg s "$source" --arg p "$phase" --arg now "$(now_iso)" \
      '.findings = $f | .findings_source = $s | .phase = $p | .updated_at = $now' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    jq --arg f "$text" --arg s "$source" --arg now "$(now_iso)" \
      '.findings = $f | .findings_source = $s | .updated_at = $now' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv "$tmp" "$file"
}

cmd_init() {
  local task="" objective_file="" context_file="" thread=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; task=$2; shift 2 ;;
      --objective-file) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; objective_file=$2; shift 2 ;;
      --context-file) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; context_file=$2; shift 2 ;;
      --thread) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; thread=$2; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-chatgpt-loop: unknown init argument %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: init needs --task\n' >&2; usage; return 2; }
  fm_task_id_creation_valid "$task" || { printf 'fm-chatgpt-loop: invalid task id: %s\n' "$task" >&2; return 2; }
  [ -n "$objective_file" ] || { printf 'fm-chatgpt-loop: init needs --objective-file\n' >&2; usage; return 2; }
  [ -f "$objective_file" ] || { printf 'fm-chatgpt-loop: objective file not found: %s\n' "$objective_file" >&2; return 2; }
  [ -z "$thread" ] && thread="chatgpt-loop-$task"
  local context=""
  if [ -n "$context_file" ]; then
    [ -f "$context_file" ] || { printf 'fm-chatgpt-loop: context file not found: %s\n' "$context_file" >&2; return 2; }
    context=$(cat "$context_file")
  fi
  local dir file objective tmp
  dir="$DATA/$task"
  mkdir -p "$dir" || return 1
  file=$(loop_state_file "$task")
  objective=$(cat "$objective_file")
  tmp=$(mktemp) || return 1
  jq -n --arg t "$task" --arg o "$objective" --arg c "$context" --arg th "$thread" --arg u "$(now_iso)" \
    '{task_id: $t, objective: $o, context: $c, thread: $th, phase: "audit-consult", iteration: 1, audit_prompt: "", audit_result: "", findings: "", findings_source: "", worker_task: "", plan: "", worker_result: "", last_error: "", updated_at: $u}' > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
  printf 'initialized task %s in phase audit-consult\n' "$task"
}

build_audit_prompt() {
  local file=$1 out=$2 task=$3 objective context
  objective=$(read_field "$file" objective)
  context=$(read_field "$file" context)
  {
    printf 'User objective:\n%s\n\n' "$objective"
    printf 'Firstmate context:\n%s\n' "$context"
  } > "$out" || return 1
  inline_citations "$task" "$out" "$objective"$'\n'"$context"
}

build_plan_prompt() {
  local file=$1 out=$2 task=$3 fsrc objective context audit_prompt audit_result findings
  objective=$(read_field "$file" objective)
  context=$(read_field "$file" context)
  audit_prompt=$(read_field "$file" audit_prompt)
  audit_result=$(read_field "$file" audit_result)
  findings=$(read_field "$file" findings)
  refuse_model_citations "audit prompt" "$audit_prompt" || return 1
  refuse_model_citations "audit result" "$audit_result" || return 1
  {
    printf 'User objective:\n%s\n\n' "$objective"
    printf 'Firstmate context:\n%s\n\n' "$context"
    printf 'Audit prompt sent earlier:\n%s\n\n' "$audit_prompt"
    printf 'ChatGPT audit result:\n%s\n\n' "$audit_result"
  } > "$out" || return 1
  fsrc=$(read_field "$file" findings_source)
  if [ -n "$fsrc" ]; then
    printf 'Worker audit findings (source: %s):\n' "$fsrc" >> "$out" || return 1
    printf -- '--- BEGIN CITED EVIDENCE: %s ---\n' "$fsrc" >> "$out" || return 1
    jq -r '.findings' "$file" >> "$out" || return 1
    printf -- '\n--- END CITED EVIDENCE: %s ---\n' "$fsrc" >> "$out" || return 1
  else
    printf 'Worker audit findings:\n%s\n' "$findings" >> "$out" || return 1
  fi
  inline_citations "$task" "$out" "$objective"$'\n'"$context"$'\n'"$findings"
}

# strip_local_tools_banner reads a consultation answer on stdin and writes it
# back with a leading "Local tools unavailable" blockquote removed. Only a
# leading contiguous blockquote run whose first content line names the banner
# is stripped, and only the blank separator after that run is trimmed; any
# later blockquote and every other byte are left untouched.
strip_local_tools_banner() {
  awk '
    { line[NR] = $0 }
    END {
      n = NR
      i = 1
      while (i <= n && line[i] ~ /^[[:space:]]*$/) i++
      if (i > n || line[i] !~ /^>.*Local tools unavailable/) {
        for (j = 1; j <= n; j++) print line[j]
        exit
      }
      j = i
      while (j <= n && line[j] ~ /^>/) j++
      while (j <= n && line[j] ~ /^[[:space:]]*$/) j++
      for (; j <= n; j++) print line[j]
    }
  '
}

cmd_consult() {
  local stage="" task="" findings_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; stage=$2; shift 2 ;;
      --task) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; task=$2; shift 2 ;;
      --findings-file) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; findings_file=$2; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-chatgpt-loop: unknown consult argument %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done
  case "$stage" in
    audit|plan) ;;
    *) printf 'fm-chatgpt-loop: consult needs --stage audit|plan\n' >&2; usage; return 2 ;;
  esac
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: consult needs --task\n' >&2; usage; return 2; }
  if [ "$stage" = audit ] && [ -n "$findings_file" ]; then
    printf 'fm-chatgpt-loop: consult --findings-file applies only to --stage plan\n' >&2
    usage
    return 2
  fi
  local file thread resolved_findings=""
  file=$(need_state "$task") || return 1
  # The normal gate is one phase per stage. A plan consult carrying a usable
  # prior-audit file additionally reaches plan from the pre-plan phases, which
  # is what lets an already-audited task plan without a redundant audit-worker
  # cycle. The wider gate is proven only after the cited file is usable, and the
  # evidence is persisted after both checks, so a bad or wrong-phase citation
  # changes no state.
  if [ "$stage" = audit ]; then
    require_phase "$file" audit-consult "$task" || return 1
  elif [ -n "$findings_file" ]; then
    require_phase_any "$file" "$task" plan-consult audit-consult audit-worker || return 1
    resolved_findings=$(resolve_citation "$task" "$findings_file") || {
      write_field "$file" last_error "cited prior audit unusable: $findings_file" || return 1
      return 1
    }
    findings_text "$resolved_findings" >/dev/null || {
      write_field "$file" last_error "cited prior audit unusable: $findings_file" || return 1
      return 1
    }
  else
    require_phase "$file" plan-consult "$task" || return 1
  fi
  command -v jq >/dev/null 2>&1 || { printf 'fm-chatgpt-loop: consultation needs jq\n' >&2; return 1; }
  if [ -n "$findings_file" ]; then
    persist_findings "$file" "$resolved_findings" "$resolved_findings" || {
      write_field "$file" last_error "cited prior audit unusable: $findings_file" || return 1
      return 1
    }
  fi
  thread=$(read_field "$file" thread)
  local work prompt answer rc build_err
  work=$(mktemp -d) || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  prompt="$work/prompt.txt"
  if [ "$stage" = audit ]; then
    build_err=$(build_audit_prompt "$file" "$prompt" "$task" 2>&1) || {
      printf '%s\n' "$build_err" >&2
      write_field "$file" last_error "audit prompt construction failed: $build_err" || return 1
      return 1
    }
  else
    build_err=$(build_plan_prompt "$file" "$prompt" "$task" 2>&1) || {
      printf '%s\n' "$build_err" >&2
      write_field "$file" last_error "plan prompt construction failed: $build_err" || return 1
      return 1
    }
  fi
  if answer=$("$CONSULT_BIN" --prompt-file "$prompt" --mode "$stage" --thread "$thread" 2>"$work/stderr.txt"); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    write_field "$file" last_error "$(cat "$work/stderr.txt")"
    cat "$work/stderr.txt" >&2
    return "$rc"
  fi
  if [ "$stage" = audit ]; then
    local audit_text
    audit_text=$(printf '%s\n' "$answer" | strip_local_tools_banner)
    if [ -z "$(printf '%s' "$audit_text" | tr -d '[:space:]')" ]; then
      write_field "$file" last_error "audit consultation returned an empty prompt after banner stripping" || return 1
      printf 'fm-chatgpt-loop: audit consultation returned an empty prompt after banner stripping; phase unchanged at audit-consult\n' >&2
      return 1
    fi
    write_field "$file" audit_prompt "$audit_text" || return 1
    write_field "$file" audit_result "$audit_text" || return 1
    write_field "$file" phase audit-dispatch || return 1
  else
    write_field "$file" plan "$answer" || return 1
    write_field "$file" phase plan-dispatch || return 1
  fi
  write_field "$file" last_error "" || return 1
  if [ "$stage" = audit ]; then
    printf '%s\n' "$audit_text"
  else
    printf '%s\n' "$answer"
  fi
}

cmd_dispatch() {
  local stage="" task="" effort="" after_dash=0
  local -a spawn_args=()
  while [ $# -gt 0 ]; do
    if [ "$after_dash" = 1 ]; then
      spawn_args+=("$1"); shift
    else
      case "$1" in
        --stage) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; stage=$2; shift 2 ;;
        --task) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; task=$2; shift 2 ;;
        --effort) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; effort=$2; shift 2 ;;
        --) after_dash=1; shift ;;
        -h|--help) usage; return 0 ;;
        *) printf 'fm-chatgpt-loop: unknown dispatch argument %s\n' "$1" >&2; usage; return 2 ;;
      esac
    fi
  done
  case "$stage" in
    audit|plan) ;;
    *) printf 'fm-chatgpt-loop: dispatch needs --stage audit|plan\n' >&2; usage; return 2 ;;
  esac
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: dispatch needs --task\n' >&2; usage; return 2; }
  [ "${#spawn_args[@]}" -gt 0 ] || { printf 'fm-chatgpt-loop: dispatch needs spawn args after --\n' >&2; usage; return 2; }
  local file
  file=$(need_state "$task") || return 1
  if [ "$stage" = audit ]; then
    require_phase "$file" audit-dispatch "$task" || return 1
  else
    require_phase "$file" plan-dispatch "$task" || return 1
  fi
  # Worker boundary: no spawned argv element may reference the ChatGPT
  # bridge. Refuse before launching. Bridge-related ambient variables are
  # scrubbed from the spawn environment below rather than refused, so the
  # loop's own bridge configuration never reaches the worker.
  local bad='CHATGPT_WEB_BRIDGE_URL|fm-chatgpt|codex-chatgpt-web|17841'
  local a
  for a in "${spawn_args[@]}"; do
    if printf '%s' "$a" | grep -Eiq "$bad"; then
      printf 'fm-chatgpt-loop: refusing dispatch: spawn arg references the bridge: %s\n' "$a" >&2
      return 2
    fi
  done
  # The handoff target is the plain task id that must lead the args after
  # --. Refuse before launching rather than guessing among option values.
  local worker_task=${spawn_args[0]:-}
  if { [ "${worker_task#-}" = "$worker_task" ] && fm_task_id_creation_valid "$worker_task"; } then
    :
  else
    printf 'fm-chatgpt-loop: refusing dispatch: the first arg after -- must be a plain task id (got %s); nothing launched, no state changed\n' "$worker_task" >&2
    return 2
  fi
  # Effort has exactly one owner in the spawned argv. The passthrough spawn
  # args may already carry the spawn interface's own --effort; the dispatch
  # selection is used only when they do not, and supplying both at once is a
  # conflict refused before launch. This keeps one --effort in the argv, so the
  # loop's per-stage default of low and a caller's spawn-side effort never
  # reach fm-spawn as duplicate or disagreeing flags. Bridge lifecycle stays
  # Firstmate-owned: the worker environment never carries the bridge URL, and
  # nothing here starts, stops, or probes it.
  local spawn_effort_count=0 spawn_effort="" effective_effort i val
  for a in "${spawn_args[@]}"; do
    case "$a" in
      --effort|--effort=*) spawn_effort_count=$((spawn_effort_count + 1)) ;;
    esac
  done
  if [ "$spawn_effort_count" -gt 1 ]; then
    printf 'fm-chatgpt-loop: refusing dispatch: duplicate --effort in the spawn args; nothing launched, no state changed\n' >&2
    return 2
  fi
  if [ "$spawn_effort_count" = 1 ]; then
    for i in "${!spawn_args[@]}"; do
      case "${spawn_args[$i]}" in
        --effort)
          if [ $((i + 1)) -ge "${#spawn_args[@]}" ]; then
            printf 'fm-chatgpt-loop: refusing dispatch: empty --effort value in the spawn args; nothing launched, no state changed\n' >&2
            return 2
          fi
          val="${spawn_args[$((i + 1))]}"
          if [ -z "$val" ]; then
            printf 'fm-chatgpt-loop: refusing dispatch: empty --effort value in the spawn args; nothing launched, no state changed\n' >&2
            return 2
          fi
          case "$val" in
            -*) printf 'fm-chatgpt-loop: refusing dispatch: empty --effort value in the spawn args; nothing launched, no state changed\n' >&2; return 2 ;;
          esac
          spawn_effort=$val
          ;;
        --effort=*)
          spawn_effort=${spawn_args[$i]#--effort=}
          if [ -z "$spawn_effort" ]; then
            printf 'fm-chatgpt-loop: refusing dispatch: empty --effort value in the spawn args; nothing launched, no state changed\n' >&2
            return 2
          fi
          ;;
      esac
    done
  fi
  if [ "$spawn_effort_count" = 1 ] && [ -n "$effort" ]; then
    printf 'fm-chatgpt-loop: refusing dispatch: effort given both as dispatch --effort and in the spawn args; nothing launched, no state changed\n' >&2
    return 2
  fi
  if [ "$spawn_effort_count" = 1 ]; then
    effective_effort=$spawn_effort
  else
    [ -n "$effort" ] || effort=low
    spawn_args+=(--effort "$effort")
    effective_effort=$effort
  fi
  local stage_prompt rc send_err phase_next
  if [ "$stage" = audit ]; then
    stage_prompt=$(read_field "$file" audit_prompt)
    phase_next=audit-worker
  else
    stage_prompt=$(read_field "$file" plan)
    phase_next=plan-worker
  fi
  if env -u CHATGPT_WEB_BRIDGE_URL -u FM_CHATGPT_LOOP_SPAWN -u FM_CHATGPT_LOOP_CONSULT -u FM_CHATGPT_LOOP_SEND \
    FM_CHATGPT_LOOP_DISPATCH_TASK="$task" "$SPAWN" "${spawn_args[@]}"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    write_field "$file" last_error "worker $stage spawn failure: fm-spawn exited $rc" || return 1
    printf 'fm-chatgpt-loop: %s worker spawn failed for task %s (exit %s); phase unchanged at %s-dispatch\n' "$stage" "$task" "$rc" "$stage" >&2
    return "$rc"
  fi
  # The worker exists from here, so record its task id for the completion path
  # before the handoff; record-findings resolves this worker's report.
  write_field "$file" worker_task "$worker_task" || return 1
  # Handoff: deliver the stored stage prompt to the spawned worker through the
  # ordinary durable steering path, right after launch.
  if send_err=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SEND" "$worker_task" "$stage_prompt" 2>&1); then
    :
  else
    rc=$?
    write_field "$file" phase "$phase_next" || return 1
    write_field "$file" last_error "worker $stage prompt delivery failed: $send_err" || return 1
    printf 'fm-chatgpt-loop: spawned the %s worker for task %s, but the prompt handoff to %s failed: %s\n' "$stage" "$task" "$worker_task" "$send_err" >&2
    return "$rc"
  fi
  write_field "$file" phase "$phase_next" || return 1
  write_field "$file" last_error "" || return 1
  printf 'dispatched %s worker for task %s with --effort %s and delivered the %s prompt to %s\n' "$stage" "$task" "$effective_effort" "$stage" "$worker_task"
}

cmd_record_findings() {
  local task="" rfile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; task=$2; shift 2 ;;
      --file) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; rfile=$2; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-chatgpt-loop: unknown record-findings argument %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: record-findings needs --task\n' >&2; usage; return 2; }
  local file worker
  file=$(need_state "$task") || return 1
  require_phase "$file" audit-worker "$task" || return 1
  # Findings feedback is the audit completion step. Without --file the worker's
  # own report is the source, resolved from the task id dispatch recorded, so
  # the completion path never needs the caller to know a path.
  if [ -z "$rfile" ]; then
    worker=$(read_field "$file" worker_task)
    [ -n "$worker" ] || { printf 'fm-chatgpt-loop: record-findings needs --file: no dispatched worker is recorded to fall back on\n' >&2; return 2; }
    rfile="$DATA/$worker/report.md"
  fi
  # Findings and the phase advance land in one write: a failed record can never
  # leave the audit worker looking complete with findings still empty.
  persist_findings "$file" "$rfile" "$rfile" plan-consult || {
    write_field "$file" last_error "audit findings unusable: $rfile" || return 1
    return 1
  }
  printf 'recorded audit findings for task %s\n' "$task"
}

cmd_record_result() {
  local task="" rfile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; task=$2; shift 2 ;;
      --file) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; rfile=$2; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-chatgpt-loop: unknown record-result argument %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: record-result needs --task\n' >&2; usage; return 2; }
  [ -n "$rfile" ] && [ -f "$rfile" ] || { printf 'fm-chatgpt-loop: record-result needs an existing --file\n' >&2; usage; return 2; }
  local file
  file=$(need_state "$task") || return 1
  require_phase "$file" plan-worker "$task" || return 1
  write_field "$file" worker_result "$(cat "$rfile")" || return 1
  write_field "$file" phase complete || return 1
  printf 'recorded execution result for task %s: complete\n' "$task"
}

cmd_record_worker_failure() {
  local task="" stage="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; task=$2; shift 2 ;;
      --stage) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; stage=$2; shift 2 ;;
      --reason) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; reason=$2; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-chatgpt-loop: unknown record-worker-failure argument %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: record-worker-failure needs --task\n' >&2; usage; return 2; }
  case "$stage" in
    audit|plan) ;;
    *) printf 'fm-chatgpt-loop: record-worker-failure needs --stage audit|plan\n' >&2; usage; return 2 ;;
  esac
  [ -n "$reason" ] || { printf 'fm-chatgpt-loop: record-worker-failure needs --reason\n' >&2; usage; return 2; }
  local file want
  file=$(need_state "$task") || return 1
  want="$stage-worker"
  require_phase "$file" "$want" "$task" || return 1
  write_field "$file" last_error "worker $stage failure: $reason" || return 1
  write_field "$file" phase "$stage-dispatch" || return 1
  printf 'recorded %s worker failure for task %s; phase returned to %s-dispatch for retry\n' "$stage" "$task" "$stage" >&2
  return 1
}

cmd_next_round() {
  local task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; task=$2; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-chatgpt-loop: unknown next-round argument %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: next-round needs --task\n' >&2; usage; return 2; }
  local file iter tmp
  file=$(need_state "$task") || return 1
  require_phase "$file" complete "$task" || return 1
  iter=$(jq -r '.iteration // 1' "$file")
  tmp=$(mktemp) || return 1
  jq --argjson i "$((iter + 1))" --arg u "$(now_iso)" \
    '.iteration = $i | .phase = "audit-consult"
     | .audit_prompt = "" | .audit_result = "" | .findings = "" | .findings_source = ""
     | .worker_task = "" | .plan = "" | .worker_result = "" | .last_error = ""
     | .updated_at = $u' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
  printf 'task %s advanced to round %s\n' "$task" "$((iter + 1))"
}

cmd_status() {
  local task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) [ $# -ge 2 ] || { printf 'fm-chatgpt-loop: %s needs a value\n' "$1" >&2; usage; return 2; }; task=$2; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-chatgpt-loop: unknown status argument %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done
  [ -n "$task" ] || { printf 'fm-chatgpt-loop: status needs --task\n' >&2; usage; return 2; }
  local file
  file=$(need_state "$task") || return 1
  jq '.' "$file"
}

bridge_probe() {
  local url
  url=$(fm_chatgpt_bridge_url) || return 1
  curl -s -m 5 -o /dev/null "$url" 2>/dev/null
}

cmd_bridge_status() {
  if bridge_probe; then
    printf 'bridge up\n'
    return 0
  fi
  printf 'fm-chatgpt-loop: bridge unreachable; start the codex-chatgpt-web bridge before consulting\n' >&2
  return 1
}

bridge_daemon_dir() {
  printf '%s/tools/codex-chatgpt-web\n' "$HOME"
}

# True only for a live pid whose command line is this loop's serve
# entrypoint under the resolved daemon dir: a reused pid must neither block
# start nor be killed by stop, and a foreign tool that merely mentions
# codex-chatgpt-web or src/cli.ts anywhere is never this loop's instance.
bridge_pid_is_loop_instance() {
  local pid=$1 cmd dir
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
  dir=$(bridge_daemon_dir)
  case "$cmd" in
    *"$dir/bin/codex-chatgpt-web"*|*"$dir/src/cli.ts"*) return 0 ;;
  esac
  return 1
}

cmd_bridge_start() {
  [ $# -eq 0 ] || { printf 'fm-chatgpt-loop: bridge start takes no arguments; installation and authentication stay external\n' >&2; return 2; }
  if [ -f "$BRIDGE_PID_FILE" ]; then
    local old
    old=$(cat "$BRIDGE_PID_FILE" 2>/dev/null)
    if bridge_pid_is_loop_instance "$old"; then
      printf 'fm-chatgpt-loop: bridge already started by this loop (pid %s)\n' "$old" >&2
      return 1
    fi
    rm -f "$BRIDGE_PID_FILE"
  fi
  if bridge_probe; then
    printf 'fm-chatgpt-loop: a bridge is already reachable; start refuses to take ownership of a foreign instance (stop only stops what start started)\n' >&2
    return 1
  fi
  local dir cli
  dir=$(bridge_daemon_dir)
  [ -d "$dir" ] || { printf 'fm-chatgpt-loop: bridge daemon not found at %s; install it externally first\n' "$dir" >&2; return 1; }
  if [ -x "$dir/bin/codex-chatgpt-web" ]; then
    cli="$dir/bin/codex-chatgpt-web"
  elif [ -f "$dir/src/cli.ts" ] && command -v bun >/dev/null 2>&1; then
    cli="bun run $dir/src/cli.ts"
  else
    printf 'fm-chatgpt-loop: cannot resolve the bridge serve entrypoint under %s\n' "$dir" >&2
    return 1
  fi
  # Visible browser by default: never force headless operation here.
  mkdir -p "$STATE" || return 1
  # shellcheck disable=SC2086
  nohup $cli serve >"$STATE/chatgpt-loop-bridge.log" 2>&1 &
  printf '%s\n' "$!" > "$BRIDGE_PID_FILE"
  printf 'bridge starting (pid %s, log %s/chatgpt-loop-bridge.log)\n' "$!" "$STATE"
}

cmd_bridge_stop() {
  [ $# -eq 0 ] || { printf 'fm-chatgpt-loop: bridge stop takes no arguments; never killing a foreign process\n' >&2; return 2; }
  [ -f "$BRIDGE_PID_FILE" ] || { printf 'fm-chatgpt-loop: no loop-owned bridge instance to stop; never killing a foreign process\n' >&2; return 1; }
  local pid
  pid=$(cat "$BRIDGE_PID_FILE" 2>/dev/null)
  [ -n "$pid" ] || { printf 'fm-chatgpt-loop: no loop-owned bridge instance to stop\n' >&2; rm -f "$BRIDGE_PID_FILE"; return 1; }
  if kill -0 "$pid" 2>/dev/null; then
    if ! bridge_pid_is_loop_instance "$pid"; then
      printf 'fm-chatgpt-loop: recorded bridge pid %s is not a loop-owned bridge instance; never killing a foreign process\n' "$pid" >&2
      rm -f "$BRIDGE_PID_FILE"
      return 1
    fi
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      printf 'fm-chatgpt-loop: bridge instance %s did not exit after TERM; keeping the pidfile for a retry\n' "$pid" >&2
      return 1
    fi
    printf 'bridge instance %s stopped\n' "$pid"
  else
    printf 'bridge instance %s already exited\n' "$pid"
  fi
  rm -f "$BRIDGE_PID_FILE"
}

cmd_bridge() {
  local verb=${1:-}
  shift || true
  case "$verb" in
    status) cmd_bridge_status "$@" ;;
    start) cmd_bridge_start "$@" ;;
    stop) cmd_bridge_stop "$@" ;;
    install|setup|login|uninstall)
      printf 'fm-chatgpt-loop: bridge %s is refused; installation and authentication stay external\n' "$verb" >&2
      return 2
      ;;
    -h|--help|'') usage; [ -n "$verb" ] || return 2 ;;
    *) printf 'fm-chatgpt-loop: unknown bridge verb %s\n' "$verb" >&2; usage; return 2 ;;
  esac
}

sub=${1:-}
shift || true
case "$sub" in
  init) cmd_init "$@" ;;
  consult) cmd_consult "$@" ;;
  dispatch) cmd_dispatch "$@" ;;
  record-findings) cmd_record_findings "$@" ;;
  record-result) cmd_record_result "$@" ;;
  record-worker-failure) cmd_record_worker_failure "$@" ;;
  next-round) cmd_next_round "$@" ;;
  status) cmd_status "$@" ;;
  bridge) cmd_bridge "$@" ;;
  -h|--help|'') usage; [ -n "$sub" ] || exit 2 ;;
  *) printf 'fm-chatgpt-loop: unknown subcommand %s\n' "$sub" >&2; usage; exit 2 ;;
esac
