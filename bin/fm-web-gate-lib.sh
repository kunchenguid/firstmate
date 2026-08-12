#!/usr/bin/env bash

fm_web_gate_contract() {
  printf '%s\n' 'Web gate contract: custom-domain/interceptor/revision-marker/screenshot'
}

fm_web_gate_text() {
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

fm_web_gate_body_present() {
  local brief=$1 line
  while IFS= read -r line; do
    [ -z "$line" ] || grep -Fqx -- "$line" "$brief" || return 1
  done <<EOF
$(fm_web_gate_text)
EOF
}
