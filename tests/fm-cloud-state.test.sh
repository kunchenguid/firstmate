#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-cloud-state-lib.sh
. "$ROOT/bin/fm-cloud-state-lib.sh"

run_cloud_credential_is_removed() {
  # The provider account credential a cloud spawn copies into the control home
  # must not outlive the task. docs/azure-workers.md states it never enters the
  # control home at all, and before this owner existed every completed cloud
  # crewmate left a plaintext auth.json there indefinitely.
  local tmp state id
  fm_test_tmproot_into tmp fm-cloud-state
  state="$tmp/state"
  id=cloud-task-1
  mkdir -p "$state/$id.cloud-account" "$state/$id.cloud-payload"
  printf '{"refresh":"secret"}\n' > "$state/$id.cloud-account/auth.json"
  printf '{}\n' > "$state/$id.cloud-account/settings.json"
  printf 'bundle\n' > "$state/$id.cloud-payload/repo.bundle"
  printf 'brief\n' > "$state/$id.cloud-payload/brief.md"
  printf 'entry\n' > "$state/$id.cloud-entrypoint"
  printf 'env\n' > "$state/$id.cloud-env"
  : > "$state/$id.cloud-execute-dispatched"
  printf 'request\n' > "$state/$id.worker-request.out"
  printf '{}\n' > "$state/$id.worker-result.json"
  printf 'log\n' > "$state/$id.worker-execute.log"
  printf '{}\n' > "$state/$id.worker-reconcile.json"

  fm_cloud_state_remove "$state" "$id"

  assert_absent "$state/$id.cloud-account/auth.json" \
    "the provider account credential outlived the task in the control home"
  assert_absent "$state/$id.cloud-account" "the account staging directory survived"
  assert_absent "$state/$id.cloud-payload" "the payload staging directory survived"
  assert_absent "$state/$id.cloud-entrypoint" "the persisted entrypoint survived"
  assert_absent "$state/$id.cloud-env" "the persisted environment survived"
  assert_absent "$state/$id.cloud-execute-dispatched" "the dispatch marker survived"
  assert_absent "$state/$id.worker-result.json" "the worker result survived"
  assert_absent "$state/$id.worker-execute.log" "the execute log survived"
  pass "teardown removes the cloud account credential and its transport state"
}

run_teardown_actually_calls_the_owner() {
  # Driving the library proves the function works and NOT that anything calls
  # it. The first version of this check counted a literal string, so it stayed
  # green when a call was neutered to a no-op, and it hardcoded the terminal
  # count so it could never notice a THIRD success path that had no call at
  # all. It now enumerates every successful terminal in the script and
  # requires a real call statement before each one.
  local script
  script="$ROOT/bin/fm-teardown.sh"
  assert_grep 'fm-cloud-state-lib.sh' "$script" "teardown no longer sources the cloud state owner"
  python3 - "$script" <<'TERMINALS' || fail "a successful teardown terminal does not remove the cloud credential"
import re
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
call = re.compile(r"^\s*fm_cloud_state_remove\s+\"\$STATE\"\s+\"\$ID\"\s*$")

terminals = [i for i, line in enumerate(lines) if re.match(r"^\s*exit 0\s*$", line)]
terminals.append(len(lines) - 1)
assert len(terminals) >= 3, ("expected at least three successful terminals", terminals)

uncovered = []
for index in terminals:
    window_start = 0
    for other in terminals:
        if other < index:
            window_start = max(window_start, other)
    if not any(call.match(lines[i]) for i in range(window_start, index + 1)):
        uncovered.append(index + 1)

assert not uncovered, (
    "these successful teardown terminals never remove the cloud credential (1-indexed lines)",
    uncovered,
)
TERMINALS
  pass "every successful teardown terminal removes the cloud credential"
}

run_cloud_state_survives_set_e() {
  # Teardown runs under `set -e` and removes the task metadata AFTER this. A
  # bare failing rm aborted it there, leaving a half-torn-down task and the
  # credential still present. The harness only sets `set -u`, so this drives
  # the function under production shell options explicitly.
  local tmp state id out status
  fm_test_tmproot_into tmp fm-cloud-state-set-e
  state="$tmp/state"
  id=cloud-task-3
  mkdir -p "$state/$id.cloud-account"
  printf '{"refresh":"secret"}\n' > "$state/$id.cloud-account/auth.json"
  chmod 0500 "$state/$id.cloud-account"
  out=$(set -e; . "$ROOT/bin/fm-cloud-state-lib.sh"; fm_cloud_state_remove "$state" "$id" 2>&1; echo REACHED)
  status=$?
  chmod 0700 "$state/$id.cloud-account"
  expect_code 0 "$status" "an unremovable credential aborted the caller under set -e"
  assert_contains "$out" "REACHED" "the caller never reached its remaining cleanup"
  assert_contains "$out" "could not remove its staged provider credential" \
    "a credential that could not be removed was not reported"
  pass "a failed credential removal never aborts a caller running under set -e"
}

run_cloud_credential_survives_a_symlinked_directory() {
  # rm -rf on a symlinked cloud-account unlinks the symlink and spares the
  # target, so the by-name removal is what actually guarantees the credential
  # goes. Without it this case leaves the file behind.
  local tmp state id real
  fm_test_tmproot_into tmp fm-cloud-state-symlink
  state="$tmp/state"
  id=cloud-task-4
  real="$tmp/elsewhere"
  mkdir -p "$state" "$real"
  printf '{"refresh":"secret"}\n' > "$real/auth.json"
  ln -s "$real" "$state/$id.cloud-account"

  fm_cloud_state_remove "$state" "$id"

  assert_absent "$real/auth.json" \
    "a symlinked account directory left the credential on disk"
  pass "a symlinked account directory still loses its credential"
}

seed_compartment_child_staging() {  # <compartment home> <task id>
  # The exact shape bin/fm-spawn.sh leaves behind for a compartment child: the
  # whole per-task cloud state in the COMPARTMENT's own state directory.
  local home=$1 id=$2
  mkdir -p "$home/state/$id.cloud-account" "$home/state/$id.cloud-payload"
  printf 'smc-1\n' > "$home/.fm-secondmate-home"
  printf '{"refresh":"secret"}\n' > "$home/state/$id.cloud-account/auth.json"
  printf '{}\n' > "$home/state/$id.cloud-account/settings.json"
  printf 'bundle\n' > "$home/state/$id.cloud-payload/repo.bundle"
  printf 'entry\n' > "$home/state/$id.cloud-entrypoint"
  printf 'path\n' > "$home/state/$id.cloud-worktree"
  printf 'request\n' > "$home/state/$id.worker-request.out"
  printf '{}\n' > "$home/state/$id.worker-result.json"
}

run_compartment_child_credential_is_removed_from_its_task_home() {
  # THE DEFECT. A compartment child's credential is staged in the SECONDMATE's
  # home, and withdraw and surrender necessarily run with FM_HOME on the
  # primary, so a remover pointed at the controller's own state directory
  # removed a path that never existed. Handed the TASK's home, it removes what
  # is actually there. Deliberately no path-equality assertion: what must go
  # red is the credential SURVIVING, never a string differing.
  local tmp home id
  fm_test_tmproot_into tmp fm-cloud-state-compartment
  home="$tmp/compartment"
  id='child-1'
  seed_compartment_child_staging "$home" "$id"

  fm_cloud_state_remove "$home/state" "$id"

  assert_absent "$home/state/$id.cloud-account/auth.json" \
    "a compartment child's credential outlived its task in the compartment home"
  assert_absent "$home/state/$id.cloud-account" "the account staging directory survived"
  assert_absent "$home/state/$id.cloud-payload" "the payload staging directory survived"
  assert_absent "$home/state/$id.cloud-entrypoint" "the persisted entrypoint survived"
  assert_absent "$home/state/$id.cloud-worktree" \
    "the leased worktree pointer, claimed to be teardown's, outlived the task"
  assert_absent "$home/state/$id.worker-request.out" \
    "the request report, added to the file set by #280, outlived the task"
  assert_absent "$home/state/$id.worker-result.json" "the worker result survived"
  pass "a compartment child's credential is removed from the home it was staged in"
}

run_a_removal_never_reaches_a_same_id_task_in_another_home() {
  # Task ids are HOME-SCOPED, so the same id can be live in two homes at once:
  # a compartment child called X and, later, an ordinary local task called X in
  # the primary. A remover that resolved the home from the task id alone would
  # rm -rf the LIVE compartment child's credential, payload and results while
  # leaving the primary's own state behind - destroying one home's state and
  # reintroducing the leak in the other. Each remover therefore removes from
  # the directory it was handed, and from nowhere else.
  local tmp primary home id
  fm_test_tmproot_into tmp fm-cloud-state-same-id
  primary="$tmp/primary/state"
  home="$tmp/compartment"
  id=shared-id
  mkdir -p "$primary/$id.cloud-account"
  printf '{"refresh":"secret"}\n' > "$primary/$id.cloud-account/auth.json"
  printf 'entry\n' > "$primary/$id.cloud-entrypoint"
  seed_compartment_child_staging "$home" "$id"
  # An id-keyed redirect record, exactly as the rejected first design wrote it.
  # Nothing writes this file any more and nothing reads it; it is seeded here
  # on purpose so this case stays RED against any remover that resolves a home
  # from the task id instead of using the directory it was handed.
  printf '%s\n' "$home" > "$primary/$id.cloud-task-home"

  fm_cloud_state_remove "$primary" "$id"

  assert_absent "$primary/$id.cloud-account/auth.json" \
    "the primary's own credential was left behind"
  assert_absent "$primary/$id.cloud-entrypoint" "the primary's own entrypoint was left behind"
  assert_present "$home/state/$id.cloud-account/auth.json" \
    "removing the primary's task destroyed a live compartment child's credential"
  assert_present "$home/state/$id.cloud-payload/repo.bundle" \
    "removing the primary's task destroyed a live compartment child's payload"
  assert_present "$home/state/$id.worker-result.json" \
    "removing the primary's task destroyed a live compartment child's returned result"
  pass "a removal never reaches a same-id task living in another home"
}

run_the_generation_sweep_removes_the_whole_set_and_spares_the_outcome() {
  # The re-spawn sweep and the rollback share one lane. They must remove
  # everything the task-end remover does (or a new generation inherits it) plus
  # the leased-worktree pointer they own, and must never touch the outcome
  # directory, which can hold the only local copy of returned commits.
  local tmp state id
  fm_test_tmproot_into tmp fm-cloud-state-generation
  state="$tmp/state"
  id=gen-task
  mkdir -p "$state/$id.cloud-account" "$state/$id.cloud-payload" "$state/$id.cloud-outcome"
  printf '{"refresh":"secret"}\n' > "$state/$id.cloud-account/auth.json"
  printf 'bundle\n' > "$state/$id.cloud-payload/repo.bundle"
  printf 'entry\n' > "$state/$id.cloud-entrypoint"
  printf 'env\n' > "$state/$id.cloud-env"
  : > "$state/$id.cloud-execute-dispatched"
  printf 'path\n' > "$state/$id.cloud-worktree"
  printf '{}\n' > "$state/$id.worker-result.json"
  printf 'log\n' > "$state/$id.worker-execute.log"
  printf '{}\n' > "$state/$id.worker-reconcile.json"
  printf 'commits\n' > "$state/$id.cloud-outcome/outcome.bundle"

  fm_cloud_state_remove_generation "$state" "$id"

  assert_absent "$state/$id.cloud-account" "the sweep left the account staging directory"
  assert_absent "$state/$id.cloud-payload" "the sweep left the payload staging directory"
  assert_absent "$state/$id.cloud-entrypoint" "the sweep left the persisted entrypoint"
  assert_absent "$state/$id.cloud-env" "the sweep left the persisted environment"
  assert_absent "$state/$id.cloud-execute-dispatched" "the sweep left the dispatch marker"
  assert_absent "$state/$id.cloud-worktree" "the sweep left the leased worktree pointer"
  assert_absent "$state/$id.worker-request.out" "the sweep left the previous generation's request report"
  assert_absent "$state/$id.worker-result.json" "the sweep left the previous generation's result"
  assert_absent "$state/$id.worker-execute.log" "the sweep left the previous generation's log"
  assert_present "$state/$id.cloud-outcome/outcome.bundle" \
    "the sweep destroyed an unlanded outcome bundle"
  pass "the generation sweep removes the whole task-end set and spares the outcome"
}

run_the_receipt_reader_enforces_the_stagers_own_rules() {
  # The one place a remover is TOLD a home rather than handed one: the file the
  # controller writes for --task-home-out. The spawn resolved FM_SPAWN_TASK_HOME
  # with `cd -P && pwd -P` and required the home's marker to name the parent
  # compartment, so the reader must hold the value to the same rules. Anything
  # else falls back to the controller's own state directory, which leaves a
  # credential to be found rather than deleting somewhere it does not own.
  local tmp home fallback answer channel
  fm_test_tmproot_into tmp fm-cloud-state-receipt
  home="$tmp/compartment"
  fallback="$tmp/primary/state"
  channel="$tmp/task-home"
  mkdir -p "$home/state" "$fallback"
  printf 'smc-1\n' > "$home/.fm-secondmate-home"
  wrapper_fn() {  # emit the wrapper's own function definitions
    sed -n '/^fm_worker_receipt_state_dir() {/,/^}/p;/^fm_worker_receipt_credential_remains() {/,/^}/p' \
      "$ROOT/bin/fm-worker-lifecycle.sh"
  }
  receipt_dir() {  # <parent> <home>
    printf '%s\n%s\n' "$1" "$2" > "$channel"
    ( eval "$(wrapper_fn)"; fm_worker_receipt_state_dir "$channel" "$fallback" )
  }

  answer=$(receipt_dir smc-1 "$home")
  [ "$answer" = "$home/state" ] || fail "an authorized home was not followed: $answer"

  # 1. A symlinked DIRECTORY pointing at a seeded home.
  ln -s "$home" "$tmp/link-to-home"
  answer=$(receipt_dir smc-1 "$tmp/link-to-home")
  [ "$answer" = "$fallback" ] || fail "a symlinked home directory was followed: $answer"

  # 2. A seeded home reached through a symlinked PATH COMPONENT.
  mkdir -p "$tmp/real-parent/inner/state"
  printf 'smc-1\n' > "$tmp/real-parent/inner/.fm-secondmate-home"
  ln -s "$tmp/real-parent" "$tmp/link-parent"
  answer=$(receipt_dir smc-1 "$tmp/link-parent/inner")
  [ "$answer" = "$fallback" ] || fail "a symlinked path component was followed: $answer"

  # 3. A real, marked home whose marker names a DIFFERENT secondmate.
  mkdir -p "$tmp/other/state"
  printf 'smc-other\n' > "$tmp/other/.fm-secondmate-home"
  answer=$(receipt_dir smc-1 "$tmp/other")
  [ "$answer" = "$fallback" ] || fail "a home marked for another secondmate was followed: $answer"

  # Shapes that were already refused stay refused.
  answer=$(receipt_dir smc-1 compartment)
  [ "$answer" = "$fallback" ] || fail "a relative home was followed: $answer"
  answer=$(receipt_dir smc-1 "$home/../compartment")
  [ "$answer" = "$fallback" ] || fail "a traversal home was followed: $answer"
  answer=$(receipt_dir smc-1 "$tmp/absent")
  [ "$answer" = "$fallback" ] || fail "a missing home was followed: $answer"
  answer=$(receipt_dir '' "$home")
  [ "$answer" = "$fallback" ] || fail "a channel with no parent was followed: $answer"
  : > "$channel"
  answer=$( eval "$(wrapper_fn)"; fm_worker_receipt_state_dir "$channel" "$fallback" )
  [ "$answer" = "$fallback" ] || fail "an empty channel was followed: $answer"
  rm -f "$channel"
  answer=$( eval "$(wrapper_fn)"; fm_worker_receipt_state_dir "$channel" "$fallback" )
  [ "$answer" = "$fallback" ] || fail "an absent channel was followed: $answer"
  ln -s "$tmp/elsewhere" "$channel"
  answer=$( eval "$(wrapper_fn)"; fm_worker_receipt_state_dir "$channel" "$fallback" )
  [ "$answer" = "$fallback" ] || fail "a symlinked channel was followed: $answer"
  rm -f "$channel"
  pass "the receipt reader follows only a canonical home its marker names the parent of"
}

run_the_removal_audit_does_not_derive_its_subject_from_the_resolution() {
  # THE SAFETY NET, and the reason F1 was silent in production rather than
  # loud. The old check inspected the directory the removal had just resolved,
  # so when resolution fell back wrongly it inspected the primary, found
  # nothing (nothing was ever staged there), and the command exited 0
  # announcing success while the plaintext credential sat in the compartment
  # home. The audit's subjects must be fixed independently of the resolution.
  local tmp home fallback channel id
  fm_test_tmproot_into tmp fm-cloud-state-audit
  home="$tmp/compartment"
  fallback="$tmp/primary/state"
  channel="$tmp/task-home"
  id='child-9'
  mkdir -p "$home/state/$id.cloud-account" "$fallback"
  printf 'smc-1\n' > "$home/.fm-secondmate-home"
  printf '{"refresh":"secret"}\n' > "$home/state/$id.cloud-account/auth.json"
  printf 'smc-1\n%s\n' "$home" > "$channel"
  audit() {
    ( eval "$(sed -n '/^fm_worker_receipt_credential_remains() {/,/^}/p' \
        "$ROOT/bin/fm-worker-lifecycle.sh")"
      fm_worker_receipt_credential_remains "$channel" "$id" "$fallback" && echo REMAINS || echo GONE )
  }

  # A credential surviving in the home the CONTROLLER named must be seen, even
  # though the primary - the directory a wrongly fallen-back removal would have
  # touched - is empty.
  [ "$(audit)" = REMAINS ] \
    || fail "the audit missed a credential surviving in the task home the controller named"
  rm -f "$home/state/$id.cloud-account/auth.json"
  [ "$(audit)" = GONE ] || fail "the audit reported a removed credential as remaining"

  # And an ordinary task, whose credential lives in the controller's own home.
  mkdir -p "$fallback/$id.cloud-account"
  printf '{"refresh":"secret"}\n' > "$fallback/$id.cloud-account/auth.json"
  : > "$channel"
  [ "$(audit)" = REMAINS ] || fail "the audit missed a credential in the controller's own home"
  pass "the removal audit inspects the homes the controller named, not the one it resolved"
}

run_no_second_enumeration_of_the_cloud_file_set() {
  # THE STRUCTURAL INVARIANT behind this change. The per-task cloud file set
  # used to be spelled out in three places - the library, the re-spawn sweep,
  # and the spawn rollback - and only two of them knew about any given name.
  # That is how a file can be created by one lane and removed by none.
  #
  # SCOPE, stated rather than implied: this reads source text. It catches a
  # removal that NAMES one of these files, in any bin/ script of any language,
  # spelled with or without flags, through a glob, or through find -delete. It
  # cannot catch a name assembled at runtime from concatenation or from a
  # variable, and it is a lexical check, not a proof that no other remover
  # exists. It also deliberately ignores a name inside operator advice text and
  # rsync's --delete, which are not removals of these files.
  python3 - "$ROOT" <<'ENUM' || fail "a per-task cloud file name is enumerated outside its owner"
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
owner = root / "bin" / "fm-cloud-state-lib.sh"
# Stems, not full names: a glob like "$STATE/$ID".cloud-acc* names the file
# without spelling it, and the point is the file, not the spelling.
stems = [
    ".cloud-acc", ".cloud-payl", ".cloud-entry", ".cloud-env", ".cloud-exec",
    ".cloud-worktree", ".worker-req", ".worker-res", ".worker-exec",
    ".worker-recon",
]
removal = re.compile(
    r"(\brm\b"                      # rm, with or without flags
    r"|\bunlink\b"
    r"|(?<![-\w])-delete\b"         # find ... -delete, but never rsync --delete
    r"|\bshutil\.rmtree\b"
    r"|\bos\.(remove|unlink)\b"
    r"|\.unlink\("                  # pathlib
    r"|\bfs\.(unlink|rm)\b)"        # node
)
offenders = []
for script in sorted(list((root / "bin").glob("*.sh"))
                     + list((root / "bin").glob("*.py"))
                     + list((root / "bin").glob("*.mjs"))):
    if script == owner:
        continue
    for number, line in enumerate(script.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("#") or stripped.startswith("//"):
            continue
        match = removal.search(line)
        if match is None:
            continue
        # Operator advice is not a removal. This wrapper prints "remove it with
        # ..." next to its refusals, and a guard that fires on the help text is
        # the guard the next person in a hurry deletes.
        if re.search(r"\b(echo|printf|cat)\b", line[:match.start()]):
            continue
        # Only what the removal is actually AIMED at. Matching the whole line
        # flags an atomic write whose failure arm removes its own temp file on
        # a line that merely names the destination. `find ... -delete` is the
        # exception: its subject comes BEFORE the verb, so the whole line is
        # the argument scope there.
        if match.group(0).startswith("-delete"):
            arguments = line
        else:
            arguments = line[match.start():]
        if any(stem in arguments for stem in stems):
            offenders.append("{}:{}: {}".format(script.name, number, line.strip()))
assert not offenders, ("these remove a per-task cloud file outside bin/fm-cloud-state-lib.sh", offenders)
ENUM
  pass "no bin/ script outside the owner names a per-task cloud file in a removal"
}

run_the_secondmate_child_reaping_loop_calls_the_owner() {
  # Teardown's reaping loop is the one teardown that ends a cloud-placed child
  # of a SECONDMATE home when the parent goes first, and on base it removed the
  # child's metadata while never removing its cloud state at all.
  #
  # A RUN-TIME SEAM, not a source check. The loop's own text is extracted from
  # the shipped script and EXECUTED against stubs, with the owner replaced by a
  # recorder that writes OUTSIDE the home - so "the home is removed afterwards"
  # is irrelevant to whether the call was observed. A source check was shown to
  # stay green while the behavior was dead three ways: the call wrapped in a
  # never-true condition (shell does not force re-indentation), the owner
  # shadowed by a local no-op, and $sub_state re-pointed at a directory that
  # does not exist. This sees all three, because it asserts on a call that
  # happened and on the arguments it happened with.
  local tmp home sub_state child recorder driver worktree
  fm_test_tmproot_into tmp fm-cloud-state-reap
  home="$tmp/compartment"
  sub_state="$home/state"
  worktree="$tmp/child-worktree"
  recorder="$tmp/observed-calls"
  child='child-reap'
  mkdir -p "$sub_state" "$worktree"
  printf 'kind=ship\nbackend=tmux\nworktree=%s\n' "$worktree" > "$sub_state/$child.meta"
  : > "$sub_state/$child.status"
  : > "$recorder"

  driver="$tmp/driver.sh"
  cat > "$driver" <<'DRIVER'
#!/usr/bin/env bash
set -u
root=$1
home=$2
worktree=$3
recorder=$4
child=$5

# The shipped loop, verbatim.
eval "$(awk '/^cleanup_firstmate_home_children\(\) \{/,/^\}/' "$root/bin/fm-teardown.sh")"

# The owner, replaced by a recorder that lives OUTSIDE the home.
fm_cloud_state_remove() { printf '%s\t%s\n' "$1" "$2" >> "$recorder"; }

secondmate_state_metadata() { printf '%s\n' "$home/state/$child.meta"; }
meta_value() {
  case "$2" in
    kind) printf 'ship\n' ;;
    worktree) printf '%s\n' "$worktree" ;;
    *) : ;;
  esac
}
fm_backend_of_meta() { printf 'tmux\n'; }
managed_account_meta() { return 1; }
fm_account_lifecycle_lock_acquire() { printf 'lock-token\n'; }
fm_account_lifecycle_lock_release() { return 0; }
validate_child_worktree_for_removal() { return 0; }
validate_child_worktree_landed_state() { return 0; }
fm_treehouse_require_task_lease() { return 0; }
canonical_existing_dir() { printf '%s\n' "$1"; }
quiesce_child_endpoint() { return 0; }
safe_rm_rf_child_worktree() { return 0; }
remove_grok_turnend_auth() { return 0; }
TEARDOWN_ACCOUNT_LOCKS=()
CHECKOUT_LOCK_ROOT=$home/locks

cleanup_firstmate_home_children "$home"
DRIVER

  bash "$driver" "$ROOT" "$home" "$worktree" "$recorder" "$child" > "$tmp/driver.out" 2>&1 \
    || fail "the extracted reaping loop did not run: $(cat "$tmp/driver.out")"

  # It ran at all: the loop really did reach the end of a child's life.
  assert_absent "$sub_state/$child.meta" "the reaping loop never removed the child's metadata"
  # And it called the owner, with the child's OWN home and the child's OWN id.
  grep -qF "$(printf '%s\t%s' "$sub_state" "$child")" "$recorder" \
    || fail "the reaping loop never removed the child's cloud state: $(cat "$recorder")"
  pass "teardown's reaping loop is observed calling the owner with the child's own home"
}

run_no_shadowing_of_the_cloud_state_owner() {
  # The one escape the run-time seam above cannot see, because a redefinition
  # at the script's TOP LEVEL is outside the function text the seam extracts.
  # Both spellings, since the parenthesis form is not the only one bash takes.
  python3 - "$ROOT/bin/fm-teardown.sh" <<'SHADOW' || fail "the cloud state owner is shadowed"
import re
import sys

path = sys.argv[1]
shadow = re.compile(
    r"^\s*(?:function\s+fm_cloud_state_remove\b|fm_cloud_state_remove\s*\(\s*\))")
offenders = [
    number
    for number, line in enumerate(open(path, encoding="utf-8").read().splitlines(), 1)
    if shadow.match(line)
]
assert not offenders, (
    "bin/fm-teardown.sh redefines fm_cloud_state_remove, shadowing the owner", offenders)
SHADOW
  pass "no local definition shadows the cloud state owner"
}

run_cloud_credential_is_removed
run_teardown_actually_calls_the_owner
run_cloud_state_survives_set_e
run_cloud_credential_survives_a_symlinked_directory
run_compartment_child_credential_is_removed_from_its_task_home
run_a_removal_never_reaches_a_same_id_task_in_another_home
run_the_generation_sweep_removes_the_whole_set_and_spares_the_outcome
run_the_receipt_reader_enforces_the_stagers_own_rules
run_the_removal_audit_does_not_derive_its_subject_from_the_resolution
run_no_second_enumeration_of_the_cloud_file_set
run_the_secondmate_child_reaping_loop_calls_the_owner
run_no_shadowing_of_the_cloud_state_owner

echo "# fm-cloud-state.test.sh: all assertions passed"
