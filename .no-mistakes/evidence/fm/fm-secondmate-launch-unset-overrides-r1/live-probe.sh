#!/usr/bin/env bash
set -eu
name=$1
E=~/.no-mistakes/evidence/01M742GVY0TYVH8CG9X6SG2B0Y
ROOT={run-worktree}
exec > "$E/$name.txt" 2>&1
printf 'Actual secondmate CLI child environment (%s)\nFM_HOME=%s\nFM_PUBLIC_FOLLOWUP_PRIMARY_HOME=%s\nFM_SUPERVISION_MODEL=%s\n' "$name" "$FM_HOME" "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME-unset}" "${FM_SUPERVISION_MODEL-unset}"
for v in FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE; do
 if printenv "$v"; then echo "FAIL: $v exists"; exit 1; else echo "$v: absent"; fi
done
printf '#!/bin/sh\nexit 0\n' > "$FM_HOME/state/env-proof.check.sh"
printf 'synthetic trust binding\n' > "$FM_HOME/state/env-proof.check-trust"
"$ROOT/bin/fm-check-unregister.sh" env-proof
[ ! -e "$FM_HOME/state/env-proof.check.sh" ]
[ ! -e "$FM_HOME/state/env-proof.check-trust" ]
echo 'PASS: both synthetic watcher files retired in secondmate state'
# Preserve the explicitly-empty guard as an independent adversarial control.
if FM_STATE_OVERRIDE= "$ROOT/bin/fm-check-unregister.sh" env-proof; then echo 'FAIL: explicit-empty guard accepted'; exit 1; fi
echo 'PASS: explicit-empty override remains refused'
