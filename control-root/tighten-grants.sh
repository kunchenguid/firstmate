#!/usr/bin/env bash
# tighten-grants.sh - run ON a relay task host to make its authorizations safe.
#
# Usage: tighten-grants.sh <policy-id>   bind every grant to <policy-id>, then
#                                        revoke anything still bound to the
#                                        built-in full-access policy
#        tighten-grants.sh list          print the grant list and nothing else
#
# bin/fm-relay-conn.sh pipes this to the host over ordinary SSH rather than
# quoting it into a command argument, because a script that has to survive two
# levels of shell quoting stops being reviewable, and this one decides whether a
# machine is wide open.
#
# Two passes, and the second is the one that matters. Tightening can legitimately
# fail on a superseded grant (bifrost answers 409 for one that a newer pairing
# has already displaced), and treating that as fatal would leave the caller
# unpaired while the dangerous grant stayed. So: tighten what can be tightened,
# then REVOKE anything still bound to ssh-key-full-access. That set is exactly
# the grants that give arbitrary command execution on this machine, and no
# reading of "least privilege" lets one survive a pairing run. Every revocation
# is printed, because silently deleting an authorization someone else established
# would be worse than the exposure it removes.
set -u

BIFROST=${BIFROST_BIN:-bifrost}
MODE=${1:-list}

grant_ids() {
  "$BIFROST" setting grant list 2>/dev/null | sed -n 's/^  - \([0-9a-f-]\{36\}\).*/\1/p'
}

full_access_ids() {
  "$BIFROST" setting grant list 2>/dev/null | awk '
    /^  - / { id = $2; next }
    /ssh-key-full-access/ { if (id != "") { print id; id = "" } }
  '
}

if [ "$MODE" = list ]; then
  "$BIFROST" setting grant list
  exit $?
fi

POLICY=$MODE
tightened=0
for g in $(grant_ids); do
  if "$BIFROST" setting grant update --grant-id "$g" --access selected --policy "$POLICY" \
      --file-access read_write --stdin false --interactive false >/dev/null 2>&1; then
    tightened=$((tightened + 1))
  else
    echo "tighten could-not-tighten $g"
  fi
done

revoked=0
for g in $(full_access_ids); do
  if "$BIFROST" setting grant revoke "$g" >/dev/null 2>&1; then
    revoked=$((revoked + 1))
    echo "tighten revoked-full-access $g"
  else
    echo "tighten REVOKE-FAILED $g"
  fi
done

echo "tighten summary tightened=$tightened revoked=$revoked"
[ "$tightened" -gt 0 ] || [ "$revoked" -gt 0 ]
