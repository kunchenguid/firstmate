#!/usr/bin/env bash
# Focused tests for live callsign ownership and One Piece role pools.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-identity)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
mkdir -p "$STATE" "$DATA"
trap 'rm -rf "$TMP_ROOT"' EXIT
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA"

# shellcheck source=bin/fm-identity-lib.sh
. "$ROOT/bin/fm-identity-lib.sh"

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }
record() { fm_identity_task_record "$1"; }

home_name=$(fm_identity_ensure_home)
case " $FM_IDENTITY_HOME_POOL " in *" $home_name "*) ;; *) fail "home name '$home_name' is outside the Firstmate pool" ;; esac
pass "fresh Firstmate homes use the dedicated role pool"

for reserved in Luffy Roger; do
  if fm_identity_validate_name "$reserved" >/dev/null 2>&1; then fail "$reserved was not reserved"; fi
done
pass "Luffy and Roger are reserved and never assignable"

write_meta() {
  local id=$1 kind=$2
  {
    printf 'kind=%s\n' "$kind"
    printf 'worktree=%s/%s\nwindow=session:%s\nbackend=tmux\n' "$TMP_ROOT" "$id" "$id"
    printf 'spawn_gen=gen-%s\n' "$id"
  } > "$STATE/$id.meta"
}

prov=$(fm_identity_reserve_fresh_task provisioning-task ship)
write_meta provisioning-task ship
fm_identity_activate_reserved_task_from_meta "$STATE/provisioning-task.meta" provisioning-task >/dev/null
active=$(fm_identity_reserve_fresh_task active-task ship)
write_meta active-task ship
fm_identity_activate_reserved_task_from_meta "$STATE/active-task.meta" active-task >/dev/null
[ "$prov" != "$active" ] || fail "active and provisioning identities collided"
pass "active and provisioning identities reserve distinct callsigns"

second=$(fm_identity_reserve_fresh_task second-task secondmate)
case " $FM_IDENTITY_SECOND_MATE_POOL " in *" $second "*) ;; *) fail "secondmate callsign '$second' is outside its pool" ;; esac
crew=$(fm_identity_reserve_fresh_task crew-task scout)
case " $FM_IDENTITY_CREWMATE_POOL " in *" $crew "*) ;; *) fail "crewmate callsign '$crew' is outside its pool" ;; esac
case " $FM_IDENTITY_SECOND_MATE_POOL " in *" $crew "*) fail "role pools overlap" ;; esac
pass "secondmates and crewmates select distinct role pools"

saved_crew_pool=$FM_IDENTITY_CREWMATE_POOL
FM_IDENTITY_CREWMATE_POOL=Fallback
fm_identity_write_task_record "$(record fallback-task)" fallback-task Fallback active
[ "$(fm_identity_choose_fresh_callsign suffix-task scout)" = Fallback-2 ] \
  || fail "an exhausted role pool did not use the deterministic suffix fallback"
FM_IDENTITY_CREWMATE_POOL=$saved_crew_pool
pass "exhausted role pools use deterministic suffix fallback"

old=$prov
renamed=$(fm_identity_rename_task "$STATE" "$old" ReleasedName)
[ "${renamed%%$'\t'*}" = ReleasedName ] || fail "rename did not publish new callsign"
if fm_identity_name_in_use "$old"; then fail "rename retained old callsign ownership"; fi
if fm_identity_resolve_selector "$STATE" "$old" >/dev/null 2>&1; then fail "retired callsign remained routable"; fi
pass "rename releases the old callsign immediately"

fm_identity_archive_task "$STATE/active-task.meta" active-task >/dev/null
if fm_identity_name_in_use "$active"; then fail "archived callsign still reserved"; fi
if fm_identity_resolve_selector "$STATE" "$active" >/dev/null 2>&1; then fail "archived callsign still resolved"; fi
reused=$(fm_identity_reserve_fresh_task reused-task ship)
[ -n "$reused" ] || fail "fresh allocation after archive failed"
write_meta reused-task ship
fm_identity_activate_reserved_task_from_meta "$STATE/reused-task.meta" reused-task >/dev/null
fm_identity_rename_task "$STATE" "$reused" "$active" >/dev/null
[ "$(fm_identity_resolve_selector "$STATE" "$active")" = reused-task ] || fail "reused active name resolved to the archived task"
pass "archived names can be reused and resolve to the new active task"

printf 'schema=fm-firstmate-identity.v1\nhome=%s\nname=Polaris\n' "$HOME_DIR" > "$DATA/firstmate.identity"
[ "$(fm_identity_ensure_home)" = Polaris ] || fail "existing Polaris home was renamed"
printf 'schema=fm-crew-identity.v1\nhome=%s\ntask_id=franklin-task\ncallsign=Franklin\nstatus=active\n' "$HOME_DIR" > "$(record franklin-task)"
write_meta franklin-task ship
[ "$(fm_identity_ensure_task_from_meta "$STATE/franklin-task.meta" franklin-task)" = Franklin ] || fail "existing Franklin identity changed"
fresh=$(fm_identity_choose_fresh_callsign fresh-after-compat ship)
[ "$(fm_identity_fold "$fresh")" != franklin ] || fail "fresh identity collided with Franklin"
pass "existing Polaris and Franklin identities remain compatible"

printf '%s\n' "$FM_IDENTITY_HOME_POOL" "$FM_IDENTITY_SECOND_MATE_POOL" "$FM_IDENTITY_CREWMATE_POOL" \
  | awk '{for (i=1;i<=NF;i++) print $i}' | sort | uniq -d | grep -q . && fail "role pool names overlap" || true
printf 'ok - live callsign ownership and role pools\n'
