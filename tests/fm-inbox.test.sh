#!/usr/bin/env bash
# Offline tests for durable text intake and disabled optional model calls.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-inbox)
CONFIG_HOME="$TMP_ROOT/home"
mkdir -p "$CONFIG_HOME/config" "$CONFIG_HOME/state" "$CONFIG_HOME/data"
inbox_env=()
while IFS= read -r inbox_knob; do
  [ -n "$inbox_knob" ] || continue
  inbox_env+=(-u "$inbox_knob")
done < <(env | sed -n 's/^\(FM_INBOX_[A-Za-z0-9_]*\)=.*/\1/p' | sort -u)
inbox_env+=(FM_HOME="$CONFIG_HOME" FM_STATE_OVERRIDE="$CONFIG_HOME/state"
            FM_CONFIG_OVERRIDE="$CONFIG_HOME/config")

# And a stub that records any attempt, so "no model call" is a checked fact rather
# than a claim about control flow. The real aws would need credentials; this one
# leaves evidence and exits non-zero.
INBOX_FAKEBIN=$(fm_fakebin "$TMP_ROOT/inbox-fake")
AWS_CALLED="$TMP_ROOT/aws-was-called"
cat > "$INBOX_FAKEBIN/aws" <<SH
#!/usr/bin/env bash
printf 'aws %s\n' "\$*" >> "$AWS_CALLED"
exit 9
SH
chmod +x "$INBOX_FAKEBIN/aws"
inbox_env+=(PATH="$INBOX_FAKEBIN:$PATH")

set +e
ask_out=$(env "${inbox_env[@]}" "$ROOT/bin/fm-inbox.sh" ask "how is the fleet" 2>&1)
ask_code=$?
set -e
[ "$ask_code" -ne 0 ] || fail "ask ran with nothing configured"
assert_contains "$ask_out" 'inbox-region' \
  "the first refusal should name the region file: $ask_out"

# One file at a time, so each refusal names one thing to do.
printf 'eu-somewhere-1\n' > "$CONFIG_HOME/config/inbox-region"
set +e
ask_out=$(env "${inbox_env[@]}" "$ROOT/bin/fm-inbox.sh" ask "how is the fleet" 2>&1)
ask_code=$?
set -e
[ "$ask_code" -ne 0 ] || fail "ask ran without a configured model"
assert_contains "$ask_out" 'inbox-ask-model' \
  "the refusal should name the model file to write: $ask_out"

set +e
say_out=$(printf '' | env "${inbox_env[@]}" "$ROOT/bin/fm-inbox.sh" say 2>&1)
say_code=$?
set -e
[ "$say_code" -ne 0 ] || fail "retired say command remained executable"
assert_contains "$say_out" 'unknown subcommand: say' \
  "the retired say command should be rejected by the public interface: $say_out"

rm -f "$CONFIG_HOME/config/inbox-region"
unconfigured_note=$(env "${inbox_env[@]}" \
  "$ROOT/bin/fm-inbox.sh" note "the handover must work with no configuration") \
  || fail "note should not need any configuration"
assert_contains "$unconfigured_note" 'queued ' "note should still queue a record"
assert_absent "$AWS_CALLED" \
  "no case above may reach a model: the aws stub recorded an attempt"
pass "the ask helper stays opt-in, retired say is rejected, and note keeps working"

# --help prints the whole header block, and finds where that block ends rather
# than counting lines to it, so growing the header cannot silently truncate the
# help again. The PRIVACY paragraph is the part that matters: it is the only place
# a new operator is told which subcommand sends text off this host, and a fixed
# line range had already dropped it.
inbox_help=$("$ROOT/bin/fm-inbox.sh" --help) || fail "fm-inbox.sh --help failed"
assert_contains "$inbox_help" 'PRIVACY:' \
  "the help must say which subcommands send anything to a model"
assert_contains "$inbox_help" 'make no network call at all' \
  "the help must name the subcommands that stay on this host"
assert_contains "$inbox_help" 'FM_HOME' \
  "the help must keep its environment section"
assert_contains "$inbox_help" 'inbox-ask-model' \
  "the help must name the files a home has to write"
assert_contains "$inbox_help" 'fm-inbox.sh note' \
  "the help must still open with the usage it always had"
assert_not_contains "$inbox_help" 'fm-inbox.sh say' \
  "the help must not advertise the retired say command"
pass "fm-inbox.sh --help prints its whole header, privacy paragraph included"


# Listing and draining are read-only until exact acknowledgement.
id=${unconfigured_note#queued }
id=${id%%$'\n'*}
assert_present "$CONFIG_HOME/state/inbox/$id.note" "queued note must be durable"
queue_before=$(cat "$CONFIG_HOME/state/.wake-queue")
listed=$(env "${inbox_env[@]}" "$ROOT/bin/fm-inbox.sh" list)
assert_contains "$listed" "$id" "list must include the pending note"
drained=$(env "${inbox_env[@]}" "$ROOT/bin/fm-inbox.sh" drain)
assert_contains "$drained" 'the handover must work' "drain must present the exact body"
assert_present "$CONFIG_HOME/state/inbox/$id.note" "drain without ack must preserve note"
env "${inbox_env[@]}" "$ROOT/bin/fm-inbox.sh" drain --ack "$id" >/dev/null
assert_absent "$CONFIG_HOME/state/inbox/$id.note" "ack must remove the pending entry"
assert_present "$CONFIG_HOME/state/inbox/handled/$id.note" "ack must preserve handled evidence"
[ "$(cat "$CONFIG_HOME/state/.wake-queue")" = "$queue_before" ] || fail "reads and ack must not append more wakes"
pass "text intake preserves a durable message until explicit acknowledgement"
alt_data="$TMP_ROOT/data-elsewhere"
mkdir -p "$alt_data"
printf '# Backlog\n\n## In flight\n- [ ] moved-one - Moved work (kind: ship)\n' > "$alt_data/backlog.md"
FM_DATA_OVERRIDE="$alt_data" "$ROOT/bin/fm-tasks-axi.sh" add canonical-one \
  'Canonical moved work' --kind ship --start >/dev/null
inbox_moved=$(env "${inbox_env[@]}" FM_DATA_OVERRIDE="$alt_data" "$ROOT/bin/fm-inbox.sh" status)
assert_contains "$inbox_moved" 'canonical-one' "status must read canonical records from the overridden data directory"
assert_not_contains "$inbox_moved" 'moved-one' "status read a retained legacy backlog row"
pass "status honors the home data override and ignores retained legacy task data"

# Exercise the removed public entrypoint paths: an old invocation must fail
# before any transport can run.
for retired in bin/fm-mail.sh bin/fm-mail-check.sh bin/fm-mail.py \
  bin/fm-voice-client.py bin/fm-voice-relay.py; do
  case "$retired" in *.py) interpreter=python3 ;; *) interpreter=bash ;; esac
  if "$interpreter" "$ROOT/$retired" --help >"$TMP_ROOT/retired.out" 2>&1; then
    fail "retired entrypoint remained executable: $retired"
  fi
done
pass "historical mail and dedicated voice invocations cannot execute"
