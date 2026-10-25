#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/.no-mistakes" "$T/bin"; printf 'keep: yes\n' > "$T/home/.no-mistakes/config.yaml"; cp "$T/home/.no-mistakes/config.yaml" "$T/original"
cat > "$T/bin/cp" <<'CP'
#!/usr/bin/env bash
/bin/cp "$@"
if [ -n "${MARKER:-}" ]; then
  for arg in "$@"; do case "$arg" in */.pi-quota-failover.*) touch "$MARKER"; while [ ! -e "$RELEASE" ]; do sleep 0.02; done ;; esac; done
fi
CP
chmod +x "$T/bin/cp"; E=(env HOME="$T/home" XDG_DATA_HOME="$T/data" PATH="$T/bin:$PATH")
"${E[@]}" "$A/install.sh" --home "$T/home/data" --config "$T/home/.no-mistakes/config.yaml" >/dev/null
cp "$T/home/data/pi-quota-failover" "$T/old-wrapper"; MARKER="$T/marker" RELEASE="$T/release" "${E[@]}" "$A/install.sh" --home "$T/home/data" --config "$T/home/.no-mistakes/config.yaml" >/dev/null & pid=$!
for _ in $(seq 1 200); do [ -e "$T/marker" ] && break; sleep 0.02; done
[ -e "$T/marker" ] && cmp -s "$T/old-wrapper" "$T/home/data/pi-quota-failover"; touch "$T/release"; wait "$pid"
"${E[@]}" "$A/uninstall.sh" --home "$T/home/data" --config "$T/home/.no-mistakes/config.yaml" >/dev/null
cmp -s "$T/original" "$T/home/.no-mistakes/config.yaml" && [ ! -e "$T/home/data/pi-quota-failover" ]; before=$(sha256sum "$T/home/.no-mistakes/config.yaml"); "${E[@]}" "$A/uninstall.sh" --home "$T/home/data" --config "$T/home/.no-mistakes/config.yaml" >/dev/null; [ "$before" = "$(sha256sum "$T/home/.no-mistakes/config.yaml")" ]; echo 'PASS pipeline-quota-failover atomic install and uninstall'
