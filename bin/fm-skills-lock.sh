#!/usr/bin/env bash
# Validate the vendored engineering-skill lock, Firstmate discovery paths, and
# optional upstream checkout against the pinned source revision.
#
# The default check is network-free and verifies the checked-in adapted skill
# directories, their shared Firstmate contract, and the .claude/skills discovery
# symlink.
# Directory hashes use a stable, length-delimited encoding of sorted paths and
# file contents so each filename is cryptographically bound to its bytes.
# --source-root additionally verifies one local checkout of the pinned upstream
# repository at the exact recorded revision, including every source directory
# hash.
#
# Test-only override:
#   FM_ROOT_OVERRIDE=<path>  validate another Firstmate-shaped fixture root.
#
# Usage: fm-skills-lock.sh [--source-root <checkout>] [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SOURCE_ROOT=""

usage() {
  cat <<'EOF'
Usage: fm-skills-lock.sh [--source-root <checkout>] [--help]

Verify Firstmate's vendored engineering-skill snapshot and discovery paths.

--source-root additionally verifies a local checkout of the pinned upstream
repository at the exact revision and directory hashes recorded in
skills-lock.json.

Test-only environment:
  FM_ROOT_OVERRIDE  Firstmate-shaped root to validate
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --source-root)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      SOURCE_ROOT=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

node - "$ROOT" "$SOURCE_ROOT" <<'NODE'
const { createHash } = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { lstat, readdir, readFile, realpath } = require('node:fs/promises');
const { isAbsolute, join, relative } = require('node:path');

const root = process.argv[2];
const sourceRoot = process.argv[3];
const hex40 = /^[0-9a-f]{40}$/;
const hex64 = /^[0-9a-f]{64}$/;
const skillName = /^[a-z0-9][a-z0-9-]*$/;

function fail(message) {
  throw new Error(message);
}

function safeRelativePath(value) {
  if (typeof value !== 'string' || value === '' || isAbsolute(value)) return false;
  const segments = value.split('/');
  return !segments.some((segment) => segment === '' || segment === '.' || segment === '..');
}

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

function updateDirectoryEntry(hash, relativePath, content) {
  const path = Buffer.from(relativePath, 'utf8');
  const length = Buffer.alloc(8);
  length.writeBigUInt64BE(BigInt(path.length));
  hash.update(length);
  hash.update(path);
  length.writeBigUInt64BE(BigInt(content.length));
  hash.update(length);
  hash.update(content);
}

async function directoryHash(directory) {
  const files = [];
  await collectFiles(directory, directory, files);
  files.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
  const hash = createHash('sha256');
  for (const file of files) {
    updateDirectoryEntry(hash, file.relativePath, file.content);
  }
  return hash.digest('hex');
}

async function fileHash(file) {
  return createHash('sha256').update(await readFile(file)).digest('hex');
}

function gitTreeHash(repository, revision, prefix) {
  const paths = execFileSync(
    'git',
    ['-C', repository, 'ls-tree', '-r', '--name-only', revision, '--', prefix],
    { encoding: 'utf8' },
  ).trim().split('\n').filter(Boolean).map((path) => ({
    path,
    relativePath: path.slice(prefix.length + 1),
  }));
  paths.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
  const hash = createHash('sha256');
  for (const file of paths) {
    updateDirectoryEntry(
      hash,
      file.relativePath,
      execFileSync('git', ['-C', repository, 'show', `${revision}:${file.path}`]),
    );
  }
  return hash.digest('hex');
}

async function main() {
  const lockPath = join(root, 'skills-lock.json');
  const lock = JSON.parse(await readFile(lockPath, 'utf8'));
  if (lock.version !== 3) fail(`unsupported skills lock version: ${lock.version}`);

  const sources = Object.entries(lock.sources || {});
  if (sources.length !== 1) fail('skills lock must declare exactly one pinned source');
  const [sourceName, source] = sources[0];
  if (source.sourceType !== 'github') fail(`${sourceName}: unsupported source type`);
  if (source.sourceUrl !== `https://github.com/${sourceName}.git`) {
    fail(`${sourceName}: source URL does not match its repository identity`);
  }
  if (!hex40.test(source.revision || '')) fail(`${sourceName}: invalid pinned revision`);
  if (source.capturedRef !== 'refs/heads/main') fail(`${sourceName}: unexpected captured ref`);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(source.capturedAt || '')) fail(`${sourceName}: invalid capture date`);
  if (!hex40.test(source.agentPluginsRevision || '')) {
    fail(`${sourceName}: invalid Agent Plugins compatibility revision`);
  }
  if (!safeRelativePath(source.agentPluginsSkillRoot)) {
    fail(`${sourceName}: invalid Agent Plugins skill root`);
  }
  const license = source.license || {};
  if (license.spdx !== 'MIT' || !safeRelativePath(license.sourcePath)
      || !safeRelativePath(license.vendoredPath) || !hex64.test(license.computedHash || '')) {
    fail(`${sourceName}: invalid source-license lock`);
  }
  if (await fileHash(join(root, license.vendoredPath)) !== license.computedHash) {
    fail(`${sourceName}: vendored source-license hash mismatch`);
  }

  const contract = lock.adaptationContract || {};
  if (!safeRelativePath(contract.path) || !hex64.test(contract.computedHash || '')) {
    fail('invalid Firstmate adaptation contract lock');
  }
  const contractPath = join(root, contract.path);
  if (await fileHash(contractPath) !== contract.computedHash) {
    fail('Firstmate adaptation contract hash mismatch');
  }

  const discoveryLink = join(root, '.claude', 'skills');
  if (!(await lstat(discoveryLink)).isSymbolicLink()) fail('.claude/skills is not a symlink');
  if (await realpath(discoveryLink) !== await realpath(join(root, '.agents', 'skills'))) {
    fail('.claude/skills does not resolve to .agents/skills');
  }

  const entries = Object.entries(lock.skills || {});
  if (entries.length === 0) fail('skills lock has no vendored skills');
  const sourcePaths = new Set();
  const mismatches = [];
  for (const [name, entry] of entries) {
    if (!skillName.test(name)) fail(`${name}: invalid skill name`);
    if (entry.source !== sourceName) fail(`${name}: unknown source ${entry.source}`);
    if (!safeRelativePath(entry.skillPath) || !entry.skillPath.endsWith('/SKILL.md')) {
      fail(`${name}: unsafe or invalid source skill path`);
    }
    if (sourcePaths.has(entry.skillPath)) fail(`${name}: duplicate source skill path`);
    sourcePaths.add(entry.skillPath);
    if (!hex64.test(entry.sourceHash || '')) fail(`${name}: invalid source hash`);
    if (!hex64.test(entry.computedHash || '')) fail(`${name}: invalid vendored hash`);

    const vendoredDir = join(root, '.agents', 'skills', name);
    const vendoredSkill = await readFile(join(vendoredDir, 'SKILL.md'), 'utf8');
    if (!/^---\n[\s\S]*?\nmetadata:\n  internal: true\n[\s\S]*?\n---\n/.test(vendoredSkill)) {
      mismatches.push(`${name}: missing metadata.internal=true`);
    }
    if (!vendoredSkill.includes('VENDORED-ENGINEERING-CONTRACT.md')) {
      mismatches.push(`${name}: missing Firstmate adaptation-contract pointer`);
    }
    const actual = await directoryHash(vendoredDir);
    if (entry.computedHash !== actual) {
      mismatches.push(`${name}: lock=${entry.computedHash} vendored=${actual}`);
    }
  }

  let sourceSummary = '';
  if (sourceRoot !== '') {
    let revision;
    try {
      revision = execFileSync('git', ['-C', sourceRoot, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
    } catch (error) {
      fail(`cannot read source checkout revision: ${error.message}`);
    }
    if (revision !== source.revision) {
      fail(`source checkout is ${revision}, expected ${source.revision}`);
    }
    if (await fileHash(join(sourceRoot, license.sourcePath)) !== license.computedHash) {
      mismatches.push(`${sourceName}: pinned source license differs from vendored notice`);
    }
    for (const [name, entry] of entries) {
      const sourceDir = join(sourceRoot, entry.skillPath.slice(0, -'/SKILL.md'.length));
      const actual = await directoryHash(sourceDir);
      if (entry.sourceHash !== actual) {
        mismatches.push(`${name}: source lock=${entry.sourceHash} checkout=${actual}`);
      }
      const pluginHash = gitTreeHash(
        sourceRoot,
        source.agentPluginsRevision,
        `${source.agentPluginsSkillRoot}/${name}`,
      );
      if (entry.sourceHash !== pluginHash) {
        mismatches.push(`${name}: Agent Plugins refactor changed pinned source bytes`);
      }
    }
    sourceSummary = `; upstream ${sourceName}@${source.revision.slice(0, 12)} verified; Agent Plugins ${source.agentPluginsRevision.slice(0, 12)} content-compatible`;
  }

  if (mismatches.length > 0) fail(`vendored skill lock mismatch:\n${mismatches.join('\n')}`);
  console.log(`ok - skills lock: ${entries.length} adapted skills and Firstmate discovery paths match${sourceSummary}`);
}

main().catch((error) => {
  console.error(`not ok - ${error.message}`);
  process.exit(1);
});
NODE
