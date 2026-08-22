#!/usr/bin/env bash
# Retrieval regression for the AGENTS.md state/<id>.meta owner pointer: it
# names bin/fm-spawn.sh's header as the owner of the base task-metadata fields,
# so that header (exercised through the public --help surface) must actually
# name the keys the script emits.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELP=$("$ROOT/bin/fm-spawn.sh" --help) || fail "fm-spawn.sh --help failed"

test_spawn_header_names_base_meta_keys() {
  local key
  for key in window= endpoint_task_id= worktree= project= harness= kind= \
    mode= yolo= tasktmp= model= effort=; do
    assert_contains "$HELP" "$key" \
      "spawn header does not document base meta key $key"
  done
  pass "spawn header documents every ordinary base meta key it emits"
}

test_spawn_header_names_routing_and_remote_meta_keys() {
  local key
  for key in matched_rule= quota_decision= quota_headroom= quota_runway= \
    dispatch_provider= dispatch_model_family= routing_source= \
    dispatch_override_reason= remote_host= remote_root= remote_backend= \
    remote_herdr_session= remote_target=; do
    assert_contains "$HELP" "$key" \
      "spawn header does not document routing/remote meta key $key"
  done
  pass "spawn header documents the routing and remote-route meta keys"
}

test_spawn_header_names_base_meta_keys
test_spawn_header_names_routing_and_remote_meta_keys
