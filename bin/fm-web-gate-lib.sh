#!/usr/bin/env bash

fm_web_gate_contract() {
  printf '%s\n' 'Web gate contract: custom-domain/interceptor/revision-marker/screenshot'
}

fm_web_gate_body_text() {
  cat <<'EOF'
## Website deployment completion gate
This is a website or web-deployment ship task, so the task is not complete until firstmate can accept all of the following evidence together:
- Verify the deployed revision against the real custom production domain, never only on a preview or staging URL.
- Perform fresh-browser visual verification with the existing Interceptor skill: run `interceptor open <custom-production-domain>` and inspect the actual rendered page, not a headless or CDP shortcut.
- Confirm that the rendered page visibly contains concrete distinguishing revision content - a marker introduced by this change - and record the exact marker checked.
- Capture screenshot evidence of that verified custom-domain page with the existing Interceptor screenshot mechanism, and preserve the screenshot as durable task or PR evidence.
- Explicitly record the custom production URL, marker, and screenshot evidence before reporting done.
HTTP 200, a preview URL, or bare reachability alone is explicitly rejected as insufficient acceptance evidence.
Do not append a done status or claim completion when any visual, marker, custom-domain, or screenshot evidence is missing.
EOF
}

fm_web_gate_unfenced_text() {
  awk '
    /^```/ { fenced = !fenced; next }
    !fenced { print }
  ' "$1"
}

fm_web_gate_contract_count() {
  fm_web_gate_unfenced_text "$1" | grep -Fxc "$(fm_web_gate_contract)" || true
}

fm_web_gate_body_present() {
  local brief=$1 expected
  expected=$(fm_web_gate_body_text)
  fm_web_gate_unfenced_text "$brief" | awk -v expected="$expected" '
    BEGIN {
      wanted_count = split(expected, wanted, "\n")
      wanted_index = 1
      in_dod = 0
      found = 0
    }
    {
      if ($0 == "# Definition of done") {
        in_dod = 1
        next
      }
      if (in_dod && $0 == wanted[wanted_index]) {
        wanted_index++
        if (wanted_index > wanted_count) {
          found = 1
          exit
        }
        next
      }
      if (in_dod) exit 1
    }
    END { exit found ? 0 : 1 }
  ' "$brief"
}
