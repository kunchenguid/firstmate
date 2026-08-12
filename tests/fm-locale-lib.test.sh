#!/usr/bin/env bash
# tests/fm-locale-lib.test.sh - focused coverage for Darwin C.UTF-8 sanitization.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCALE_LIB="$ROOT/bin/fm-locale-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-locale-lib)

run_locale_case() {  # <ostype> <lc-ctype> <lang> <lc-all-or-unset>
  local ostype=$1 lc_ctype=$2 lang=$3 lc_all=$4
  if [ "$lc_all" = unset ]; then
    # shellcheck disable=SC2016  # Positional and locale expansion belongs to the child bash.
    env -u LC_ALL LC_CTYPE="$lc_ctype" LANG="$lang" bash -c \
      'OSTYPE=$1; . "$2"; printf "%s\n" "${LC_ALL:-unset}"' _ "$ostype" "$LOCALE_LIB"
  else
    LC_ALL="$lc_all" LC_CTYPE="$lc_ctype" LANG="$lang" bash -c \
      'OSTYPE=$1; . "$2"; printf "%s\n" "$LC_ALL"' _ "$ostype" "$LOCALE_LIB"
  fi
}

test_darwin_c_utf8_is_sanitized() {
  local out
  out=$(run_locale_case darwin24 C.UTF-8 C.UTF-8 unset)
  [ "$out" = C ] || fail "Darwin C.UTF-8 must export LC_ALL=C, got '$out'"
  pass "fm_locale_sanitize: broken C.UTF-8 locale on Darwin exports LC_ALL=C"
}

test_darwin_lang_alone_is_sanitized() {
  local out
  out=$(run_locale_case darwin24 '' C.UTF-8 unset)
  [ "$out" = C ] || fail "Darwin LANG=C.UTF-8 must export LC_ALL=C, got '$out'"
  pass "fm_locale_sanitize: LANG=C.UTF-8 alone on Darwin triggers sanitization"
}

test_darwin_lc_ctype_alone_is_sanitized() {
  local out
  out=$(run_locale_case darwin24 C.UTF-8 '' unset)
  [ "$out" = C ] || fail "Darwin LC_CTYPE=C.UTF-8 must export LC_ALL=C, got '$out'"
  pass "fm_locale_sanitize: LC_CTYPE=C.UTF-8 alone on Darwin triggers sanitization"
}

test_sanitized_locale_makes_fixture_perl_executable_without_uname() {
  local toolbin="$TMP_ROOT/no-uname" out
  mkdir -p "$toolbin"
  ln -s "$(command -v bash)" "$toolbin/bash"
  cat > "$toolbin/perl" <<'SH'
#!/usr/bin/env bash
[ "${LC_ALL:-}" = C ] || {
  echo "panic: unsupported inherited C.UTF-8" >&2
  exit 9
}
printf 'perl-ok\n'
SH
  chmod +x "$toolbin/perl"
  # shellcheck disable=SC2016  # The library path is expanded by the restricted child bash.
  out=$(env -u LC_ALL LC_CTYPE=C.UTF-8 LANG=C.UTF-8 PATH="$toolbin" bash -c \
    'OSTYPE=darwin24; . "$1"; perl' _ "$LOCALE_LIB" 2>&1)
  [ "$out" = perl-ok ] || fail "sanitized fixture perl must execute without uname on PATH, got '$out'"
  pass "fm_locale_sanitize: restricted PATH child perl runs after sanitization"
}

test_working_darwin_locale_is_untouched() {
  local out
  out=$(run_locale_case darwin24 en_US.UTF-8 en_US.UTF-8 unset)
  [ "$out" = unset ] || fail "working Darwin UTF-8 locale must remain untouched, got '$out'"
  pass "fm_locale_sanitize: working Darwin UTF-8 locale is untouched"
}

test_explicit_lc_all_is_preserved() {
  local out
  out=$(run_locale_case darwin24 C.UTF-8 C.UTF-8 POSIX)
  [ "$out" = POSIX ] || fail "explicit LC_ALL must be preserved, got '$out'"
  pass "fm_locale_sanitize: explicit LC_ALL is preserved"
}

test_linux_c_utf8_is_untouched() {
  local out
  out=$(run_locale_case linux-gnu C.UTF-8 C.UTF-8 unset)
  [ "$out" = unset ] || fail "Linux C.UTF-8 must remain untouched, got '$out'"
  pass "fm_locale_sanitize: Linux C.UTF-8 is untouched"
}

test_resourcing_is_idempotent() {
  local out
  # shellcheck disable=SC2016  # Library paths and LC_ALL are expanded by the child bash.
  out=$(env -u LC_ALL LC_CTYPE=C.UTF-8 LANG=C.UTF-8 bash -c \
    'OSTYPE=darwin24; . "$1"; . "$1"; printf "%s\n" "$LC_ALL"' _ "$LOCALE_LIB")
  [ "$out" = C ] || fail "re-sourcing must leave LC_ALL=C, got '$out'"
  pass "fm_locale_sanitize: re-sourcing is idempotent"
}

test_darwin_c_utf8_is_sanitized
test_darwin_lang_alone_is_sanitized
test_darwin_lc_ctype_alone_is_sanitized
test_sanitized_locale_makes_fixture_perl_executable_without_uname
test_working_darwin_locale_is_untouched
test_explicit_lc_all_is_preserved
test_linux_c_utf8_is_untouched
test_resourcing_is_idempotent
