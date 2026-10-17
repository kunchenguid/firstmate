#!/usr/bin/env bash
# Opt-in real Orca/Pi persistent-home proof, with an attended visual checkpoint.
# Usage through fm-test-run.sh, with FM_ORCA_SECONDMATE_LIVE=1 and:
#   FM_ORCA_PROOF_PHASE=launch|verify|retire
#   FM_ORCA_PROOF_PRIMARY=<new disposable primary home>
#   FM_ORCA_PROOF_HOME=<new disposable secondmate home>
#   FM_ORCA_PROOF_ID=<secondmate id>
#   FM_ORCA_PROOF_REPO=<HTTPS clone URL> (launch only)
#   FM_ORCA_PROOF_PROJECT=<clone name> (default proof)
#   FM_ORCA_PROOF_SCOUT_ID=<unique scout id> (default orca-proof-scout)
#   FM_ORCA_PROOF_TASK=<read-only scout request> (launch only)
# Launch refuses existing paths, seeds from this committed code root, and leaves
# the sessions open. Verify checks the child's visible labels, independent placement, and report.
# Retire requires FM_ORCA_PROOF_VISUAL_CONFIRMED=1 after human inspection and the
# secondmate's guarded child cleanup. No trap deletes unverified live resources.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_ORCA_SECONDMATE_LIVE orca pi gh

primary=${FM_ORCA_PROOF_PRIMARY:?explicit disposable primary required}
mate=${FM_ORCA_PROOF_HOME:?explicit disposable secondmate home required}
id=${FM_ORCA_PROOF_ID:?explicit test id required}
project=${FM_ORCA_PROOF_PROJECT:-proof}
scout=${FM_ORCA_PROOF_SCOUT_ID:-orca-proof-scout}
case "$id" in ''|*[!A-Za-z0-9_-]*) fail 'invalid proof id' ;; esac
case "$project" in ''|*[!A-Za-z0-9_-]*) fail 'invalid proof project' ;; esac
case "$scout" in ''|*[!A-Za-z0-9_-]*) fail 'invalid proof scout id' ;; esac
case "$primary:$mate" in /*:/*) ;; *) fail 'proof homes must be absolute' ;; esac
[ "$primary" != "$mate" ] || fail 'proof homes must differ'
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME=$primary
case "${FM_ORCA_PROOF_PHASE:-launch}" in
  launch)
    [ ! -e "$primary" ] && [ ! -L "$primary" ] && [ ! -e "$mate" ] && [ ! -L "$mate" ] || fail 'refusing pre-existing proof homes'
    [ -z "$(git -C "$ROOT" status --porcelain)" ] || fail 'commit the code under test first'
    repo=${FM_ORCA_PROOF_REPO:?explicit read-only proof repository required}
    task=${FM_ORCA_PROOF_TASK:?explicit read-only scout request required}
    case "$repo" in https://*) ;; *) fail 'proof repo must use HTTPS' ;; esac
    mkdir -p "$primary/config" "$primary/data" "$primary/state" "$primary/projects"
    printf '%s\n' "$id" > "$primary/.orca-secondmate-proof"
    printf 'orca\n' > "$primary/config/backend"
    printf 'pi\n' > "$primary/config/secondmate-harness"
    printf 'pi\n' > "$primary/config/crew-harness"
    printf 'manual\n' > "$primary/config/backlog-backend"
    printf -- '- %s [direct-PR] - disposable read-only proof clone\n' "$project" > "$primary/data/projects.md"
    # Keep fixture Git identity isolation while allowing read-only private
    # HTTPS clones through the authenticated gh helper, without storing tokens.
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='!gh auth git-credential'
    git clone --quiet "$repo" "$primary/projects/$project"
    export FM_SECONDMATE_CHARTER='Disposable Orca proof only. Idle until routed one read-only scout request; no project changes, publication, infrastructure credentials, production handoff, or unrelated work. Use Orca and Pi only. This home intentionally runs the committed source under test; do not switch branches or update it. Keep the scout terminal open after reporting, until the parent asks for guarded cleanup.'
    export FM_SECONDMATE_SCOPE='Disposable read-only Orca lifecycle proof only'
    bash "$ROOT/bin/fm-brief.sh" "$id" --secondmate "$project"
    bash "$ROOT/bin/fm-home-seed.sh" "$id" "$mate" "$project"
    [ "$(git -C "$mate" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse HEAD)" ] || fail 'seeded code differs from test code'
    # The unpushed test branch is intentional; never sync it to another branch.
    FM_SKIP_SECONDMATE_SYNC=1 bash "$ROOT/bin/fm-spawn.sh" "$id" --secondmate --backend orca --harness pi
    bash "$ROOT/bin/fm-send.sh" "$id" "Commission exactly one read-only scout named $scout on the $project project, using Orca and Pi. $task Do not use Railway credentials. Report through the correlated parent channel and retain the scout terminal for the visual check."
    pass "Orca/Pi secondmate launched; live report and visual inspection still pending: 2ndmate-$id, 2ndmate-$id · fm-$scout"
    ;;
  verify|retire)
    [ "$(cat "$primary/.orca-secondmate-proof")" = "$id" ] || fail 'not the recorded disposable proof primary'
    [ "$(cat "$mate/.fm-secondmate-home")" = "$id" ] || fail 'secondmate identity mismatch'
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_validate_task_endpoint "$primary/state/$id.meta" "$id" || fail 'invalid secondmate endpoint'
    if [ "$FM_ORCA_PROOF_PHASE" = verify ]; then
      child="$mate/state/$scout.meta"
      fm_backend_validate_task_endpoint "$child" "$scout" || fail 'invalid proof scout endpoint'
      [ -s "$mate/data/$scout/report.md" ] || fail 'proof scout report missing'
      child_workspace=$(fm_backend_meta_exact_value "$child" orca_worktree_id)
      child_terminal=$(fm_backend_meta_exact_value "$child" terminal)
      label="2ndmate-$id · fm-$scout"
      orca worktree show --worktree "id:$child_workspace" --json | \
        node "$ROOT/bin/backends/orca-home.js" worker-workspace "$child_workspace" "$label" || fail 'real worker label or independent placement is unconfirmed'
      orca terminal show --terminal "$child_terminal" --json | \
        node "$ROOT/bin/backends/orca-home.js" worker-terminal "$child_workspace" "$child_terminal" "$label" || fail 'real worker terminal label is unconfirmed'
      pass 'real scout report exists and Orca confirms both worker labels with no parent; inspect both terminals before retirement'
    else
      [ "${FM_ORCA_PROOF_VISUAL_CONFIRMED:-0}" = 1 ] || fail 'visual confirmation required before retirement'
      bash "$ROOT/bin/fm-teardown.sh" "$id"
      [ ! -e "$mate" ] && [ ! -e "$primary/state/$id.meta" ] || fail 'retirement incomplete'
      pass 'guarded Orca secondmate retirement completed'
    fi
    ;;
  *) fail 'unknown proof phase' ;;
esac
