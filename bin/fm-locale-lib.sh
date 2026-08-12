#!/usr/bin/env bash
# bin/fm-locale-lib.sh - the single owner of locale sanitization for
# supervision-critical Perl and shasum paths.
#
# macOS system Perl can panic before executing when it inherits C.UTF-8 through
# LC_CTYPE or LANG while LC_ALL is unset. C.UTF-8 is valid on modern Linux, so
# this repair is deliberately Darwin-only. It uses bash's builtin OSTYPE rather
# than uname because supervision helpers can run with a restricted PATH.
#
# Source this file before invoking Perl or shasum. Sourcing applies the repair
# immediately and is idempotent. Explicit LC_ALL values and all other locales
# are preserved.

fm_locale_sanitize() {
  [ -z "${LC_ALL:-}" ] || return 0
  case "${OSTYPE:-}" in
    darwin*) ;;
    *) return 0 ;;
  esac
  case "${LC_CTYPE:-}${LANG:-}" in
    *C.UTF-8*) export LC_ALL=C ;;
  esac
}

fm_locale_sanitize
