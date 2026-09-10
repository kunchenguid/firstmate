#!/usr/bin/env bash

fm_brief_contract_value() {  # <brief-path> <prefix>
  awk -v prefix="$2" '
    $0 == "<!-- fm-generated-contract -->" { in_contract=1; value=""; next }
    in_contract && $0 == "# Definition of done" { next }
    in_contract && $0 ~ /^#/ { in_contract=0 }
    in_contract && index($0, prefix) == 1 { value=substr($0, length(prefix) + 1) }
    END { if (value != "") print value }
  ' "$1"
}

fm_brief_crew_branch() {  # <brief-path>
  fm_brief_contract_value "$1" 'Crew branch: branch='
}
