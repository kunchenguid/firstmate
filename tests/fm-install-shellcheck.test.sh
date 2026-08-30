#!/usr/bin/env bash
# Characterization tests for fm-install-shellcheck.sh's hermetic installer path.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
REQUIRED=$("$ROOT/bin/fm-lint.sh" --required-version)

# Official GitHub release asset sha256 values for shellcheck v0.11.0 .tar.xz
# archives (https://github.com/koalaman/shellcheck/releases/tag/v0.11.0).
SHELLCHECK_SHA_LINUX_X86_64=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
SHELLCHECK_SHA_LINUX_AARCH64=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
SHELLCHECK_SHA_DARWIN_X86_64=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6
SHELLCHECK_SHA_DARWIN_AARCH64=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79

fm_install_stub_uname() {
  local fakebin=$1
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${FM_TEST_UNAME_M:-x86_64}" ;;
  *) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
esac
SH
  chmod +x "$fakebin/uname"
}

fm_install_stub_curl_retry_once() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$CURL_COUNT" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$CURL_COUNT"
[ "$count" -gt 1 ] || exit 35
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    : > "$2"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fakebin/curl"
}

fm_install_stub_hasher() {
  local fakebin=$1
  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64|Linux-amd64)
    sum=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;;
  Linux-aarch64|Linux-arm64)
    sum=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;;
  Darwin-x86_64|Darwin-amd64)
    sum=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6 ;;
  Darwin-arm64|Darwin-aarch64)
    sum=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79 ;;
  *)
    echo "fm-install-shellcheck.test.sh: unknown platform $(uname -s)-$(uname -m)" >&2
    exit 1 ;;
esac
printf '%s  %s\n' "$sum" "$1"
SH
  chmod +x "$fakebin/sha256sum"
}

fm_install_stub_tar_shellcheck() {
  local fakebin=$1
  cat > "$fakebin/tar" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "-C" ]; then
    mkdir -p "\$2/shellcheck-v${REQUIRED}"
    cat > "\$2/shellcheck-v${REQUIRED}/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
EOF
    chmod +x "\$2/shellcheck-v${REQUIRED}/shellcheck"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fakebin/tar"
}

fm_install_stub_sleep() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

fm_install_shellcheck_fakebin() {
  local tmp=$1 fakebin
  fakebin=$(fm_fakebin "$tmp")
  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl_retry_once "$fakebin"
  fm_install_stub_hasher "$fakebin"
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"
  printf '%s\n' "$fakebin"
}

test_retries_and_installs_pinned_shellcheck() {
  local tmp fakebin destination output
  tmp=$(fm_test_tmproot fm-install-shellcheck)
  fakebin=$(fm_install_shellcheck_fakebin "$tmp")
  destination="$tmp/bin"

  output=$(CURL_COUNT="$tmp/curl-count" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not recover from a transient download failure\n$output"
  [ "$(cat "$tmp/curl-count")" -eq 2 ] \
    || fail "installer did not retry exactly once after recovery"
  assert_contains "$output" "download attempt 1 failed; retrying" \
    "installer did not disclose its retry"
  [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck"
  assert_contains "$("$destination/shellcheck" --version)" "version: $REQUIRED" \
    "installed executable did not report the pinned version"
  pass "fm-install-shellcheck retries and installs the pinned executable"
}

test_maps_all_supported_platform_checksums() {
  local tmp fakebin destination out url_log uname_s uname_m archive sha
  tmp=$(fm_test_tmproot fm-install-shellcheck-platforms)
  fakebin=$(fm_install_shellcheck_fakebin "$tmp")
  destination="$tmp/bin"
  url_log="$tmp/curl-url.log"

  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
url=
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
[ -z "${CURL_URL_LOG:-}" ] || printf '%s\n' "$url" >> "$CURL_URL_LOG"
: > "$out"
exit 0
SH
  chmod +x "$fakebin/curl"

  while IFS=$'\t' read -r uname_s uname_m archive sha; do
    [ -n "$uname_s" ] || continue
    rm -rf "$destination"
    : > "$url_log"
    out=$(CURL_URL_LOG="$url_log" FM_TEST_UNAME_S="$uname_s" FM_TEST_UNAME_M="$uname_m" \
      PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
      || fail "installer failed for ${uname_s}/${uname_m}\n$out"
    assert_contains "$(cat "$url_log")" "$archive" \
      "installer did not download $archive for ${uname_s}/${uname_m}"
    [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck for ${uname_s}/${uname_m}"
  done <<EOF
Linux	x86_64	shellcheck-v${REQUIRED}.linux.x86_64.tar.xz	$SHELLCHECK_SHA_LINUX_X86_64
Linux	amd64	shellcheck-v${REQUIRED}.linux.x86_64.tar.xz	$SHELLCHECK_SHA_LINUX_X86_64
Linux	aarch64	shellcheck-v${REQUIRED}.linux.aarch64.tar.xz	$SHELLCHECK_SHA_LINUX_AARCH64
Linux	arm64	shellcheck-v${REQUIRED}.linux.aarch64.tar.xz	$SHELLCHECK_SHA_LINUX_AARCH64
Darwin	x86_64	shellcheck-v${REQUIRED}.darwin.x86_64.tar.xz	$SHELLCHECK_SHA_DARWIN_X86_64
Darwin	amd64	shellcheck-v${REQUIRED}.darwin.x86_64.tar.xz	$SHELLCHECK_SHA_DARWIN_X86_64
Darwin	arm64	shellcheck-v${REQUIRED}.darwin.aarch64.tar.xz	$SHELLCHECK_SHA_DARWIN_AARCH64
Darwin	aarch64	shellcheck-v${REQUIRED}.darwin.aarch64.tar.xz	$SHELLCHECK_SHA_DARWIN_AARCH64
EOF
  pass "fm-install-shellcheck maps every supported OS/arch pair to its pinned digest"
}

test_rejects_unknown_platform_pairs() {
  local tmp fakebin destination out rc
  tmp=$(fm_test_tmproot fm-install-shellcheck-unknown)
  fakebin=$(fm_install_shellcheck_fakebin "$tmp")
  destination="$tmp/bin"

  rc=0
  out=$(FM_TEST_UNAME_S=FreeBSD FM_TEST_UNAME_M=amd64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an unsupported OS\n$out"
  assert_contains "$out" "unsupported platform" \
    "installer did not fail closed on an unknown OS/arch pair"
  assert_contains "$out" "FreeBSD-amd64" \
    "installer did not report the detected unknown pair"

  rc=0
  out=$(FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=ppc64le \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an unsupported architecture\n$out"
  assert_contains "$out" "unsupported platform" \
    "installer did not fail closed on linux/ppc64le"
  pass "fm-install-shellcheck refuses unknown OS/arch pairs before downloading"
}

test_retries_and_installs_pinned_shellcheck
test_maps_all_supported_platform_checksums
test_rejects_unknown_platform_pairs
