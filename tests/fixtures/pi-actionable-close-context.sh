#!/usr/bin/env bash
sleep 6
printf 'WAKE_CONTEXT_PRESENTED: durable presentation complete; do not run bin/fm-wake-drain.sh again.\n'
printf 'Wake context packet could not be built after the durable presentation.\n'
printf 'Handle the durable human presentation below and use its exact acknowledgement command.\n\ndrained\n'
printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 7 --recovery-generation fixture-7\n' >&2
exit 1
