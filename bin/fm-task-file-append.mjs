#!/usr/bin/env node
import fs from "node:fs";
import transactionModule from "./fm-file-transaction.cjs";

const [dataDir, taskId, fileName, header = ""] = process.argv.slice(2);
if (!dataDir || !taskId || !fileName) {
  console.error("usage: fm-task-file-append.mjs <data-dir> <task-id> <file-name> [header]");
  process.exit(2);
}

try {
  const addition = fs.readFileSync(0);
  transactionModule.pinnedTaskFileTransaction(dataDir, taskId, fileName, (content, { existed }) => {
    const prefix = !existed && header ? Buffer.from(`${header}\n\n`) : Buffer.alloc(0);
    return Buffer.concat([content, prefix, addition]);
  });
} catch (error) {
  console.error(`error: task file transaction failed for ${taskId}/${fileName}: ${error.message}`);
  process.exit(1);
}
