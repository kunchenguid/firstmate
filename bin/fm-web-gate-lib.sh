#!/usr/bin/env bash

fm_web_gate_contract() {
  printf '%s\n' 'Web gate contract: custom-domain/chrome-devtools-axi/revision-marker/screenshot'
}

fm_web_gate_provenance_placeholder() {
  printf '%s\n' 'Web gate provenance: surface=web sha256:pending'
}

fm_web_gate_body_text() {
  cat <<'EOF'
## Website deployment completion gate
This is a website or web-deployment ship task, so the task is not complete until firstmate can accept all of the following evidence together:
- Verify the deployed revision against the real custom production domain, never only on a preview or staging URL.
- Perform a fresh-page visual verification against the real custom production domain with the existing chrome-devtools-axi tool: run `chrome-devtools-axi open <custom-production-domain>`, render the page, and inspect the actual result, not a headless or CDP shortcut.
- Confirm that the rendered page visibly contains concrete distinguishing revision content - a marker introduced by this change - and record the exact marker checked.
- Capture screenshot evidence of that verified custom-domain page with `chrome-devtools-axi screenshot`, and preserve the screenshot as durable task or PR evidence.
- Explicitly record the custom production URL, marker, and screenshot evidence before reporting done.
HTTP 200, a preview URL, or bare reachability alone is explicitly rejected as insufficient acceptance evidence.
Do not append a done status or claim completion when any visual, marker, custom-domain, or screenshot evidence is missing.
EOF
}

fm_web_gate_hash_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  else
    return 1
  fi
}

fm_web_gate_body_hash() {
  fm_web_gate_body_text | fm_web_gate_hash_stream
}

fm_web_gate_body_present() {
  local brief=$1 expected
  expected=$(fm_web_gate_body_text)
  awk -v expected="$expected" '
    BEGIN {
      wanted_count = split(expected, wanted, "\n")
      wanted_index = 1
      matches = 0
    }
    {
      if ($0 == wanted[wanted_index]) {
        wanted_index++
        if (wanted_index > wanted_count) {
          matches++
          wanted_index = 1
        }
      } else if ($0 == wanted[1]) {
        wanted_index = 2
      } else {
        wanted_index = 1
      }
    }
    END { exit matches == 1 ? 0 : 1 }
  ' "$brief"
}

fm_web_gate_stamp_file() {
  local brief=$1 digest tmp
  digest=$(fm_web_gate_body_hash) || return 1
  tmp=$(mktemp "$brief.tmp.XXXXXX") || return 1
  if ! sed "s/^Web gate provenance: .*/Web gate provenance: surface=web sha256:$digest/" "$brief" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv "$tmp" "$brief"
}

fm_web_gate_provenance_present() {
  local brief=$1 count actual expected
  count=$(grep -Ec '^Web gate provenance: surface=web sha256:[0-9a-fA-F]{64}$' "$brief" || true)
  [ "$count" -eq 1 ] || return 1
  fm_web_gate_body_present "$brief" || return 1
  actual=$(sed -n 's/^Web gate provenance: //p' "$brief")
  expected=$(fm_web_gate_body_hash) || return 1
  [ "$actual" = "surface=web sha256:$expected" ]
}

fm_web_gate_surface_line_count() {
  grep -Ec '^Surface contract:' "$1" || true
}

fm_web_gate_surface_contract() {
  local brief=$1 count declared
  count=$(fm_web_gate_surface_line_count "$brief")
  if fm_web_gate_provenance_present "$brief"; then
    if [ "$count" -eq 0 ]; then
      printf '%s\n' web
      return 0
    fi
    [ "$count" -eq 1 ] || return 1
    declared=$(sed -n 's/^Surface contract: //p' "$brief")
    [ "$declared" = web ] || return 1
    printf '%s\n' web
    return 0
  fi
  [ "$count" -eq 1 ] || return 1
  declared=$(sed -n 's/^Surface contract: //p' "$brief")
  case "$declared" in
    web|non-web) printf '%s\n' "$declared" ;;
    *) return 1 ;;
  esac
}
