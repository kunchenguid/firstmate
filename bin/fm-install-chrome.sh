#!/usr/bin/env bash
# fm-install-chrome.sh - install CI's pinned, verified Chrome headless shell.
#
# Usage:
#   fm-install-chrome.sh <destination-directory>
set -eu

FM_CHROME_VERSION=153.0.8010.2
FM_CHROME_ARCHIVE=chrome-headless-shell-linux64.zip
FM_CHROME_SHA256=1b830648ab948e01e3324cba1430839194b034dbdeac738e41a2001fe81b042c
FM_CHROME_URL="https://storage.googleapis.com/chrome-for-testing-public/${FM_CHROME_VERSION}/linux64/${FM_CHROME_ARCHIVE}"
FM_CHROME_MAX_BYTES=180000000
FM_NSPR_PACKAGE=libnspr4_4.35-1.1build1_amd64.deb
FM_NSPR_SHA256=e579e72d091f6c7a13f5a756c31065b15aae5b81840d61b069355aa2283c07b4
FM_NSPR_URL="https://archive.ubuntu.com/ubuntu/pool/main/n/nspr/$FM_NSPR_PACKAGE"
FM_NSPR_MAX_BYTES=2000000
FM_NSS_PACKAGE=libnss3_3.98-1build1_amd64.deb
FM_NSS_SHA256=88247fe0db5cd4c273b7dd026d9ded4ff9ba828b62437d12a2f1c2abc29468d2
FM_NSS_URL="https://archive.ubuntu.com/ubuntu/pool/main/n/nss/$FM_NSS_PACKAGE"
FM_NSS_MAX_BYTES=3000000
FM_ATK_PACKAGE=libatk1.0-0t64_2.52.0-1build1_amd64.deb
FM_ATK_SHA256=42c5d4b00954f17c2c3c4b866844f691eb8b6d57bf08b59203e65f12dc84a4f9
FM_ATK_URL="https://archive.ubuntu.com/ubuntu/pool/main/a/at-spi2-core/$FM_ATK_PACKAGE"
FM_ATK_MAX_BYTES=1000000
FM_ATK_BRIDGE_PACKAGE=libatk-bridge2.0-0t64_2.52.0-1build1_amd64.deb
FM_ATK_BRIDGE_SHA256=22b7d47e3c0f7953a78d3cfd309d1b20771085de9220fbe610c0989b9e808c9b
FM_ATK_BRIDGE_URL="https://archive.ubuntu.com/ubuntu/pool/main/a/at-spi2-core/$FM_ATK_BRIDGE_PACKAGE"
FM_ATK_BRIDGE_MAX_BYTES=1000000
FM_X11_PACKAGE=libx11-6_1.8.7-1build1_amd64.deb
FM_X11_SHA256=397f84347476a3c5786b39f3ff6f0f82866eb3d8be6d2ad3efeadf019efe5b80
FM_X11_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libx11/$FM_X11_PACKAGE"
FM_X11_MAX_BYTES=3000000
FM_XCOMPOSITE_PACKAGE=libxcomposite1_0.4.5-1build2_amd64.deb
FM_XCOMPOSITE_SHA256=1e3d7e7b53149f6fff92e1fbf4203b61301ca4e251b2949a34bf788dd999621f
FM_XCOMPOSITE_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxcomposite/$FM_XCOMPOSITE_PACKAGE"
FM_XCOMPOSITE_MAX_BYTES=1000000
FM_XDAMAGE_PACKAGE=libxdamage1_1.1.6-1build1_amd64.deb
FM_XDAMAGE_SHA256=6891faf325e996ebd28ef53ebb9c043dc96f67327500490affc3e89d366d35ed
FM_XDAMAGE_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxdamage/$FM_XDAMAGE_PACKAGE"
FM_XDAMAGE_MAX_BYTES=1000000
FM_XEXT_PACKAGE=libxext6_1.3.4-1build2_amd64.deb
FM_XEXT_SHA256=45783969a9ece9d7b7b733b8c60981584c53c6bc5ee3b42d295d2f80d1285679
FM_XEXT_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxext/$FM_XEXT_PACKAGE"
FM_XEXT_MAX_BYTES=1000000
FM_XFIXES_PACKAGE=libxfixes3_6.0.0-2build1_amd64.deb
FM_XFIXES_SHA256=0ee1015cccd063249e01c0cd0bf45f513c8ac9a1e5e485070c12e69192455e4a
FM_XFIXES_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxfixes/$FM_XFIXES_PACKAGE"
FM_XRANDR_PACKAGE=libxrandr2_1.5.2-2build1_amd64.deb
FM_XRANDR_SHA256=f2955a5e594f5724b58ad241d9231ea191cb36574a0d5e5ca6b661cd41d6256d
FM_XRANDR_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxrandr/$FM_XRANDR_PACKAGE"
FM_XI_PACKAGE=libxi6_1.8.1-1build1_amd64.deb
FM_XI_SHA256=0ea7acb5e8a8ce4d6653b30e03a319bfe136db7bfb5ee7cad34c2aa1272ea8d9
FM_XI_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxi/$FM_XI_PACKAGE"
FM_XTST_PACKAGE=libxtst6_1.2.3-1.1build1_amd64.deb
FM_XTST_SHA256=632d74c760f0a4e844c499e7bc1eca4c709aa096fde783a7a6807604aef77545
FM_XTST_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxtst/$FM_XTST_PACKAGE"
FM_XKBCOMMON_PACKAGE=libxkbcommon0_1.6.0-1build1_amd64.deb
FM_XKBCOMMON_SHA256=2b9caeb423efb540296a1cb20b872cc630c23908407ecb5c1c787a617622d664
FM_XKBCOMMON_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxkbcommon/$FM_XKBCOMMON_PACKAGE"
FM_XKBCOMMON_X11_PACKAGE=libxkbcommon-x11-0_1.6.0-1build1_amd64.deb
FM_XKBCOMMON_X11_SHA256=3befe840ce612ddfc0998d8610c6eed295726722a78e75cd08520bbd75065a23
FM_XKBCOMMON_X11_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxkbcommon/$FM_XKBCOMMON_X11_PACKAGE"
FM_GBM_PACKAGE=libgbm1_24.0.5-1ubuntu1_amd64.deb
FM_GBM_SHA256=bffad21d2383429d6dbec8395ba8d8476a0ed69e7e0b1c3ef2f27da99211b200
FM_GBM_URL="https://archive.ubuntu.com/ubuntu/pool/main/m/mesa/$FM_GBM_PACKAGE"
FM_XCB_PACKAGE=libxcb1_1.15-1ubuntu2_amd64.deb
FM_XCB_SHA256=e1c6611d11ad7398326f1bf028afc34c3b14c51d917a3426b966ed4b9687fa58
FM_XCB_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxcb/$FM_XCB_PACKAGE"
FM_X11_XCB_PACKAGE=libx11-xcb1_1.8.7-1build1_amd64.deb
FM_X11_XCB_SHA256=7d0d357e47cd6e1042be34da1d37cea313420b000035e71e855087c8268ab127
FM_X11_XCB_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libx11/$FM_X11_XCB_PACKAGE"
FM_ALSA_PACKAGE=libasound2t64_1.2.11-1build2_amd64.deb
FM_ALSA_SHA256=c2f0caa30869876791ba349bef4907d5cfec47b8cfd1ae9889a05dce0feb7c39
FM_ALSA_URL="https://archive.ubuntu.com/ubuntu/pool/main/a/alsa-lib/$FM_ALSA_PACKAGE"
FM_ATSPI_PACKAGE=libatspi2.0-0t64_2.52.0-1build1_amd64.deb
FM_ATSPI_SHA256=d686ace4080eca9c2d6ce8de69392a5ac56c846701894c0858922d4ce341a1d7
FM_ATSPI_URL="https://archive.ubuntu.com/ubuntu/pool/main/a/at-spi2-core/$FM_ATSPI_PACKAGE"
FM_XRENDER_PACKAGE=libxrender1_0.9.10-1.1build1_amd64.deb
FM_XRENDER_SHA256=d70bd831aebe8d4834b5dd2ed98df26dd6bd27f1042c47543bd7f66df1ae22ea
FM_XRENDER_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxrender/$FM_XRENDER_PACKAGE"
FM_WAYLAND_SERVER_PACKAGE=libwayland-server0_1.22.0-2.1build1_amd64.deb
FM_WAYLAND_SERVER_SHA256=edbfa4b6857691ae922cc768a753fab230eee9e956aa2ce4f2eaa8d9ad777dca
FM_WAYLAND_SERVER_URL="https://archive.ubuntu.com/ubuntu/pool/main/w/wayland/$FM_WAYLAND_SERVER_PACKAGE"
FM_WAYLAND_CLIENT_PACKAGE=libwayland-client0_1.22.0-2.1build1_amd64.deb
FM_WAYLAND_CLIENT_SHA256=6af0aed41d75149bea22fa468f01eb058ffe3e35ef07ff2f13fb88a90387881d
FM_WAYLAND_CLIENT_URL="https://archive.ubuntu.com/ubuntu/pool/main/w/wayland/$FM_WAYLAND_CLIENT_PACKAGE"
FM_XCB_RANDR_PACKAGE=libxcb-randr0_1.15-1ubuntu2_amd64.deb
FM_XCB_RANDR_SHA256=b5cb519823a05a617b543dc9b6a9289b7648b20048244abe021caa706309835a
FM_XCB_RANDR_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxcb/$FM_XCB_RANDR_PACKAGE"
FM_XCB_IMAGE_PACKAGE=libxcb-image0_0.4.0-2build1_amd64.deb
FM_XCB_IMAGE_SHA256=6af300eeef5523aa0d8dbfab3a23c1fe7006ecc19f8abdc5c636d734d7bb5287
FM_XCB_IMAGE_URL="https://archive.ubuntu.com/ubuntu/pool/main/x/xcb-util-image/$FM_XCB_IMAGE_PACKAGE"
FM_XCB_KEYSYMS_PACKAGE=libxcb-keysyms1_0.4.0-1build4_amd64.deb
FM_XCB_KEYSYMS_SHA256=6c261aae923175b88a032018c530873ffb40f2bf96b045fdda42bd8bc74cb1c3
FM_XCB_KEYSYMS_URL="https://archive.ubuntu.com/ubuntu/pool/main/x/xcb-util-keysyms/$FM_XCB_KEYSYMS_PACKAGE"
FM_XCB_RENDER_UTIL_PACKAGE=libxcb-render-util0_0.3.9-1build4_amd64.deb
FM_XCB_RENDER_UTIL_SHA256=95d895ceb921e38e4edd85555b407b1a0564d8ad097ec7566e261764ce27787b
FM_XCB_RENDER_UTIL_URL="https://archive.ubuntu.com/ubuntu/pool/main/x/xcb-util-renderutil/$FM_XCB_RENDER_UTIL_PACKAGE"
FM_XCB_SHM_PACKAGE=libxcb-shm0_1.15-1ubuntu2_amd64.deb
FM_XCB_SHM_SHA256=229d1280d459f1ba44c22939d3f9b61d9d20932d9a646b3fe4ce50be4cdf2325
FM_XCB_SHM_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxcb/$FM_XCB_SHM_PACKAGE"
FM_XCB_SYNC_PACKAGE=libxcb-sync1_1.15-1ubuntu2_amd64.deb
FM_XCB_SYNC_SHA256=14286795a258593259923619073e50c15345673befae2733f7b0577b07359aa8
FM_XCB_SYNC_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxcb/$FM_XCB_SYNC_PACKAGE"
FM_XCB_XFIXES_PACKAGE=libxcb-xfixes0_1.15-1ubuntu2_amd64.deb
FM_XCB_XFIXES_SHA256=0b2ab64af92a71e3d1a35e3c819880ee28d04bfac81360df68ae8d8e9663ebd2
FM_XCB_XFIXES_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxcb/$FM_XCB_XFIXES_PACKAGE"
FM_XAU_PACKAGE=libxau6_1.0.9-1build6_amd64.deb
FM_XAU_SHA256=e40d29f1d1a62393bacaedebe0da3d9006084152a9f7e5e029293f08ce1c5c80
FM_XAU_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxau/$FM_XAU_PACKAGE"
FM_XDMCP_PACKAGE=libxdmcp6_1.1.3-0ubuntu6_amd64.deb
FM_XDMCP_SHA256=bcd336fce11ce2a45f34d0f95e6980af22529f22147e8f98c156e5cee8ee42bb
FM_XDMCP_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxdmcp/$FM_XDMCP_PACKAGE"

die() {
  printf 'fm-install-chrome.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-chrome.sh <destination-directory>}
mkdir -p "$DESTINATION/chrome-cache"
archive="$DESTINATION/chrome-cache/$FM_CHROME_ARCHIVE"
download_attempts=3

if [ ! -f "$archive" ]; then
  attempt=1
  while ! curl -fsSL --max-filesize "$FM_CHROME_MAX_BYTES" "$FM_CHROME_URL" -o "$archive"; do
    [ "$attempt" -lt "$download_attempts" ] || die "download failed after $download_attempts attempts"
    printf 'fm-install-chrome.sh: download attempt %s failed; retrying\n' "$attempt" >&2
    sleep "$attempt"
    attempt=$((attempt + 1))
  done
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha256=$(sha256sum "$archive" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
else
  die 'need sha256sum or shasum to verify the Chrome archive'
fi
[ "$actual_sha256" = "$FM_CHROME_SHA256" ] \
  || die "checksum mismatch for $FM_CHROME_ARCHIVE (expected $FM_CHROME_SHA256, got $actual_sha256)"

bundle="$DESTINATION/chrome-headless-shell-linux64"
python3 - "$archive" "$DESTINATION" <<'PY'
import pathlib
import sys
import zipfile

archive = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(archive) as source:
    source.extractall(destination)
browser = destination / "chrome-headless-shell-linux64" / "chrome-headless-shell"
browser.chmod(0o755)
PY
[ -f "$bundle/icudtl.dat" ] || die 'Chrome bundle is missing icudtl.dat'
real_browser="$bundle/chrome-headless-shell"
browser="$DESTINATION/chrome-headless-shell"

runtime_dirs=
runtime_dir="$DESTINATION/chrome-runtime"
mkdir -p "$runtime_dir"
nspr_package="$DESTINATION/chrome-cache/$FM_NSPR_PACKAGE"
if [ ! -f "$nspr_package" ]; then
  curl -fsSL --max-filesize "$FM_NSPR_MAX_BYTES" "$FM_NSPR_URL" -o "$nspr_package" \
    || die "download failed for pinned NSS package $FM_NSPR_PACKAGE"
fi
actual_nspr_sha256=$(sha256sum "$nspr_package" | awk '{print $1}')
[ "$actual_nspr_sha256" = "$FM_NSPR_SHA256" ] \
  || die "checksum mismatch for $FM_NSPR_PACKAGE (expected $FM_NSPR_SHA256, got $actual_nspr_sha256)"
dpkg-deb -x "$nspr_package" "$runtime_dir" \
  || die "could not extract pinned NSS package $FM_NSPR_PACKAGE"
[ -f "$runtime_dir/usr/lib/x86_64-linux-gnu/libnspr4.so" ] \
  || die "pinned NSS package did not provide libnspr4.so"
nss_package="$DESTINATION/chrome-cache/$FM_NSS_PACKAGE"
if [ ! -f "$nss_package" ]; then
  curl -fsSL --max-filesize "$FM_NSS_MAX_BYTES" "$FM_NSS_URL" -o "$nss_package" \
    || die "download failed for pinned NSS package $FM_NSS_PACKAGE"
fi
actual_nss_sha256=$(sha256sum "$nss_package" | awk '{print $1}')
[ "$actual_nss_sha256" = "$FM_NSS_SHA256" ] \
  || die "checksum mismatch for $FM_NSS_PACKAGE (expected $FM_NSS_SHA256, got $actual_nss_sha256)"
dpkg-deb -x "$nss_package" "$runtime_dir" \
  || die "could not extract pinned NSS package $FM_NSS_PACKAGE"
[ -f "$runtime_dir/usr/lib/x86_64-linux-gnu/libnss3.so" ] \
  || die "pinned NSS package did not provide libnss3.so"
atk_package="$DESTINATION/chrome-cache/$FM_ATK_PACKAGE"
if [ ! -f "$atk_package" ]; then
  curl -fsSL --max-filesize "$FM_ATK_MAX_BYTES" "$FM_ATK_URL" -o "$atk_package" \
    || die "download failed for pinned ATK package $FM_ATK_PACKAGE"
fi
actual_atk_sha256=$(sha256sum "$atk_package" | awk '{print $1}')
[ "$actual_atk_sha256" = "$FM_ATK_SHA256" ] \
  || die "checksum mismatch for $FM_ATK_PACKAGE (expected $FM_ATK_SHA256, got $actual_atk_sha256)"
dpkg-deb -x "$atk_package" "$runtime_dir" \
  || die "could not extract pinned ATK package $FM_ATK_PACKAGE"
[ -f "$runtime_dir/usr/lib/x86_64-linux-gnu/libatk-1.0.so.0" ] \
  || die "pinned ATK package did not provide libatk-1.0.so.0"
atk_bridge_package="$DESTINATION/chrome-cache/$FM_ATK_BRIDGE_PACKAGE"
if [ ! -f "$atk_bridge_package" ]; then
  curl -fsSL --max-filesize "$FM_ATK_BRIDGE_MAX_BYTES" "$FM_ATK_BRIDGE_URL" -o "$atk_bridge_package" \
    || die "download failed for pinned ATK bridge package $FM_ATK_BRIDGE_PACKAGE"
fi
actual_atk_bridge_sha256=$(sha256sum "$atk_bridge_package" | awk '{print $1}')
[ "$actual_atk_bridge_sha256" = "$FM_ATK_BRIDGE_SHA256" ] \
  || die "checksum mismatch for $FM_ATK_BRIDGE_PACKAGE (expected $FM_ATK_BRIDGE_SHA256, got $actual_atk_bridge_sha256)"
dpkg-deb -x "$atk_bridge_package" "$runtime_dir" \
  || die "could not extract pinned ATK bridge package $FM_ATK_BRIDGE_PACKAGE"
[ -f "$runtime_dir/usr/lib/x86_64-linux-gnu/libatk-bridge-2.0.so.0" ] \
  || die "pinned ATK bridge package did not provide libatk-bridge-2.0.so.0"
x11_package="$DESTINATION/chrome-cache/$FM_X11_PACKAGE"
if [ ! -f "$x11_package" ]; then
  curl -fsSL --max-filesize "$FM_X11_MAX_BYTES" "$FM_X11_URL" -o "$x11_package" \
    || die "download failed for pinned X11 package $FM_X11_PACKAGE"
fi
actual_x11_sha256=$(sha256sum "$x11_package" | awk '{print $1}')
[ "$actual_x11_sha256" = "$FM_X11_SHA256" ] \
  || die "checksum mismatch for $FM_X11_PACKAGE (expected $FM_X11_SHA256, got $actual_x11_sha256)"
dpkg-deb -x "$x11_package" "$runtime_dir" \
  || die "could not extract pinned X11 package $FM_X11_PACKAGE"
[ -f "$runtime_dir/usr/lib/x86_64-linux-gnu/libX11.so.6" ] \
  || die "pinned X11 package did not provide libX11.so.6"
xcomposite_package="$DESTINATION/chrome-cache/$FM_XCOMPOSITE_PACKAGE"
if [ ! -f "$xcomposite_package" ]; then
  curl -fsSL --max-filesize "$FM_XCOMPOSITE_MAX_BYTES" "$FM_XCOMPOSITE_URL" -o "$xcomposite_package" \
    || die "download failed for pinned X Composite package $FM_XCOMPOSITE_PACKAGE"
fi
actual_xcomposite_sha256=$(sha256sum "$xcomposite_package" | awk '{print $1}')
[ "$actual_xcomposite_sha256" = "$FM_XCOMPOSITE_SHA256" ] \
  || die "checksum mismatch for $FM_XCOMPOSITE_PACKAGE (expected $FM_XCOMPOSITE_SHA256, got $actual_xcomposite_sha256)"
dpkg-deb -x "$xcomposite_package" "$runtime_dir" \
  || die "could not extract pinned X Composite package $FM_XCOMPOSITE_PACKAGE"
[ -f "$runtime_dir/usr/lib/x86_64-linux-gnu/libXcomposite.so.1" ] \
  || die "pinned X Composite package did not provide libXcomposite.so.1"
xdamage_package="$DESTINATION/chrome-cache/$FM_XDAMAGE_PACKAGE"
if [ ! -f "$xdamage_package" ]; then
  curl -fsSL --max-filesize "$FM_XDAMAGE_MAX_BYTES" "$FM_XDAMAGE_URL" -o "$xdamage_package" \
    || die "download failed for pinned XDamage package $FM_XDAMAGE_PACKAGE"
fi
actual_xdamage_sha256=$(sha256sum "$xdamage_package" | awk '{print $1}')
[ "$actual_xdamage_sha256" = "$FM_XDAMAGE_SHA256" ] \
  || die "checksum mismatch for $FM_XDAMAGE_PACKAGE (expected $FM_XDAMAGE_SHA256, got $actual_xdamage_sha256)"
dpkg-deb -x "$xdamage_package" "$runtime_dir" \
  || die "could not extract pinned XDamage package $FM_XDAMAGE_PACKAGE"
[ -f "$runtime_dir/usr/lib/x86_64-linux-gnu/libXdamage.so.1" ] \
  || die "pinned XDamage package did not provide libXdamage.so.1"
xext_package="$DESTINATION/chrome-cache/$FM_XEXT_PACKAGE"
if [ ! -f "$xext_package" ]; then
  curl -fsSL --max-filesize "$FM_XEXT_MAX_BYTES" "$FM_XEXT_URL" -o "$xext_package" \
    || die "download failed for pinned Xext package $FM_XEXT_PACKAGE"
fi
actual_xext_sha256=$(sha256sum "$xext_package" | awk '{print $1}')
[ "$actual_xext_sha256" = "$FM_XEXT_SHA256" ] \
  || die "checksum mismatch for $FM_XEXT_PACKAGE (expected $FM_XEXT_SHA256, got $actual_xext_sha256)"
dpkg-deb -x "$xext_package" "$runtime_dir" \
  || die "could not extract pinned Xext package $FM_XEXT_PACKAGE"
[ -f "$runtime_dir/usr/lib/x86_64-linux-gnu/libXext.so.6" ] \
  || die "pinned Xext package did not provide libXext.so.6"
install_extra_package() {
  local package=$1 expected_sha256=$2 url=$3 required_library package_path actual_sha256
  required_library=$4
  package_path="$DESTINATION/chrome-cache/$package"
  if [ ! -f "$package_path" ]; then
    curl -fsSL --max-filesize 1000000 "$url" -o "$package_path" \
      || die "download failed for pinned runtime package $package"
  fi
  actual_sha256=$(sha256sum "$package_path" | awk '{print $1}')
  [ "$actual_sha256" = "$expected_sha256" ] \
    || die "checksum mismatch for $package (expected $expected_sha256, got $actual_sha256)"
  dpkg-deb -x "$package_path" "$runtime_dir" \
    || die "could not extract pinned runtime package $package"
  [ -f "$runtime_dir/usr/lib/x86_64-linux-gnu/$required_library" ] \
    || die "pinned runtime package $package did not provide $required_library"
}
install_extra_package "$FM_XFIXES_PACKAGE" "$FM_XFIXES_SHA256" "$FM_XFIXES_URL" libXfixes.so.3
install_extra_package "$FM_XRANDR_PACKAGE" "$FM_XRANDR_SHA256" "$FM_XRANDR_URL" libXrandr.so.2
install_extra_package "$FM_XI_PACKAGE" "$FM_XI_SHA256" "$FM_XI_URL" libXi.so.6
install_extra_package "$FM_XTST_PACKAGE" "$FM_XTST_SHA256" "$FM_XTST_URL" libXtst.so.6
install_extra_package "$FM_XKBCOMMON_PACKAGE" "$FM_XKBCOMMON_SHA256" "$FM_XKBCOMMON_URL" libxkbcommon.so.0
install_extra_package "$FM_XKBCOMMON_X11_PACKAGE" "$FM_XKBCOMMON_X11_SHA256" "$FM_XKBCOMMON_X11_URL" libxkbcommon-x11.so.0
install_extra_package "$FM_GBM_PACKAGE" "$FM_GBM_SHA256" "$FM_GBM_URL" libgbm.so.1
install_extra_package "$FM_XCB_PACKAGE" "$FM_XCB_SHA256" "$FM_XCB_URL" libxcb.so.1
install_extra_package "$FM_X11_XCB_PACKAGE" "$FM_X11_XCB_SHA256" "$FM_X11_XCB_URL" libX11-xcb.so.1
install_extra_package "$FM_ALSA_PACKAGE" "$FM_ALSA_SHA256" "$FM_ALSA_URL" libasound.so.2
install_extra_package "$FM_ATSPI_PACKAGE" "$FM_ATSPI_SHA256" "$FM_ATSPI_URL" libatspi.so.0
install_extra_package "$FM_XRENDER_PACKAGE" "$FM_XRENDER_SHA256" "$FM_XRENDER_URL" libXrender.so.1
install_extra_package "$FM_WAYLAND_SERVER_PACKAGE" "$FM_WAYLAND_SERVER_SHA256" "$FM_WAYLAND_SERVER_URL" libwayland-server.so.0
install_extra_package "$FM_WAYLAND_CLIENT_PACKAGE" "$FM_WAYLAND_CLIENT_SHA256" "$FM_WAYLAND_CLIENT_URL" libwayland-client.so.0
install_extra_package "$FM_XCB_RANDR_PACKAGE" "$FM_XCB_RANDR_SHA256" "$FM_XCB_RANDR_URL" libxcb-randr.so.0
install_extra_package "$FM_XCB_IMAGE_PACKAGE" "$FM_XCB_IMAGE_SHA256" "$FM_XCB_IMAGE_URL" libxcb-image.so.0
install_extra_package "$FM_XCB_KEYSYMS_PACKAGE" "$FM_XCB_KEYSYMS_SHA256" "$FM_XCB_KEYSYMS_URL" libxcb-keysyms.so.1
install_extra_package "$FM_XCB_RENDER_UTIL_PACKAGE" "$FM_XCB_RENDER_UTIL_SHA256" "$FM_XCB_RENDER_UTIL_URL" libxcb-render-util.so.0
install_extra_package "$FM_XCB_SHM_PACKAGE" "$FM_XCB_SHM_SHA256" "$FM_XCB_SHM_URL" libxcb-shm.so.0
install_extra_package "$FM_XCB_SYNC_PACKAGE" "$FM_XCB_SYNC_SHA256" "$FM_XCB_SYNC_URL" libxcb-sync.so.1
install_extra_package "$FM_XCB_XFIXES_PACKAGE" "$FM_XCB_XFIXES_SHA256" "$FM_XCB_XFIXES_URL" libxcb-xfixes.so.0
install_extra_package "$FM_XAU_PACKAGE" "$FM_XAU_SHA256" "$FM_XAU_URL" libXau.so.6
install_extra_package "$FM_XDMCP_PACKAGE" "$FM_XDMCP_SHA256" "$FM_XDMCP_URL" libXdmcp.so.6
runtime_dirs="$runtime_dir/usr/lib/x86_64-linux-gnu:$runtime_dir"
# The generated wrapper must expand LD_LIBRARY_PATH when it runs, not here.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nexport LD_LIBRARY_PATH="%s\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"\n' \
  "$runtime_dirs" >"$browser"
cat >>"$browser" <<SH
exec "$real_browser" "\$@"
SH
chmod 0755 "$browser"

python3 - "$browser" <<'PY'
import subprocess
import sys

browser = sys.argv[1]
try:
    result = subprocess.run(
        [browser, "--headless=new", "--disable-gpu", "--no-sandbox", "--dump-dom", "about:blank"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
except subprocess.CalledProcessError as error:
    detail = (error.stderr or "").strip()
    print(f"fm-install-chrome.sh: headless launch probe failed: {error}{': ' + detail if detail else ''}", file=sys.stderr)
    raise SystemExit(1)
except (OSError, subprocess.SubprocessError) as error:
    print(f"fm-install-chrome.sh: headless launch probe failed: {error}", file=sys.stderr)
    raise SystemExit(1)
if "<html" not in result.stdout:
    print("fm-install-chrome.sh: headless launch probe returned no HTML", file=sys.stderr)
    raise SystemExit(1)
PY

printf '%s\n' "$browser"
