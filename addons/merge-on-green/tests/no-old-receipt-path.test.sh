#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
# Allow receipt add-on documentation/fixtures and its intentional fork-copy e2e fixture.
while IFS= read -r hit; do
  file=${hit%%:*}
  [[ "$file" == receipts/* ]] && continue
  [[ "$file" == merge-on-green/tests/receipts-hook-e2e.sh || "$file" == merge-on-green/tests/no-old-receipt-path.test.sh ]] && continue
  [[ "$hit" == *'receipts/bin/fm-run-receipt.sh'* ]] && continue
  echo "FAIL: old receipt publisher path in $file" >&2
  exit 1
done < <(git -C "$ROOT" grep -n -F 'bin/fm-run-receipt.sh' -- '*.sh' || true)
echo 'PASS: no scripts outside receipts use the old receipt publisher path'
