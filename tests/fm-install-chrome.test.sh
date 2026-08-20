#!/usr/bin/env bash
# Contract tests for the pinned, verified Chrome headless-shell installer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-install-chrome)
FAKE_BIN="$TMP_ROOT/bin"
CALLS="$TMP_ROOT/calls"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
out=
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = -o ]; then
    i=$((i + 1))
    out=${!i}
  fi
done
printf '%s\n' "$*" >>"$FM_CHROME_TEST_CALLS"
printf 'fixture archive\n' >"$out"
SH

cat >"$FAKE_BIN/sha256sum" <<'SH'
#!/usr/bin/env bash
if [ "${FM_CHROME_TEST_BAD_SHA:-}" = 1 ]; then
  printf '%s  %s\n' bad "$1"
else
  case "$1" in
    *libnspr4_*.deb) printf '%s  %s\n' e579e72d091f6c7a13f5a756c31065b15aae5b81840d61b069355aa2283c07b4 "$1" ;;
    *libnss3_*.deb) printf '%s  %s\n' 88247fe0db5cd4c273b7dd026d9ded4ff9ba828b62437d12a2f1c2abc29468d2 "$1" ;;
    *libatk1.0-0t64_*.deb) printf '%s  %s\n' 42c5d4b00954f17c2c3c4b866844f691eb8b6d57bf08b59203e65f12dc84a4f9 "$1" ;;
    *libatk-bridge2.0-0t64_*.deb) printf '%s  %s\n' 22b7d47e3c0f7953a78d3cfd309d1b20771085de9220fbe610c0989b9e808c9b "$1" ;;
    *libx11-6_*.deb) printf '%s  %s\n' 397f84347476a3c5786b39f3ff6f0f82866eb3d8be6d2ad3efeadf019efe5b80 "$1" ;;
    *libxcomposite1_*.deb) printf '%s  %s\n' 1e3d7e7b53149f6fff92e1fbf4203b61301ca4e251b2949a34bf788dd999621f "$1" ;;
    *libxdamage1_*.deb) printf '%s  %s\n' 6891faf325e996ebd28ef53ebb9c043dc96f67327500490affc3e89d366d35ed "$1" ;;
    *libxext6_*.deb) printf '%s  %s\n' 45783969a9ece9d7b7b733b8c60981584c53c6bc5ee3b42d295d2f80d1285679 "$1" ;;
    *libxfixes3_*.deb) printf '%s  %s\n' 0ee1015cccd063249e01c0cd0bf45f513c8ac9a1e5e485070c12e69192455e4a "$1" ;;
    *libxrandr2_*.deb) printf '%s  %s\n' f2955a5e594f5724b58ad241d9231ea191cb36574a0d5e5ca6b661cd41d6256d "$1" ;;
    *libxi6_*.deb) printf '%s  %s\n' 0ea7acb5e8a8ce4d6653b30e03a319bfe136db7bfb5ee7cad34c2aa1272ea8d9 "$1" ;;
    *libxtst6_*.deb) printf '%s  %s\n' 632d74c760f0a4e844c499e7bc1eca4c709aa096fde783a7a6807604aef77545 "$1" ;;
    *libxkbcommon-x11-0_*.deb) printf '%s  %s\n' 3befe840ce612ddfc0998d8610c6eed295726722a78e75cd08520bbd75065a23 "$1" ;;
    *libxkbcommon0_*.deb) printf '%s  %s\n' 2b9caeb423efb540296a1cb20b872cc630c23908407ecb5c1c787a617622d664 "$1" ;;
    *libgbm1_*.deb) printf '%s  %s\n' bffad21d2383429d6dbec8395ba8d8476a0ed69e7e0b1c3ef2f27da99211b200 "$1" ;;
    *libxcb1_*.deb) printf '%s  %s\n' e1c6611d11ad7398326f1bf028afc34c3b14c51d917a3426b966ed4b9687fa58 "$1" ;;
    *libx11-xcb1_*.deb) printf '%s  %s\n' 7d0d357e47cd6e1042be34da1d37cea313420b000035e71e855087c8268ab127 "$1" ;;
    *libasound2t64_*.deb) printf '%s  %s\n' c2f0caa30869876791ba349bef4907d5cfec47b8cfd1ae9889a05dce0feb7c39 "$1" ;;
    *libatspi2.0-0t64_*.deb) printf '%s  %s\n' d686ace4080eca9c2d6ce8de69392a5ac56c846701894c0858922d4ce341a1d7 "$1" ;;
    *libxrender1_*.deb) printf '%s  %s\n' d70bd831aebe8d4834b5dd2ed98df26dd6bd27f1042c47543bd7f66df1ae22ea "$1" ;;
    *libwayland-server0_*.deb) printf '%s  %s\n' edbfa4b6857691ae922cc768a753fab230eee9e956aa2ce4f2eaa8d9ad777dca "$1" ;;
    *libwayland-client0_*.deb) printf '%s  %s\n' 6af0aed41d75149bea22fa468f01eb058ffe3e35ef07ff2f13fb88a90387881d "$1" ;;
    *libxcb-randr0_*.deb) printf '%s  %s\n' b5cb519823a05a617b543dc9b6a9289b7648b20048244abe021caa706309835a "$1" ;;
    *libxcb-image0_*.deb) printf '%s  %s\n' 6af300eeef5523aa0d8dbfab3a23c1fe7006ecc19f8abdc5c636d734d7bb5287 "$1" ;;
    *libxcb-keysyms1_*.deb) printf '%s  %s\n' 6c261aae923175b88a032018c530873ffb40f2bf96b045fdda42bd8bc74cb1c3 "$1" ;;
    *libxcb-render-util0_*.deb) printf '%s  %s\n' 95d895ceb921e38e4edd85555b407b1a0564d8ad097ec7566e261764ce27787b "$1" ;;
    *libxcb-shm0_*.deb) printf '%s  %s\n' 229d1280d459f1ba44c22939d3f9b61d9d20932d9a646b3fe4ce50be4cdf2325 "$1" ;;
    *libxcb-sync1_*.deb) printf '%s  %s\n' 14286795a258593259923619073e50c15345673befae2733f7b0577b07359aa8 "$1" ;;
    *libxcb-xfixes0_*.deb) printf '%s  %s\n' 0b2ab64af92a71e3d1a35e3c819880ee28d04bfac81360df68ae8d8e9663ebd2 "$1" ;;
    *libxau6_*.deb) printf '%s  %s\n' e40d29f1d1a62393bacaedebe0da3d9006084152a9f7e5e029293f08ce1c5c80 "$1" ;;
    *libxdmcp6_*.deb) printf '%s  %s\n' bcd336fce11ce2a45f34d0f95e6980af22529f22147e8f98c156e5cee8ee42bb "$1" ;;
    *) printf '%s  %s\n' 1b830648ab948e01e3324cba1430839194b034dbdeac738e41a2001fe81b042c "$1" ;;
  esac
fi
SH

cat >"$FAKE_BIN/dpkg-deb" <<'SH'
#!/usr/bin/env bash
mkdir -p "$3/usr/lib/x86_64-linux-gnu"
: >"$3/usr/lib/x86_64-linux-gnu/libnspr4.so"
: >"$3/usr/lib/x86_64-linux-gnu/libnss3.so"
: >"$3/usr/lib/x86_64-linux-gnu/libatk-1.0.so.0"
: >"$3/usr/lib/x86_64-linux-gnu/libatk-bridge-2.0.so.0"
: >"$3/usr/lib/x86_64-linux-gnu/libX11.so.6"
: >"$3/usr/lib/x86_64-linux-gnu/libXcomposite.so.1"
: >"$3/usr/lib/x86_64-linux-gnu/libXdamage.so.1"
: >"$3/usr/lib/x86_64-linux-gnu/libXext.so.6"
: >"$3/usr/lib/x86_64-linux-gnu/libXfixes.so.3"
: >"$3/usr/lib/x86_64-linux-gnu/libXrandr.so.2"
: >"$3/usr/lib/x86_64-linux-gnu/libXi.so.6"
: >"$3/usr/lib/x86_64-linux-gnu/libXtst.so.6"
: >"$3/usr/lib/x86_64-linux-gnu/libxkbcommon.so.0"
: >"$3/usr/lib/x86_64-linux-gnu/libxkbcommon-x11.so.0"
: >"$3/usr/lib/x86_64-linux-gnu/libgbm.so.1"
: >"$3/usr/lib/x86_64-linux-gnu/libxcb.so.1"
: >"$3/usr/lib/x86_64-linux-gnu/libX11-xcb.so.1"
: >"$3/usr/lib/x86_64-linux-gnu/libasound.so.2"
: >"$3/usr/lib/x86_64-linux-gnu/libatspi.so.0"
: >"$3/usr/lib/x86_64-linux-gnu/libXrender.so.1"
: >"$3/usr/lib/x86_64-linux-gnu/libwayland-server.so.0"
: >"$3/usr/lib/x86_64-linux-gnu/libwayland-client.so.0"
: >"$3/usr/lib/x86_64-linux-gnu/libxcb-randr.so.0"
: >"$3/usr/lib/x86_64-linux-gnu/libxcb-image.so.0"
: >"$3/usr/lib/x86_64-linux-gnu/libxcb-keysyms.so.1"
: >"$3/usr/lib/x86_64-linux-gnu/libxcb-render-util.so.0"
: >"$3/usr/lib/x86_64-linux-gnu/libxcb-shm.so.0"
: >"$3/usr/lib/x86_64-linux-gnu/libxcb-sync.so.1"
: >"$3/usr/lib/x86_64-linux-gnu/libxcb-xfixes.so.0"
: >"$3/usr/lib/x86_64-linux-gnu/libXau.so.6"
: >"$3/usr/lib/x86_64-linux-gnu/libXdmcp.so.6"
SH

cat >"$FAKE_BIN/python3" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 3 ]; then
  bundle=$3/chrome-headless-shell-linux64
  mkdir -p "$bundle"
  printf '#!/usr/bin/env bash\ncase "$*" in *--version*) echo "Google Chrome for Testing 153.0.8010.2" ;; *) echo "<html></html>" ;; esac\n' >"$bundle/chrome-headless-shell"
  : >"$bundle/icudtl.dat"
  chmod +x "$bundle/chrome-headless-shell"
  exit 0
fi
"$2" --headless=new --disable-gpu --no-sandbox --dump-dom about:blank | grep -Fq '<html'
SH
chmod +x "$FAKE_BIN"/*

test_installs_pinned_browser_and_reuses_verified_archive() {
  local destination="$TMP_ROOT/tools" output
  assert_not_contains "$(cat "$ROOT/bin/fm-install-chrome.sh")" 'find /snap' \
    "installer must not sweep host snap files"
  output=$(PATH="$FAKE_BIN:$PATH" FM_CHROME_TEST_CALLS="$CALLS" \
    "$ROOT/bin/fm-install-chrome.sh" "$destination") \
    || fail "pinned Chrome fixture installation failed"
  [ -x "$output" ] || fail "installer did not return an executable browser"
  assert_contains "$(cat "$CALLS")" '153.0.8010.2/linux64/chrome-headless-shell-linux64.zip' \
    "installer did not request the pinned Chrome-for-Testing URL"
  assert_contains "$(cat "$CALLS")" 'libnss3_3.98-1build1_amd64.deb' \
    "installer did not request the pinned NSS runtime package"
  assert_contains "$(cat "$CALLS")" 'libatk1.0-0t64_2.52.0-1build1_amd64.deb' \
    "installer did not request the pinned ATK runtime package"
  assert_contains "$(cat "$CALLS")" 'libatk-bridge2.0-0t64_2.52.0-1build1_amd64.deb' \
    "installer did not request the pinned ATK bridge runtime package"
  assert_contains "$(cat "$CALLS")" 'libx11-6_1.8.7-1build1_amd64.deb' \
    "installer did not request the pinned X11 runtime package"
  assert_contains "$(cat "$CALLS")" 'libxcomposite1_0.4.5-1build2_amd64.deb' \
    "installer did not request the pinned X Composite runtime package"
  assert_contains "$(cat "$CALLS")" 'libxdamage1_1.1.6-1build1_amd64.deb' \
    "installer did not request the pinned XDamage runtime package"
  assert_contains "$(cat "$CALLS")" 'libxext6_1.3.4-1build2_amd64.deb' \
    "installer did not request the pinned Xext runtime package"

  : >"$CALLS"
  PATH="$FAKE_BIN:$PATH" FM_CHROME_TEST_CALLS="$CALLS" \
    "$ROOT/bin/fm-install-chrome.sh" "$destination" >/dev/null \
    || fail "verified Chrome cache reuse failed"
  [ ! -s "$CALLS" ] || fail "verified archive cache was downloaded again"
  pass "Chrome installer uses a pinned, checksummed archive and verifies launchability"
}

test_rejects_checksum_mismatch() {
  local destination="$TMP_ROOT/bad" out rc=0
  out=$(PATH="$FAKE_BIN:$PATH" FM_CHROME_TEST_CALLS="$CALLS" FM_CHROME_TEST_BAD_SHA=1 \
    "$ROOT/bin/fm-install-chrome.sh" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted a checksum mismatch"
  assert_contains "$out" 'checksum mismatch' "checksum refusal did not name the failure"
  [ ! -x "$destination/chrome-headless-shell" ] \
    || fail "checksum mismatch installed a browser"
  pass "Chrome installer refuses an unverified archive before installation"
}

test_installs_pinned_browser_and_reuses_verified_archive
test_rejects_checksum_mismatch
