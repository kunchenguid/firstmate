#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-remote-generation-lib.sh"
TMP=$(fm_test_tmproot fm-remote-generation)
SCRIPT_DIR="$TMP/bin"
FM_HOME="$TMP"
STATE="$TMP/state"
mkdir -p "$SCRIPT_DIR" "$STATE"
ID=ios
META="$STATE/ios.meta"
export FM_GENERATION_FIXTURE="$TMP/ledger" FM_ROUTE_FIXTURE="$TMP/route"
cat > "$SCRIPT_DIR/fm-fleet-seats.sh" <<'SH'
#!/usr/bin/env bash
cat "$FM_GENERATION_FIXTURE"
SH
cat > "$SCRIPT_DIR/fm-on.sh" <<'SH'
#!/usr/bin/env bash
cat "$FM_ROUTE_FIXTURE"
SH
chmod +x "$SCRIPT_DIR/"*.sh
fm_write_meta "$META" remote_host=remote remote_root=/srv/fm home=/srv/home remote_spawn_gen=stale remote_target=stale
printf '%s\n' '{"incarnations":[{"generation":"current","lifecycle":"confirmed","startup_confirmed":true,"route":{"placement":"remote","backend":"herdr","host":"remote","remote_root":"/srv/fm","home":"/srv/home","spawn_gen":"current","target":"session:p1"}}]}' > "$FM_GENERATION_FIXTURE"
fm_remote_generation_resolve
assert_equals current "$FM_REMOTE_GENERATION" 'authoritative generation replaces stale parent'
assert_equals current "$(fm_meta_get "$META" remote_spawn_gen)" 'generation persisted before lifecycle operation'
fm_write_meta "$META" remote_host=remote remote_root=/srv/fm home=/srv/home custom=preserved remote_target=session:p1 remote_spawn_gen=current
cp "$META" "$TMP/current-meta"
fm_remote_generation_resolve
cmp -s "$META" "$TMP/current-meta" || fail 'current ledger metadata was reordered'
jq '.incarnations += [{generation:"candidate", lifecycle:"reserved", route:{target:null,spawn_gen:null}}]' "$FM_GENERATION_FIXTURE" > "$TMP/candidate"
mv "$TMP/candidate" "$FM_GENERATION_FIXTURE"
if fm_remote_generation_resolve retire; then fail 'unresolved candidate permitted retirement'; fi
assert_equals current "$(fm_meta_get "$META" remote_spawn_gen)" 'refusal preserves parent identity'
printf '%s\n' '{"incarnations":[]}' > "$FM_GENERATION_FIXTURE"
printf 'schema=fm-remote-secondmate-control.v1\nbackend=herdr\nspawn_gen=legacy\ntarget=session:p2\n' > "$FM_ROUTE_FIXTURE"
fm_remote_generation_resolve
assert_equals legacy "$FM_REMOTE_GENERATION" 'legacy predecessor resolved from host'
assert_equals session:p2 "$(fm_meta_get "$META" remote_target)" 'legacy target persisted'
cp "$META" "$TMP/legacy-meta"
fm_remote_generation_resolve
cmp -s "$META" "$TMP/legacy-meta" || fail 'current host metadata was reordered'
rm "$FM_ROUTE_FIXTURE"
fm_remote_generation_resolve retire
assert_equals legacy "$FM_REMOTE_GENERATION" 'retirement retry retains fence'
if fm_remote_generation_resolve; then fail 'relaunch accepted unavailable host identity'; fi
# A home that never reserved a seat reads back empty. That is the ordinary
# uncapped case, so resolution must fall through to the host route without a
# JSON decoder the caller does not otherwise use.
: > "$FM_GENERATION_FIXTURE"
printf 'schema=fm-remote-secondmate-control.v1\nbackend=herdr\nspawn_gen=uncapped\ntarget=session:p3\n' > "$FM_ROUTE_FIXTURE"
NOJQ="$TMP/no-jq"
mkdir -p "$NOJQ"
printf '#!/usr/bin/env bash\nexit 127\n' > "$NOJQ/jq"
chmod +x "$NOJQ/jq"
if ! PATH="$NOJQ:$PATH" fm_remote_generation_resolve; then
  fail 'an absent seat ledger needed a JSON decoder to resolve the host route'
fi
assert_equals uncapped "$FM_REMOTE_GENERATION" 'an absent seat ledger resolved no generation'
assert_equals session:p3 "$(fm_meta_get "$META" remote_target)" 'an absent seat ledger lost the host target'
rm -f "$FM_ROUTE_FIXTURE"

# The launch predecessor is the newest generation the host still records. A
# launch that reached an endpoint and was then cancelled counts even though it
# never confirmed a startup; a prelaunch refusal and a stopped predecessor
# never became the host's record.
bound_route() { printf '{"placement":"remote","host":"remote","remote_root":"/srv/fm","home":"/srv/home","spawn_gen":%s,"target":%s}' "$1" "$2"; }
LEDGER_A="{\"generation\":\"A\",\"lifecycle\":\"confirmed\",\"startup_confirmed\":true,\"route\":$(bound_route '"A"' '"session:p1"')}"
LEDGER_B="{\"generation\":\"B\",\"lifecycle\":\"released\",\"startup_confirmed\":false,\"disposition\":{\"reason\":\"cancelled\",\"source\":\"reconcile-remote\"},\"route\":$(bound_route null '"session:p1"')}"
assert_equals B "$(fm_remote_launch_predecessor "{\"incarnations\":[$LEDGER_A,$LEDGER_B]}" remote /srv/fm /srv/home)" \
  'a cancelled unconfirmed launch did not become the predecessor'
assert_equals B "$(fm_remote_launch_predecessor \
  "{\"incarnations\":[$LEDGER_A,{\"generation\":\"B\",\"lifecycle\":\"reclaimed\",\"startup_confirmed\":true,\"disposition\":{\"reason\":\"dead-after-start\"},\"route\":$(bound_route '"B"' '"session:p1"')}]}" \
  remote /srv/fm /srv/home)" 'a started generation that died did not become the predecessor'
assert_equals A "$(fm_remote_launch_predecessor \
  "{\"incarnations\":[$LEDGER_A,{\"generation\":\"B\",\"lifecycle\":\"released\",\"startup_confirmed\":false,\"disposition\":{\"reason\":\"prelaunch\"},\"route\":$(bound_route null null)}]}" \
  remote /srv/fm /srv/home)" 'a prelaunch refusal displaced the running generation'
assert_equals A "$(fm_remote_launch_predecessor \
  "{\"incarnations\":[$LEDGER_A,{\"generation\":\"B\",\"lifecycle\":\"released\",\"startup_confirmed\":false,\"disposition\":{\"reason\":\"old-stopped\"},\"route\":$(bound_route null null)}]}" \
  remote /srv/fm /srv/home)" 'a stopped predecessor displaced the running generation'
assert_equals - "$(fm_remote_launch_predecessor "{\"incarnations\":[$LEDGER_A]}" other-host /srv/fm /srv/home)" \
  'another host route answered for this one'
assert_equals - "$(fm_remote_launch_predecessor '{"incarnations":[]}' remote /srv/fm /srv/home)" \
  'an empty ledger named a predecessor'
printf 'remote generation regressions passed\n'
