#!/usr/bin/env bash
# fm-install-herdr.test.sh - the pinned Herdr installer downloads from Herdr's
# current repository. A PATH curl stub records the requested URL and refuses
# the download, so nothing is fetched or installed.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-install-herdr)
FAKEBIN=$(fm_fakebin "$TMP")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in https://*) printf '%s\n' "$arg" > "$FM_CURL_URL_LOG" ;; esac
done
exit 22
SH
chmod +x "$FAKEBIN/curl"

code=0
FM_CURL_URL_LOG="$TMP/url" PATH="$FAKEBIN:$PATH" RUNNER_TEMP="$TMP" \
  bash "$ROOT/bin/fm-install-herdr.sh" "$TMP/dest" 2>"$TMP/err" || code=$?
[ "$code" -ne 0 ] || fail "installer succeeded although the download was refused"
[ -s "$TMP/url" ] || fail "installer requested no release URL: $(cat "$TMP/err")"
case "$(cat "$TMP/url")" in
  https://github.com/herdrdev/herdr/releases/download/v*/herdr-*) ;;
  *) fail "installer requested $(cat "$TMP/url"), not a herdrdev/herdr release asset" ;;
esac
[ ! -e "$TMP/dest/herdr" ] || fail "installer installed a binary after a refused download"
pass "installer downloads the pinned asset from herdrdev/herdr"
