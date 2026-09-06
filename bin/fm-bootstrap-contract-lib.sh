#!/usr/bin/env bash
# fm-bootstrap-contract-lib.sh - single owner of a project's declared bootstrap
# contract discovery and its injection into a generated ship/scout brief.
#
# Sourced by bin/fm-brief.sh. Exists because a generated brief used to carry no
# structural link to a project's own mandatory read order at all: a live
# incident brief could scaffold with zero mentions of a project's declared
# continuity docs, so a worker never bootstrapped and the captain had to
# manually supply what the project's own documentation already said.
#
# A project opts in by adding one marker block to its own checked-in
# AGENTS.md (the project's real project-intrinsic knowledge file; see
# bin/fm-ensure-agents-md.sh), using the same firstmate:-prefixed
# HTML-comment-marker convention that file's own
# `<!-- firstmate:maintained-by-project -->` mark established:
#
#   <!-- firstmate:bootstrap-contract
#   <one or more lines: the mandatory read order and any evidence-first
#   incident rule every worker on this project must follow before starting
#   task work>
#   -->
#
# The opening line must be exactly `<!-- firstmate:bootstrap-contract`
# (trailing whitespace only) and the closing line exactly `-->`, each alone on
# its own line; only the first such block in the file is read, and everything
# between the two marker lines is copied into the brief verbatim.
#
# fm_brief_bootstrap_contract_block <projects-dir> <repo-name> <quoted-status-file>
# prints the ready-to-splice brief section on stdout when a contract is
# declared. The caller appends it directly after existing brief text with no
# separating template blank line, so the output opens with its own blank-line
# separator and carries no trailing blank line. It prints nothing and returns
# 0 when the project directory, its AGENTS.md, or the marker itself is absent
# - that silent-nothing case is what keeps a project declaring nothing
# byte-identical to a brief scaffolded before this contract existed.
# It fails closed - one "error:" line on stderr naming the file, return 1 -
# when AGENTS.md opens the marker but never closes it, or closes an empty
# block. Both are malformed declarations in the PROJECT's own AGENTS.md, and a
# brief that silently omitted them would recreate exactly the gap this owner
# exists to close; bin/fm-brief.sh propagates that failure rather than
# scaffolding a brief with the contract quietly missing.
# Ship and scout briefs take a single repo argument that this lookup resolves
# against `<projects-dir>/<repo-name>/AGENTS.md`; a secondmate charter's
# multi-project list is out of scope (AGENTS.md section 6 already routes
# secondmate project knowledge elsewhere), so bin/fm-brief.sh calls this only
# for ship/scout scaffolds.
fm_brief_bootstrap_contract_block() {  # <projects-dir> <repo-name> <quoted-status-file>
  local projects=$1 repo=$2 status_file=$3 agents body status
  agents="$projects/$repo/AGENTS.md"
  [ -f "$agents" ] || return 0
  body=$(awk '
    state == 1 && /^-->[[:space:]]*$/ { closed = 1; state = 0; next }
    state == 1 {
      print
      if ($0 ~ /[^[:space:]]/) has_content = 1
      next
    }
    !found && /^<!-- firstmate:bootstrap-contract[[:space:]]*$/ { state = 1; found = 1; next }
    END {
      if (found && !closed) exit 2
      if (found && closed && !has_content) exit 3
    }
  ' "$agents")
  status=$?
  case "$status" in
    0) ;;
    2)
      echo "error: $agents opens a firstmate:bootstrap-contract block with no closing \`-->\`; fix the project's AGENTS.md before a brief can include its declared bootstrap contract" >&2
      return 1 ;;
    3)
      echo "error: $agents declares an empty firstmate:bootstrap-contract block; add its mandatory read order and incident rule, or remove the marker" >&2
      return 1 ;;
    *)
      echo "error: $agents: could not parse its firstmate:bootstrap-contract block" >&2
      return 1 ;;
  esac
  [ -n "$body" ] || return 0
  cat <<EOF


# Project bootstrap contract
$agents declares a mandatory bootstrap contract for every worker on this project (a \`firstmate:bootstrap-contract\` block in its own AGENTS.md). Before investigating, diagnosing, or changing anything, read every document it names, in the order given, and follow its rule for incidents exactly as written:

$body

State which of the documents above you actually read as your very first status line for this task, before any other status append:
\`echo "working: bootstrapped, read {documents}" >> $status_file\`
EOF
}
