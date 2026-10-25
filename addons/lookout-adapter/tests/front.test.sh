#!/usr/bin/env bash
# Test for lookout-front and install.sh: a stub upstream and a fixture board url file; install.sh only in --dry-run, so no unit is touched.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'kill "${up:-}" "${fr:-}" 2>/dev/null || true; rm -rf -- "$t"' EXIT
mkdir -p "$t/up"; echo '{"fleet":{"lanes":[1]}}' > "$t/up/api"; echo up-ok > "$t/up/page"
echo "http://192.0.2.1:4420/?token=SECRET-TOKEN" > "$t/board.url"
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$t/up" > "$t/up.log" 2>&1 & up=$!
for _ in $(seq 50); do grep -q 'port' "$t/up.log" && break; sleep 0.1; done
upport="$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$t/up.log" | head -1)"
"$here/lookout-front" --upstream "http://127.0.0.1:$upport" --port 0 --board-url-file "$t/board.url" > "$t/front.log" & fr=$!
for _ in $(seq 50); do grep -q serving "$t/front.log" && break; sleep 0.1; done
base="$(sed 's|.*serving \(.*\)/|\1|' "$t/front.log")"
[ "$(curl -s "$base/page")" = up-ok ]
[ "$(curl -s -o /dev/null -w '%{http_code}' "$base/nope")" = 404 ]
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/comment")" = 405 ]
for r in tickets needs backlog measure overview; do
  out="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$base/$r")"
  [ "$out" = "301 http://192.0.2.1:4420/" ] || { echo "route $r: $out" >&2; exit 1; }
done
rm "$t/board.url"; [ "$(curl -s -o /dev/null -w '%{http_code}' "$base/tickets")" = 503 ]
kill "$up"; [ "$(curl -s -o /dev/null -w '%{http_code}' "$base/page")" = 502 ]
mkdir -p "$t/bin"; touch "$t/bin/lookout.js"
dry="$(LOOKOUT_DIR="$t" BIND=192.0.2.1 XDG_CONFIG_HOME="$t/cfg" "$here/install.sh" --dry-run)"
for want in 'ExecStart=.*fleet-serve --bind 192.0.2.1 --port 4390' 'systemd-run.*--port 4395' 'disable --now fm-dashboard.service' 'enable --now fm-dashboard-lookout.service'; do
  grep -q -- "$want" <<<"$dry" || { echo "dry run lacks: $want" >&2; exit 1; }
done
[ ! -e "$t/cfg" ] || { echo "dry run wrote a file" >&2; exit 1; }
rb="$(BIND=192.0.2.1 XDG_CONFIG_HOME="$t/cfg" "$here/install.sh" --rollback --dry-run)"
grep -q 'enable --now fm-dashboard.service' <<<"$rb" && grep -q 'disable --now fm-dashboard-lookout.service' <<<"$rb"
echo "lookout-front and install.sh: PASS"
