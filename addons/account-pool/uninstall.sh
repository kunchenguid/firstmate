#!/usr/bin/env bash
# account-pool uninstall.sh - the add-on holds no state outside its checkout. Without it the hook lines
# are no-ops and workers launch on the ambient account; config/account-pool and the pool folder are the
# operator's and stay. Usage: uninstall.sh <fm-home>
echo "account-pool: nothing to remove. Delete ${FM_ADDONS_DIR:-${1:-<fm-home>}/projects/firstmate-addons}/account-pool to turn the pool off."
