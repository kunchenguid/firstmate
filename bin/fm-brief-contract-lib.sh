#!/usr/bin/env bash

fm_brief_crew_branch() {  # <brief-path>
  awk '
    $0 == "# Definition of done" && !started { started=1; in_contract=1; next }
    in_contract && $0 ~ /^#/ { in_contract=0 }
    in_contract && /^Crew branch: branch=/ {
      branch = $0
      sub(/^Crew branch: branch=/, "", branch)
    }
    END { if (branch != "") print branch }
  ' "$1"
}
