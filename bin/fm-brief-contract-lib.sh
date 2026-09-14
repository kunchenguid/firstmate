#!/usr/bin/env bash

fm_brief_contract_value() {  # <brief-path> <prefix>
  awk -v prefix="$2" '
    $0 == "<!-- fm-generated-contract-boundary -->" && !boundary_seen {
      boundary_seen=1
      marked=0
      in_contract=0
      value=""
      next
    }
    $0 == "<!-- fm-generated-contract -->" && !marked && !contract_done {
      marked=1
      in_contract=1
      signature=1
      value=""
      next
    }
    $0 == "<!-- fm-generated-contract-end -->" && marked {
      in_contract=0
      contract_done=1
      next
    }
    !marked && !legacy_anchor && ($0 == "# Project memory" || $0 == "# Firstmate instruction inbox") {
      legacy_anchor=1
      next
    }
    !marked && legacy_anchor && !in_contract && !legacy_complete && $0 == "# Definition of done" {
      in_contract=1
      signature=0
      value=""
      next
    }
    in_contract && !marked && !signature {
      if ($0 ~ /^Delivery contract: mode=/ || $0 ~ /^Write your findings to /) {
        signature=1
        legacy_complete=1
        next
      }
      if ($0 ~ /^#/) {
        in_contract=0
        next
      }
      next
    }
    in_contract && marked && $0 == "# Definition of done" { next }
    in_contract && $0 ~ /^#/ {
      in_contract=0
      next
    }
    in_contract && signature && index($0, prefix) == 1 { value=substr($0, length(prefix) + 1) }
    END { if (value != "") print value }
  ' "$1"
}

fm_brief_crew_branch() {  # <brief-path>
  fm_brief_contract_value "$1" 'Crew branch: branch='
}
