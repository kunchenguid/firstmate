#!/usr/bin/env bash
# fm-meta-lib.sh - the single owner of the task-record key vocabulary.
#
# A task record (state/<id>.meta) is a flat key=value file that several tracked
# bin/ scripts write: fm-spawn.sh writes the launch record and rewrites it on a
# relaunch (adding control_relaunch_tx), plus the remote-secondmate route
# record (remote_*) and the Orca cleanup recovery record, fm-remote-secondmate-relaunch.sh
# refreshes harness/model/effort, fm-pr-check.sh records pr/pr_head,
# fm-review-check.sh records review/review_head, fm-x-lib.sh records the x_*
# relay link, fm-captain-hold.sh records decisions_reviewed/decision_keys, and
# fm-teardown.sh stamps spawn_gen on a legacy record. Each of them appends or
# rewrites in its own order, so no writer may assume another's key sits last.
#
# fm_meta_key_known answers whether firstmate itself records a key. It is how a
# reader tells firstmate's own writes from foreign bytes without keeping a
# private list that drifts: fm_pr_metadata_identity_parse (bin/fm-pr-lib.sh)
# accepts any key named here after the pr= identity and refuses any other.
# A writer that records a new key names it here in the same change, or the
# merge poll refuses every record that key lands in after pr=.
#
# fm_meta_get (bin/fm-backend.sh) reads a key's value; this file owns only which
# keys exist.

# fm_meta_key_known <key>: succeeds when a tracked bin/ script records <key>.
fm_meta_key_known() {
  case "$1" in
    # bin/fm-spawn.sh: the launch record, rewritten on relaunch
    window|endpoint_task_id|worktree|project|harness|approval_mode|kind|mode|yolo|\
    branch|tasktmp|base_branch|upstream_consent|forge|backup_remote|backup_prefix|\
    model|effort|dispatch_override|opencode_version|account|account_provider|\
    omp_profile|hermes_profile|hermes_home|busy_gen|spawn_gen|traceparent|\
    backend|backend_detect|\
    herdr_session|herdr_workspace_id|herdr_tab_id|herdr_pane_id|\
    zellij_session|zellij_tab_id|zellij_pane_id|\
    orca_worktree_id|terminal|cmux_workspace_id|cmux_surface_id|\
    paseo_terminal_id|paseo_workspace_id|\
    rex_server|rex_session_id|rex_window_id|rex_block_id|\
    t3_thread_id|t3_project_id|tern_session_id|tern_tab_id|tern_block_id|\
    hc_session|hc_terminal|home|projects|control_relaunch_tx|\
    polytoken_session|polytoken_port|polytoken_credential) return 0 ;;
    # bin/fm-pr-check.sh and bin/fm-review-check.sh: the delivery identity
    pr|pr_head|review|review_head) return 0 ;;
    # bin/fm-x-lib.sh: the Relay link
    x_request|x_request_ts|x_followups|x_platform|x_reply_max_chars) return 0 ;;
    # bin/fm-captain-hold.sh: the completion attestation
    decisions_reviewed|decision_keys) return 0 ;;
    # bin/fm-spawn.sh: the remote-secondmate route record
    remote_host|remote_root|remote_backend|remote_herdr_session|\
    remote_rex_session_id|remote_rex_server|remote_target) return 0 ;;
    # bin/fm-spawn.sh: the Orca worktree cleanup recovery record
    cleanup_recovery) return 0 ;;
    *) return 1 ;;
  esac
}
