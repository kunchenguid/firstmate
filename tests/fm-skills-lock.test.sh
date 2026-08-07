#!/usr/bin/env bash
# Verify every locked skill against its vendored directory using the canonical
# skills CLI folder hash: regular files only, recursively excluding .git and
# node_modules, relative paths normalized to forward slashes and locale-sorted,
# then SHA-256 over each path immediately followed by its raw file bytes.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$ROOT" <<'NODE'
const { createHash } = require('node:crypto');
const { readdir, readFile } = require('node:fs/promises');
const { join, relative } = require('node:path');

const root = process.argv[2];

async function collectFiles(baseDir, currentDir, results) {
  const entries = await readdir(currentDir, { withFileTypes: true });
  await Promise.all(entries.map(async (entry) => {
    const fullPath = join(currentDir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === '.git' || entry.name === 'node_modules') return;
      await collectFiles(baseDir, fullPath, results);
    } else if (entry.isFile()) {
      results.push({
        relativePath: relative(baseDir, fullPath).split('\\').join('/'),
        content: await readFile(fullPath),
      });
    }
  }));
}

async function computeSkillFolderHash(skillDir) {
  const files = [];
  await collectFiles(skillDir, skillDir, files);
  files.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
  const hash = createHash('sha256');
  for (const file of files) {
    hash.update(file.relativePath);
    hash.update(file.content);
  }
  return hash.digest('hex');
}

async function main() {
  const lock = JSON.parse(await readFile(join(root, 'skills-lock.json'), 'utf8'));
  const entries = Object.entries(lock.skills || {});
  if (entries.length === 0) throw new Error('skills-lock.json has no locked skills');

  const mismatches = [];
  for (const [name, entry] of entries) {
    const skillDir = join(root, '.agents', 'skills', name);
    let actual;
    try {
      actual = await computeSkillFolderHash(skillDir);
    } catch (error) {
      mismatches.push(`${name}: cannot hash vendored directory: ${error.message}`);
      continue;
    }
    if (entry.computedHash !== actual) {
      mismatches.push(`${name}: lock=${entry.computedHash} vendored=${actual}`);
    }
  }

  if (mismatches.length > 0) {
    throw new Error(`vendored skill lock mismatch:\n${mismatches.join('\n')}`);
  }
  console.log(`ok - skills lock: ${entries.length} vendored directory hashes match`);
}

main().catch((error) => {
  console.error(`not ok - ${error.message}`);
  process.exit(1);
});
NODE
