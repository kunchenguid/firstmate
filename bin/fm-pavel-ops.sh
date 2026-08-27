#!/usr/bin/env bash
# fm-pavel-ops.sh - durable command boundary for the opt-in autonomous Pavel
# business-operations loop.
#
# The local `config/pavel-ops.json` file opts one Firstmate home into this flow.
# The exact schema is documented in docs/configuration.md. The implementation
# accepts only the verified Pi worker adapter, no-mistakes delivery, and standing
# yolo=on for the delegated scope, so enabling this flow cannot silently fall
# back to Claude or return green Pavel PRs to per-PR captain approval.
#
# Intake is one JSON object on stdin (or --file) with transport=telegram,
# chat_id, update_id, message_id, sender_id, date, text, optional attachments,
# and optional reply_to_message_id. The immutable identity is
# transport+chat_id+update_id. The event record is published before its durable
# check wake; replaying identical input is a no-op apart from repairing a missing
# wake, while conflicting bytes under one identity are refused and audited.
#
# Every event remains `captured` until Firstmate classifies it. A task
# classification creates or verifies its deterministic tasks-axi row before the
# event can leave intake. `conversation` and `reply` classifications create no
# task but retain the original event, reason, and related task, so chatter and
# answers remain auditable without manufacturing work.
#
# Authority routes are `ordinary`, `business-ambiguity`, and `hard-safety`.
# Ordinary reversible work becomes ready immediately. Business ambiguity enters
# the backlog first, then waits on one batched Pavel clarification under an
# external hold. Hard safety accepts only credentials, irreversible, legal,
# security-authority, or unbudgeted-spend and registers a captain hold. The
# pavel-ops skill owns the semantic classification procedure; this script owns
# deterministic persistence and refuses every unrecognized route.
#
# Delivery state is linear and evidence-bearing:
#   ready -> dispatched -> validating -> delivery_ready -> merge_queued
#   -> landed -> live -> notified
# `merge_queued` requires a full PR URL and the configured standing autonomy;
# `live` requires a full live URL. `notified` is written only after Telegram
# returns a concrete message_id for a live-completion send. An interrupted send
# stays `sending`, is surfaced by recover, and is never retried until explicitly
# reconciled, preferring visible uncertainty over a duplicate Pavel message.
# A confirmed Telegram API rejection becomes retryable and may be retried safely.
#
# Session start calls `recover --startup` only when the opt-in config exists.
# Recovery re-publishes missing intake, orphaned active-delivery, landed, and
# live-but-unnotified wakes, and surfaces unknown or retryable outbound delivery
# without touching project branches, PRs, or supervised tasks.
#
# Migration is non-destructive. `migration-audit` reads a legacy pending queue,
# held Pavel backlog rows, and an optional project clone, then reports how to
# preserve any ahead commit on a dedicated branch before guarded fleet sync.
# `adopt-task` links an existing paused task to this lifecycle without changing
# its backlog state, branch, commits, PR, or worker. Neither command resets,
# cleans, pushes, merges, or removes anything.
#
# Usage:
#   fm-pavel-ops.sh ingest [--file <event.json>]
#   fm-pavel-ops.sh inspect <event-id>
#   fm-pavel-ops.sh list
#   fm-pavel-ops.sh classify <event-id> --as task --title <title> --intent <intent> \
#     --reason <reason> --authority ordinary|business-ambiguity|hard-safety \
#     [--question <one-batched-question>] [--safety <boundary>] [--task-id <id>]
#   fm-pavel-ops.sh classify <event-id> --as conversation --reason <reason>
#   fm-pavel-ops.sh classify <event-id> --as reply --related-task <id> --reason <reason>
#   fm-pavel-ops.sh resolve-pavel <event-id> --reply-event <event-id> --answer <answer>
#   fm-pavel-ops.sh transition <event-id> <state> --evidence <evidence> \
#     [--pr-url <url>] [--live-url <url>]
#   fm-pavel-ops.sh failure <event-id> --stage <stage> --error <error>
#   fm-pavel-ops.sh send <event-id> --purpose qa|ack|clarification|live-completion --text <text>
#   fm-pavel-ops.sh reconcile-outbound <outbound-id> \
#     (--sent-message-id <id>|--confirm-not-sent)
#   fm-pavel-ops.sh recover [--startup]
#   fm-pavel-ops.sh adopt-task <task-id> --state <state> --note <evidence>
#   fm-pavel-ops.sh migration-audit [--legacy-pending <pending.jsonl>] \
#     [--clone <project-clone>] [--expected-head <commit>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  -h|--help|help|'')
    sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'
    [ -n "${1:-}" ] && exit 0 || exit 2
    ;;
esac

exec python3 "$SCRIPT_DIR/fm-pavel-ops.py" "$@"
