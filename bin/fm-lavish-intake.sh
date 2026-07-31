#!/usr/bin/env bash
# Consume durable Lavish answers at an existing Firstmate turn boundary.
#
# The fork identifies itself with:
#   lavish-axi 1.x (store-forward protocol 1)
# Older upstream binaries are ignored during cutover because their lifecycle
# commands are incompatible and must never be invoked by this adapter.
set -u

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"

command -v lavish-axi >/dev/null 2>&1 || exit 0
version=$(lavish-axi --version 2>/dev/null || true)
case "$version" in
  'lavish-axi 1.'*'(store-forward protocol 1)') ;;
  *) exit 0 ;;
esac

exec lavish-axi intake --home "$FM_HOME"
