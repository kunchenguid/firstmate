#!/usr/bin/env bash
# shellcheck disable=SC2034 # Public FM_WORKGRAPH_* outputs are consumed by sourcing lifecycle scripts.
# WorkGraph dispatch binding for fm-spawn.sh.
#
# This file is sourced after fm-lock-lib.sh. It validates the exact graph,
# contract snapshot, registry, declared worktree and active metadata before a
# launch. It holds one short dispatch lock until fm-spawn publishes metadata.
# Existing tasks without a complete WorkGraph binding are deliberately treated
# as broadly exclusive.

FM_WORKGRAPH_ENABLED=0
FM_WORKGRAPH_GRAPH=
FM_WORKGRAPH_REGISTRY=
FM_WORKGRAPH_GOAL=
FM_WORKGRAPH_SLICE=
FM_WORKGRAPH_TYPE=
FM_WORKGRAPH_WORKTREE=
FM_WORKGRAPH_HARNESS=
FM_WORKGRAPH_MODEL=
FM_WORKGRAPH_EFFORT=
FM_WORKGRAPH_WAVE=
FM_WORKGRAPH_GRAPH_SHA256=
FM_WORKGRAPH_CONTRACT_SHA256=
FM_WORKGRAPH_REGISTRY_SHA256=
FM_WORKGRAPH_LEASE_ID=
FM_WORKGRAPH_FENCING_TOKEN=
FM_WORKGRAPH_LEASE_HELD=0
FM_WORKGRAPH_HOLDER_PID=
FM_WORKGRAPH_HOLDER_START_TICKS=
FM_WORKGRAPH_HOLDER_STARTED=0
FM_WORKGRAPH_HOLDER_OWNED=0
FM_WORKGRAPH_DISPATCH_LOCK=
FM_WORKGRAPH_DISPATCH_LOCK_HELD=0

fm_workgraph_dispatch_error() {
  printf 'error: WorkGraph dispatch: %s\n' "$*" >&2
  return 1
}

fm_workgraph_meta_exact() { # <meta> <key>
  local meta=$1 key=$2 count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$meta" | cut -d= -f2-
}

fm_workgraph_load_contract() { # <task-id> <kind> <graph> <slice> <registry>
  local id=$1 kind=$2 graph=$3 slice=$4 registry=$5 snapshot selected
  local fields
  if [ -z "$graph$slice$registry" ]; then
    FM_WORKGRAPH_ENABLED=0
    return 0
  fi
  [ -n "$graph" ] && [ -n "$slice" ] && [ -n "$registry" ] \
    || fm_workgraph_dispatch_error "--workgraph, --slice and --registry must be supplied together"
  [ "$id" = "$slice" ] \
    || fm_workgraph_dispatch_error "task id must equal the WorkGraph slice id"
  [ "$kind" != secondmate ] \
    || fm_workgraph_dispatch_error "secondmate launches cannot consume slice contracts"

  FM_WORKGRAPH_GRAPH=$(cd "$(dirname "$graph")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$graph")") \
    || fm_workgraph_dispatch_error "cannot resolve graph $graph"
  FM_WORKGRAPH_REGISTRY=$(cd "$(dirname "$registry")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$registry")") \
    || fm_workgraph_dispatch_error "cannot resolve registry $registry"
  "$FM_ROOT/bin/fm-workgraph.sh" registry "$FM_WORKGRAPH_REGISTRY" >/dev/null \
    || fm_workgraph_dispatch_error "registry validation failed"

  snapshot="$DATA/$id/slice-contract.json"
  [ -f "$snapshot" ] && [ ! -L "$snapshot" ] \
    || fm_workgraph_dispatch_error "missing sealed brief contract snapshot $snapshot"
  selected=$(mktemp "${TMPDIR:-/tmp}/fm-workgraph-dispatch-contract.XXXXXX") \
    || fm_workgraph_dispatch_error "cannot create a private contract capture"
  if ! "$FM_ROOT/bin/fm-workgraph.sh" contract "$FM_WORKGRAPH_GRAPH" "$slice" >"$selected"; then
    rm -f "$selected"
    fm_workgraph_dispatch_error "graph or contract validation failed"
    return 1
  fi
  if ! cmp -s "$selected" "$snapshot"; then
    rm -f "$selected"
    fm_workgraph_dispatch_error "brief contract snapshot differs from the sealed graph bytes"
    return 1
  fi
  fields=$(node - "$selected" <<'NODE'
const fs = require("node:fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const safe = (name, text, pattern) => {
  if (typeof text !== "string" || !pattern.test(text)) {
    process.stderr.write(`unsafe ${name}\n`);
    process.exit(1);
  }
  return text;
};
const rows = [
  safe("goal_id", value.goal_id, /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/),
  safe("slice_id", value.slice_id, /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/),
  safe("type", value.type, /^(ship|scout|audit|integration)$/),
  safe("worktree", value.worktree, /^\/[^\u0000-\u001f\u007f]*$/),
  safe("harness", value.harness, /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/),
  safe("model", value.model, /^[A-Za-z0-9][A-Za-z0-9._\/-]{0,127}$/),
  // `default` is the explicit no-separate-axis value for harnesses such as
  // MiniMax.  It records the absence faithfully and never becomes a CLI flag.
  safe("effort", value.effort, /^(default|low|medium|high|xhigh|max)$/),
];
process.stdout.write(rows.join("\t"));
NODE
  ) || {
    rm -f "$selected"
    fm_workgraph_dispatch_error "contract contains dispatch-unsafe identity fields"
    return 1
  }
  if ! node - "$selected" "$(dirname "$FM_WORKGRAPH_GRAPH")" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const contract = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const graphDirectory = process.argv[3];
for (const input of contract.immutable_inputs) {
  const filename = path.isAbsolute(input.path) ? input.path : path.resolve(graphDirectory, input.path);
  let descriptor;
  try {
    const before = fs.lstatSync(filename, {bigint: true});
    if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1n) process.exit(1);
    descriptor = fs.openSync(filename, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
    const opened = fs.fstatSync(descriptor, {bigint: true});
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor, {bigint: true});
    if (opened.dev !== before.dev || opened.ino !== before.ino
        || after.dev !== opened.dev || after.ino !== opened.ino
        || crypto.createHash("sha256").update(bytes).digest("hex") !== input.sha256) {
      process.exit(1);
    }
  } catch {
    process.exit(1);
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}
NODE
  then
    rm -f "$selected"
    fm_workgraph_dispatch_error "immutable input is missing, unsafe, or has the wrong SHA-256"
    return 1
  fi
  IFS=$'\t' read -r FM_WORKGRAPH_GOAL FM_WORKGRAPH_SLICE FM_WORKGRAPH_TYPE \
    FM_WORKGRAPH_WORKTREE FM_WORKGRAPH_HARNESS FM_WORKGRAPH_MODEL FM_WORKGRAPH_EFFORT <<EOF
$fields
EOF
  FM_WORKGRAPH_GRAPH_SHA256=$(sha256sum "$FM_WORKGRAPH_GRAPH" | awk '{print $1}')
  FM_WORKGRAPH_CONTRACT_SHA256=$(sha256sum "$selected" | awk '{print $1}')
  FM_WORKGRAPH_REGISTRY_SHA256=$(sha256sum "$FM_WORKGRAPH_REGISTRY" | awk '{print $1}')
  rm -f "$selected"

  case "$FM_WORKGRAPH_TYPE:$kind" in
    ship:ship|integration:ship|scout:scout|audit:scout) ;;
    *) fm_workgraph_dispatch_error "contract type $FM_WORKGRAPH_TYPE is incompatible with spawn kind $kind"; return 1 ;;
  esac
  FM_WORKGRAPH_ENABLED=1
}

fm_workgraph_git_common_dir() { # <worktree>
  local root=$1 common
  common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) cd "$common" 2>/dev/null && pwd -P ;;
    *) cd "$root/$common" 2>/dev/null && pwd -P ;;
  esac
}

fm_workgraph_validate_worktree() { # <project>
  local project=$1 declared top project_common worktree_common
  declared=$(cd "$FM_WORKGRAPH_WORKTREE" 2>/dev/null && pwd -P) \
    || fm_workgraph_dispatch_error "declared worktree does not exist"
  top=$(git -C "$declared" rev-parse --show-toplevel 2>/dev/null) \
    || fm_workgraph_dispatch_error "declared worktree is not a Git worktree"
  top=$(cd "$top" 2>/dev/null && pwd -P) \
    || fm_workgraph_dispatch_error "declared worktree cannot be canonicalized"
  [ "$declared" = "$top" ] \
    || fm_workgraph_dispatch_error "declared worktree must be its Git top level"
  project_common=$(fm_workgraph_git_common_dir "$project") \
    || fm_workgraph_dispatch_error "project Git common directory is unavailable"
  worktree_common=$(fm_workgraph_git_common_dir "$declared") \
    || fm_workgraph_dispatch_error "worktree Git common directory is unavailable"
  [ "$project_common" = "$worktree_common" ] \
    || fm_workgraph_dispatch_error "declared worktree does not belong to the selected project"
  [ "$declared" != "$(cd "$project" && pwd -P)" ] \
    || fm_workgraph_dispatch_error "declared worktree is the primary project checkout"
  FM_WORKGRAPH_WORKTREE=$declared
}

fm_workgraph_process_start_ticks() { # <pid>
  local pid=$1 stat rest
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -r "/proc/$pid/stat" ] || return 1
  IFS= read -r stat <"/proc/$pid/stat" || return 1
  rest=${stat##*) }
  # shellcheck disable=SC2086 # /proc stat fields are intentionally tokenized after the final ") ".
  set -- $rest
  [ "$#" -ge 20 ] || return 1
  case "${20}" in ''|*[!0-9]*|0) return 1 ;; esac
  printf '%s\n' "${20}"
}

fm_workgraph_holder_start() {
  [ "$FM_WORKGRAPH_ENABLED" = 1 ] || return 0
  [ "$FM_WORKGRAPH_HOLDER_STARTED" = 0 ] || return 0
  # The launcher itself is the provisional holder. A detached child is not a
  # durable identity: process supervisors may reap it when fm-spawn returns.
  # Before metadata publication, fm-spawn replaces this provisional lease with
  # one bound to the persistent session-provider pane shell.
  FM_WORKGRAPH_HOLDER_PID=$$
  FM_WORKGRAPH_HOLDER_START_TICKS=$(fm_workgraph_process_start_ticks "$FM_WORKGRAPH_HOLDER_PID") \
    || {
      FM_WORKGRAPH_HOLDER_PID=
      return 1
    }
  FM_WORKGRAPH_HOLDER_STARTED=1
  FM_WORKGRAPH_HOLDER_OWNED=0
}

fm_workgraph_holder_stop_exact() { # <pid> <start-ticks>
  local pid=$1 expected=$2 actual i
  actual=$(fm_workgraph_process_start_ticks "$pid") || return 0
  [ "$actual" = "$expected" ] || {
    echo "error: WorkGraph holder PID identity changed; refusing to signal $pid" >&2
    return 1
  }
  kill "$pid" >/dev/null 2>&1 || return 1
  i=0
  while [ "$i" -lt 40 ]; do
    fm_workgraph_process_start_ticks "$pid" >/dev/null 2>&1 || return 0
    sleep 0.05
    i=$((i + 1))
  done
  echo "error: WorkGraph holder process $pid did not terminate" >&2
  return 1
}

fm_workgraph_holder_stop_current() {
  [ "$FM_WORKGRAPH_HOLDER_STARTED" = 1 ] || return 0
  if [ "$FM_WORKGRAPH_HOLDER_OWNED" = 1 ]; then
    fm_workgraph_holder_stop_exact \
      "$FM_WORKGRAPH_HOLDER_PID" "$FM_WORKGRAPH_HOLDER_START_TICKS" || return 1
    wait "$FM_WORKGRAPH_HOLDER_PID" >/dev/null 2>&1 || true
  fi
  FM_WORKGRAPH_HOLDER_STARTED=0
  FM_WORKGRAPH_HOLDER_OWNED=0
  FM_WORKGRAPH_HOLDER_PID=
  FM_WORKGRAPH_HOLDER_START_TICKS=
}

fm_workgraph_acquire_bound_lease() {
  local acquire_result
  acquire_result=$("$FM_ROOT/bin/fm-workgraph.sh" acquire \
    "$FM_WORKGRAPH_GRAPH" "$FM_WORKGRAPH_SLICE" \
    --registry "$FM_WORKGRAPH_REGISTRY" \
    --lease-id "$FM_WORKGRAPH_LEASE_ID" \
    --holder-id "$FM_WORKGRAPH_SLICE" \
    --holder-pid "$FM_WORKGRAPH_HOLDER_PID") \
    || return 1
  FM_WORKGRAPH_FENCING_TOKEN=$(node -e '
    const value = JSON.parse(process.argv[1]);
    if (value.state !== "held" || !/^[1-9][0-9]*$/.test(value.holder_fencing_token)) process.exit(1);
    process.stdout.write(value.holder_fencing_token);
  ' "$acquire_result") || return 1
  FM_WORKGRAPH_LEASE_HELD=1
}

fm_workgraph_handoff_to_endpoint() { # <persistent endpoint shell pid>
  local endpoint_pid=$1 endpoint_start
  [ "$FM_WORKGRAPH_ENABLED" = 1 ] || return 0
  [ "$FM_WORKGRAPH_DISPATCH_LOCK_HELD" = 1 ] \
    || { fm_workgraph_dispatch_error "endpoint handoff requires the dispatch lock"; return 1; }
  [ "$FM_WORKGRAPH_LEASE_HELD" = 1 ] \
    || { fm_workgraph_dispatch_error "endpoint handoff requires a provisional lease"; return 1; }
  endpoint_start=$(fm_workgraph_process_start_ticks "$endpoint_pid") \
    || { fm_workgraph_dispatch_error "endpoint holder process is unavailable"; return 1; }

  "$FM_ROOT/bin/fm-workgraph.sh" release "$FM_WORKGRAPH_GOAL" \
    --lease-id "$FM_WORKGRAPH_LEASE_ID" \
    --holder-id "$FM_WORKGRAPH_SLICE" \
    --fencing-token "$FM_WORKGRAPH_FENCING_TOKEN" >/dev/null \
    || { fm_workgraph_dispatch_error "provisional lease release failed"; return 1; }
  FM_WORKGRAPH_LEASE_HELD=0

  FM_WORKGRAPH_LEASE_ID=$FM_WORKGRAPH_SLICE
  FM_WORKGRAPH_HOLDER_PID=$endpoint_pid
  FM_WORKGRAPH_HOLDER_START_TICKS=$endpoint_start
  FM_WORKGRAPH_HOLDER_STARTED=1
  FM_WORKGRAPH_HOLDER_OWNED=0
  fm_workgraph_acquire_bound_lease \
    || { fm_workgraph_dispatch_error "endpoint lease acquisition failed"; return 1; }
}

fm_workgraph_active_lease_valid() { # <meta>
  local meta=$1 goal lease token task record holder_pid holder_start current_start
  goal=$(fm_workgraph_meta_exact "$meta" workgraph_goal) || return 1
  lease=$(fm_workgraph_meta_exact "$meta" workgraph_lease_id) || return 1
  token=$(fm_workgraph_meta_exact "$meta" workgraph_fencing_token) || return 1
  holder_pid=$(fm_workgraph_meta_exact "$meta" workgraph_holder_pid) || return 1
  holder_start=$(fm_workgraph_meta_exact "$meta" workgraph_holder_start_ticks) || return 1
  current_start=$(fm_workgraph_process_start_ticks "$holder_pid") || return 1
  [ "$current_start" = "$holder_start" ] || return 1
  task=$(basename "$meta" .meta)
  record=$("$FM_ROOT/bin/fm-workgraph.sh" inspect "$goal" --lease-id "$lease" 2>/dev/null) || return 1
  node - "$task" "$lease" "$token" "$holder_pid" "$holder_start" "$record" <<'NODE'
const [task, lease, token, holderPid, holderStart, raw] = process.argv.slice(2);
let value;
try { value = JSON.parse(raw); } catch { process.exit(1); }
if (value.state !== "held" || value.lease_id !== lease || value.holder_id !== task
    || value.holder_fencing_token !== token || value.current_fencing_token !== token
    || value.holder_process.pid !== holderPid
    || value.holder_process.start_ticks !== holderStart) {
  process.exit(1);
}
NODE
}

fm_workgraph_bound_file_valid() { # <meta> <path-key> <sha256-key>
  local meta=$1 path_key=$2 digest_key=$3 file expected observed
  file=$(fm_workgraph_meta_exact "$meta" "$path_key") || return 1
  expected=$(fm_workgraph_meta_exact "$meta" "$digest_key") || return 1
  case "$expected" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#expected}" = 64 ] || return 1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  observed=$(sha256sum "$file" 2>/dev/null | awk '{print $1}') || return 1
  [ "$observed" = "$expected" ]
}

fm_workgraph_active_contract_compatible() { # <meta>
  local meta=$1 graph goal slice contract_digest registry result observed_contract
  fm_workgraph_bound_file_valid "$meta" workgraph_graph workgraph_graph_sha256 \
    || return 1
  fm_workgraph_bound_file_valid "$meta" workgraph_registry workgraph_registry_sha256 \
    || return 1
  graph=$(fm_workgraph_meta_exact "$meta" workgraph_graph) || return 1
  goal=$(fm_workgraph_meta_exact "$meta" workgraph_goal) || return 1
  slice=$(fm_workgraph_meta_exact "$meta" workgraph_slice) || return 1
  contract_digest=$(fm_workgraph_meta_exact "$meta" workgraph_contract_sha256) || return 1
  registry=$(fm_workgraph_meta_exact "$meta" workgraph_registry) || return 1
  result=$("$FM_ROOT/bin/fm-workgraph.sh" __dispatch-conflict \
    "$FM_WORKGRAPH_GRAPH" "$FM_WORKGRAPH_SLICE" "$FM_WORKGRAPH_REGISTRY" \
    "$graph" "$slice" "$registry" 2>/dev/null) || return 1
  [ "$(printf '%s\n' "$result" | grep -c "^goal_b=$goal$")" = 1 ] || return 1
  [ "$(printf '%s\n' "$result" | grep -c "^slice_b=$slice$")" = 1 ] || return 1
  observed_contract=$(printf '%s\n' "$result" | sed -n 's/^contract_sha256_b=//p')
  [ "$observed_contract" = "$contract_digest" ] || return 1
  [ "$(printf '%s\n' "$result" | grep -c '^compatible=true$')" = 1 ]
}

fm_workgraph_dispatch_lock() {
  mkdir -p "$STATE"
  FM_WORKGRAPH_DISPATCH_LOCK="$STATE/.workgraph-dispatch.lock"
  fm_lock_try_acquire "$FM_WORKGRAPH_DISPATCH_LOCK" \
    || fm_workgraph_dispatch_error "another dispatch is currently deciding compatibility"
  FM_WORKGRAPH_DISPATCH_LOCK_HELD=1
}

fm_workgraph_dispatch_unlock() {
  [ "$FM_WORKGRAPH_DISPATCH_LOCK_HELD" = 1 ] || return 0
  FM_WORKGRAPH_DISPATCH_LOCK_HELD=0
  fm_lock_release "$FM_WORKGRAPH_DISPATCH_LOCK"
}

fm_workgraph_enforce_dispatch() { # <task-id> <project>
  local id=$1 project=$2 meta other_worktree active_count=0 mode capacity waves provisional_seed
  fm_workgraph_dispatch_lock || return 1
  if [ "$FM_WORKGRAPH_ENABLED" = 1 ]; then
    fm_workgraph_validate_worktree "$project" || return 1
    "$FM_ROOT/bin/fm-workgraph.sh" gate-check \
      "$FM_WORKGRAPH_GRAPH" "$FM_WORKGRAPH_SLICE" >/dev/null \
      || { fm_workgraph_dispatch_error "dependencies or prior completion block the selected slice"; return 1; }
  fi

  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ "$(basename "$meta" .meta)" != "$id" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] \
      || { fm_workgraph_dispatch_error "active metadata is not a regular file: $meta"; return 1; }
    active_count=$((active_count + 1))
    if [ "$FM_WORKGRAPH_ENABLED" != 1 ]; then
      fm_workgraph_dispatch_error "legacy task $id is exclusive while active task metadata exists"
      return 1
    fi
    fm_workgraph_active_lease_valid "$meta" \
      || { fm_workgraph_dispatch_error "active task $(basename "$meta" .meta) is legacy, ambiguous, or lacks a valid held lease"; return 1; }
    fm_workgraph_active_contract_compatible "$meta" \
      || { fm_workgraph_dispatch_error "sealed contract conflicts with active task $(basename "$meta" .meta)"; return 1; }
    other_worktree=$(fm_workgraph_meta_exact "$meta" worktree) \
      || { fm_workgraph_dispatch_error "active task metadata lacks one worktree"; return 1; }
    [ "$other_worktree" != "$FM_WORKGRAPH_WORKTREE" ] \
      || { fm_workgraph_dispatch_error "declared worktree is already owned by $(basename "$meta" .meta)"; return 1; }
  done

  [ "$FM_WORKGRAPH_ENABLED" = 1 ] || return 0
  mode=$("$FM_ROOT/bin/fm-parallelism.sh" get --goal "$FM_WORKGRAPH_GOAL") \
    || { fm_workgraph_dispatch_error "parallelism mode cannot be resolved"; return 1; }
  case "$mode" in
    off) capacity=1 ;;
    eco) capacity=2 ;;
    on|max) capacity=999999 ;;
    *) fm_workgraph_dispatch_error "parallelism mode is invalid"; return 1 ;;
  esac
  [ "$active_count" -lt "$capacity" ] \
    || { fm_workgraph_dispatch_error "parallelism mode $mode has reached capacity $capacity"; return 1; }
  waves=$("$FM_ROOT/bin/fm-workgraph.sh" waves "$FM_WORKGRAPH_GRAPH" \
    --registry "$FM_WORKGRAPH_REGISTRY" --mode "$mode") \
    || { fm_workgraph_dispatch_error "static wave calculation failed"; return 1; }
  FM_WORKGRAPH_WAVE=$(node - "$FM_WORKGRAPH_SLICE" "$waves" <<'NODE'
const slice = process.argv[2];
const lines = process.argv[3].split("\n");
for (const line of lines) {
  const match = /^wave\[([0-9]+)\]\.slice\[[0-9]+\]=(.*)$/.exec(line);
  if (match && match[2] === slice) {
    process.stdout.write(match[1]);
    process.exit(0);
  }
}
process.exit(1);
NODE
  ) || { fm_workgraph_dispatch_error "selected slice is absent from the static wave plan"; return 1; }

  [ "$FM_WORKGRAPH_HOLDER_STARTED" = 1 ] \
    || { fm_workgraph_dispatch_error "lease holder guardian was not started"; return 1; }
  provisional_seed=$(printf '%s\0%s\0%s\0' \
    "$id" "$FM_WORKGRAPH_HOLDER_PID" "$FM_WORKGRAPH_HOLDER_START_TICKS" \
    | sha256sum | awk '{print substr($1, 1, 40)}')
  FM_WORKGRAPH_LEASE_ID="dispatch-$provisional_seed"
  fm_workgraph_acquire_bound_lease \
    || { fm_workgraph_dispatch_error "resource claims conflict with an active lease"; return 1; }
}

fm_workgraph_abort_release() {
  if [ "$FM_WORKGRAPH_LEASE_HELD" = 1 ]; then
    "$FM_ROOT/bin/fm-workgraph.sh" release "$FM_WORKGRAPH_GOAL" \
      --lease-id "$FM_WORKGRAPH_LEASE_ID" \
      --holder-id "$FM_WORKGRAPH_SLICE" \
      --fencing-token "$FM_WORKGRAPH_FENCING_TOKEN" >/dev/null 2>&1 || true
    FM_WORKGRAPH_LEASE_HELD=0
  fi
  fm_workgraph_holder_stop_current || true
}
