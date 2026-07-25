#!/usr/bin/env bash
# Render the single completion-report prompt contract shared by ship briefs and
# managed continuation prompts.
# The durable publication and storage contract lives in docs/report-stack.md.

fm_completion_report_contract() {  # <data-dir> <task-id>
  local data=$1 task=$2
  printf '%s\n' \
    '# Completion report' \
    "Before the final \`done:\` status, write \`$data/$task/completion.md\` with these six sections, each as a LEVEL-TWO markdown heading spelled exactly: \`## Summary\`, \`## What changed\`, \`## Verification\`, \`## Visual evidence\`, \`## Artifacts\`, \`## Follow-ups\`." \
    'Publication rejects the report if any of those headings is missing, spelled differently, or written at another level - a level-one `# Summary` fails. Each section needs substantive prose directly under it; if you use sub-headings inside a section, make them `###` so they nest rather than ending the section.' \
    'When a section genuinely does not apply, say so in a sentence under the heading rather than omitting the heading.' \
    'Make it stand alone for the captain: explain the outcome, name important files or links, record the validation performed, and call out remaining risk or decisions.' \
    "Put screenshots, diagrams, or other visual artifacts under \`$data/$task/visuals/\` and reference them from the report when they materially help review." \
    "If review or the no-mistakes pipeline changes the implementation after the report is first written, refresh the report before the later final \`done:\` status." \
    'These completion-report paths and the status file are the only authorized writes outside the worktree.'
}

fm_completion_report_contract_present() {  # <brief>
  fm_completion_report_contract_file present "$1"
}

fm_completion_report_contract_ensure() (  # <data-dir> <task-id> <brief>
  local data=$1 task=$2 brief=$3 data_real task_real brief_parent brief_target
  local contract

  data_real=$(cd "$data" 2>/dev/null && pwd -P) || {
    echo "error: completion-report data directory is unavailable: $data" >&2
    return 1
  }
  task_real=$(cd "$data/$task" 2>/dev/null && pwd -P) || {
    echo "error: completion-report task directory is unavailable: $data/$task" >&2
    return 1
  }
  if [ "$task_real" != "$data_real/$task" ]; then
    echo "error: completion-report task directory must resolve directly inside $data_real: $data/$task" >&2
    return 1
  fi
  brief_parent=$(cd "$(dirname "$brief")" 2>/dev/null && pwd -P) || {
    echo "error: task brief parent is unavailable: $brief" >&2
    return 1
  }
  brief_target="$task_real/$(basename "$brief")"
  if [ "$brief_parent" != "$task_real" ] || [ -L "$brief_target" ] || [ ! -f "$brief_target" ]; then
    echo "error: task brief must be a real regular file inside $task_real: $brief" >&2
    return 1
  fi
  contract=$(fm_completion_report_contract "$data" "$task") || return 1
  FM_COMPLETION_REPORT_CONTRACT=$contract fm_completion_report_contract_file ensure "$brief_target" "$data_real" "$task"
)

fm_completion_report_contract_file() {  # <present|ensure> <brief> [data-dir] [task-id]
  local lib_dir
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  FM_MARKDOWN_STRUCTURE_LIB="$lib_dir/fm-markdown-structure.cjs" \
    FM_FILE_TRANSACTION_LIB="$lib_dir/fm-file-transaction.cjs" \
    node - "$1" "$2" "${3:-}" "${4:-}" <<'JS'
const fs = require('fs');
const path = require('path');
const { markdownStructure } = require(process.env.FM_MARKDOWN_STRUCTURE_LIB);
const { pinnedTaskFileTransaction } = require(process.env.FM_FILE_TRANSACTION_LIB);

const action = process.argv[2];
const brief = process.argv[3];
const dataDir = process.argv[4];
const taskId = process.argv[5];

function contractPresent(markdown) {
  return markdownStructure(markdown).some(({ heading }) => heading?.level === 1 && heading.content === 'Completion report');
}

try {
  if (action === 'present') {
    const entry = fs.lstatSync(brief, { bigint: true });
    if (entry.isSymbolicLink() || !entry.isFile()) throw new Error('source is not a regular file');
    const source = fs.openSync(brief,
      fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    try {
      const stat = fs.fstatSync(source, { bigint: true });
      if (!stat.isFile() || stat.dev !== entry.dev || stat.ino !== entry.ino) {
        throw new Error('source changed while opening');
      }
      process.exitCode = contractPresent(fs.readFileSync(source).toString('utf8')) ? 0 : 1;
    } finally {
      fs.closeSync(source);
    }
  } else if (action === 'ensure') {
    const contract = process.env.FM_COMPLETION_REPORT_CONTRACT;
    if (!contract) throw new Error('completion-report contract is empty');
    if (!dataDir || !taskId) throw new Error('completion-report task identity is incomplete');
    pinnedTaskFileTransaction(dataDir, taskId, path.basename(brief), (content) => {
      if (contractPresent(content.toString('utf8'))) return undefined;
      return Buffer.concat([content, Buffer.from(`\n${contract}\n`)]);
    });
  } else {
    throw new Error(`unknown completion-report brief action: ${action}`);
  }
} catch (error) {
  console.error(`error: completion-report brief transaction failed for ${brief}: ${error.message}`);
  process.exitCode = 1;
}
JS
}
