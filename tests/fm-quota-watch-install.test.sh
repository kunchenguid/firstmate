#!/usr/bin/env bash
# Tests for bin/fm-quota-watch-install.sh: the print-only (by default) crontab/
# launchd generator for bin/fm-quota-watch.sh.
#
# Regression target: a production bug where the generated PATH resolved
# quota-axi (so quota reading always worked) but not herdr (installed in a
# different directory), so every interrupt/resume send through fm-send.sh
# failed silently on every cron firing. Every case here fully controls PATH
# (no reliance on whatever happens to be installed on the machine running the
# suite) via small per-binary fake directories, and proves - the same way a
# real cron/launchd invocation would see it - that the generated PATH actually
# resolves every binary it claims to include.
#
# Matrix:
#   (a) quota-axi, jq, and every found optional backend CLI (here: tmux and
#       herdr, each in its own directory) all resolve through the generated
#       crontab-line PATH under a fully scrubbed environment
#   (b) the same holds for the generated launchd plist's PATH
#   (c) a backend CLI that is not installed (zellij, cmux) is silently
#       omitted - no error, and it is not falsely claimed as resolvable
#   (d) missing quota-axi is a hard, clear failure
#   (e) missing jq is a hard, clear failure
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL_BIN="$ROOT/bin/fm-quota-watch-install.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-watch-install-tests)

# One fake executable named <name>, alone in its own directory. Echoes the
# directory so callers can build a PATH from several of these to test
# multi-directory merging without polluting a shared fakebin.
make_fake_bin_dir() {  # <case_dir> <name>
  local case_dir=$1 name=$2 dir
  dir="$case_dir/bin-$name"
  mkdir -p "$dir"
  cat > "$dir/$name" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/$name"
  printf '%s\n' "$dir"
}

# A directory of symlinks to exactly the coreutils fm-quota-watch-install.sh
# and its bash shebang need (bash itself, cat, dirname, env, grep, sed) -
# resolved from THIS test run's own real PATH - and nothing else. Used only by
# the missing-quota-axi/missing-jq cases so a real system jq (observed at
# /usr/bin/jq on some machines) cannot mask the "jq is missing" scenario the
# way a plain /usr/bin:/bin:/usr/sbin:/sbin prefix would.
make_curated_system_dir() {  # <case_dir>
  local case_dir=$1 dir tool resolved
  dir="$case_dir/system"
  mkdir -p "$dir"
  for tool in bash cat dirname env grep sed; do
    resolved=$(command -v "$tool") || fail "test setup: '$tool' not found on this machine's own PATH"
    ln -s "$resolved" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

# Extract the PATH="..." value from a generated crontab line.
extract_cron_path() {  # <crontab-line-output>
  printf '%s\n' "$1" | grep -o 'PATH="[^"]*"' | head -1 | sed 's/^PATH="//;s/"$//'
}

# Extract the PATH string value from a generated launchd plist (the <string>
# immediately following the PATH <key>).
extract_launchd_path() {  # <plist-output>
  printf '%s\n' "$1" | awk '
    /<key>PATH<\/key>/ { want=1; next }
    want { gsub(/<\/?string>/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }
  '
}

# --- (a)/(c)/(d)/(e) crontab generation ---------------------------------------

test_crontab_path_resolves_every_included_binary() {
  local case_dir d_quota d_jq d_tmux d_herdr full_path out rc cron_line generated_path
  case_dir="$TMP_ROOT/${FUNCNAME[0]}"
  mkdir -p "$case_dir"
  d_quota=$(make_fake_bin_dir "$case_dir" quota-axi)
  d_jq=$(make_fake_bin_dir "$case_dir" jq)
  d_tmux=$(make_fake_bin_dir "$case_dir" tmux)
  d_herdr=$(make_fake_bin_dir "$case_dir" herdr)
  full_path="$d_quota:$d_jq:$d_tmux:$d_herdr:/usr/bin:/bin:/usr/sbin:/sbin"

  out=$(PATH="$full_path" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" "$INSTALL_BIN" 2>&1)
  rc=$?
  expect_code 0 "$rc" "crontab generation succeeds when quota-axi/jq/tmux/herdr are all present"

  cron_line=$(printf '%s\n' "$out" | grep -F '*/5 * * * *')
  [ -n "$cron_line" ] || fail "no crontab line found in output: $out"
  generated_path=$(extract_cron_path "$cron_line")
  [ -n "$generated_path" ] || fail "could not extract PATH= from generated crontab line"

  for bin in quota-axi jq tmux herdr; do
    # shellcheck disable=SC2016 # intentional: $1 expands in the inner sh -c, not here.
    env -i PATH="$generated_path" sh -c 'command -v "$1"' _ "$bin" >/dev/null 2>&1 \
      || fail "generated crontab PATH does not resolve '$bin' the way a real cron invocation would (PATH=$generated_path)"
  done

  # zellij/cmux were never installed anywhere on $full_path: the generated
  # PATH must not claim to resolve them either - a false resolution here would
  # mean the install script fabricated a directory it never actually checked.
  for bin in zellij cmux; do
    # shellcheck disable=SC2016 # intentional: $1 expands in the inner sh -c, not here.
    if env -i PATH="$generated_path" sh -c 'command -v "$1"' _ "$bin" >/dev/null 2>&1; then
      fail "generated crontab PATH unexpectedly resolves '$bin', which was never installed on the generation PATH"
    fi
  done

  assert_contains "$out" "PATH will include: quota-axi jq tmux herdr" "install script reports exactly the binaries it found"

  pass "crontab-generated PATH resolves quota-axi/jq/tmux/herdr and omits zellij/cmux, verified under a scrubbed environment"
}

test_launchd_path_resolves_every_included_binary() {
  local case_dir d_quota d_jq d_tmux d_herdr full_path out rc generated_path
  case_dir="$TMP_ROOT/${FUNCNAME[0]}"
  mkdir -p "$case_dir"
  d_quota=$(make_fake_bin_dir "$case_dir" quota-axi)
  d_jq=$(make_fake_bin_dir "$case_dir" jq)
  d_tmux=$(make_fake_bin_dir "$case_dir" tmux)
  d_herdr=$(make_fake_bin_dir "$case_dir" herdr)
  full_path="$d_quota:$d_jq:$d_tmux:$d_herdr:/usr/bin:/bin:/usr/sbin:/sbin"

  out=$(PATH="$full_path" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" "$INSTALL_BIN" --launchd 2>&1)
  rc=$?
  expect_code 0 "$rc" "launchd generation succeeds when quota-axi/jq/tmux/herdr are all present"

  generated_path=$(extract_launchd_path "$out")
  [ -n "$generated_path" ] || fail "could not extract the PATH string from the generated launchd plist"

  for bin in quota-axi jq tmux herdr; do
    # shellcheck disable=SC2016 # intentional: $1 expands in the inner sh -c, not here.
    env -i PATH="$generated_path" sh -c 'command -v "$1"' _ "$bin" >/dev/null 2>&1 \
      || fail "generated launchd PATH does not resolve '$bin' the way launchd's own scrubbed environment would (PATH=$generated_path)"
  done

  pass "launchd-generated PATH resolves quota-axi/jq/tmux/herdr under a scrubbed environment"
}

test_missing_quota_axi_is_a_hard_failure() {
  local case_dir d_jq d_system out rc
  case_dir="$TMP_ROOT/${FUNCNAME[0]}"
  mkdir -p "$case_dir"
  d_jq=$(make_fake_bin_dir "$case_dir" jq)
  d_system=$(make_curated_system_dir "$case_dir")

  out=$(PATH="$d_jq:$d_system" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" "$INSTALL_BIN" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "install script must refuse to generate an entry when quota-axi is missing"
  assert_contains "$out" "quota-axi not found on PATH" "clear message when quota-axi is missing"

  pass "missing quota-axi is a hard, clear failure rather than a broken generated entry"
}

test_missing_jq_is_a_hard_failure() {
  local case_dir d_quota d_system out rc
  case_dir="$TMP_ROOT/${FUNCNAME[0]}"
  mkdir -p "$case_dir"
  d_quota=$(make_fake_bin_dir "$case_dir" quota-axi)
  d_system=$(make_curated_system_dir "$case_dir")

  out=$(PATH="$d_quota:$d_system" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" "$INSTALL_BIN" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "install script must refuse to generate an entry when jq is missing"
  assert_contains "$out" "jq not found on PATH" "clear message when jq is missing"

  pass "missing jq is a hard, clear failure rather than a broken generated entry"
}

# --- run -----------------------------------------------------------------

test_crontab_path_resolves_every_included_binary
test_launchd_path_resolves_every_included_binary
test_missing_quota_axi_is_a_hard_failure
test_missing_jq_is_a_hard_failure
