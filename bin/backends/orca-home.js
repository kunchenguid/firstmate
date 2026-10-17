#!/usr/bin/env node
// Persistent Orca home receipts and strict JSON validation. Called by orca.sh.
// Receipts under <home>/state/orca-registrations survive child task cleanup.
// A pending receipt never grants ownership; an unknown mutation stays pending
// for explicit reconciliation. Only an observed new registration is removable.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const [op, ...args] = process.argv.slice(2);
function refuse(message) { throw new Error(message); }
function readJSON(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }
function input() { return JSON.parse(fs.readFileSync(0, 'utf8')); }
function result(data) {
  if (data.ok !== true || !data.result) refuse('Orca response is not an authoritative success');
  return data.result;
}
function atom(value) { return typeof value === 'string' && /^[A-Za-z0-9._@%+-]+$/.test(value); }
function canonical(value) { return fs.realpathSync(value); }
function homeDir(home) {
  if (/[\t\r\n]/.test(home) || canonical(home) !== home || !fs.lstatSync(path.join(home, '.fm-secondmate-home')).isFile())
    refuse('not a canonical seeded secondmate home');
  const state = path.join(home, 'state');
  if (canonical(state) !== state) refuse('unsafe secondmate state directory');
  const dir = path.join(state, 'orca-registrations');
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, {mode: 0o700});
  if (canonical(dir) !== dir) refuse('unsafe Orca registration directory');
  return dir;
}
function receiptPath(home, project) {
  if (/[\t\r\n]/.test(project) || canonical(project) !== project || (project !== home && !project.startsWith(home + '/projects/')))
    refuse('Orca registration is outside the seeded home');
  return path.join(homeDir(home), crypto.createHash('sha256').update(project).digest('hex') + '.json');
}
function write(file, data) {
  if (fs.existsSync(file) && fs.lstatSync(file).isSymbolicLink()) refuse('symbolic-link receipt');
  const temp = file + '.' + process.pid;
  fs.writeFileSync(temp, JSON.stringify(data) + '\n', {mode: 0o600, flag: 'wx'});
  fs.renameSync(temp, file);
}
function receipt(home, project) {
  const file = receiptPath(home, project);
  if (!fs.existsSync(file)) return null;
  if (!fs.lstatSync(file).isFile() || fs.lstatSync(file).isSymbolicLink()) refuse('unsafe receipt');
  const r = readJSON(file);
  if (r.home !== home || r.path !== project || !['pending', 'ready', 'releasing', 'released'].includes(r.state)) refuse('invalid receipt binding');
  if (r.state !== 'pending' && (!atom(r.repo) || !atom(r.setup) || r.worktree !== r.repo + '::' + project || typeof r.owned !== 'boolean'))
    refuse('invalid registration identity');
  return r;
}
function rootWorkspace(data, project, repo) {
  const w = result(data).worktree;
  if (!w || w.path !== project || w.repoId !== repo || w.id !== repo + '::' + project ||
      w.isMainWorktree !== true) refuse('Orca root workspace identity mismatch');
  return w;
}
function terminals(data, workspace) {
  const r = result(data);
  if (!Array.isArray(r.terminals) || r.truncated !== false || r.totalCount !== r.terminals.length ||
      !r.hostScope || !Array.isArray(r.hostScope.omittedHostIds) || r.hostScope.omittedHostIds.length)
    refuse('incomplete Orca terminal inventory');
  const seen = new Set();
  for (const t of r.terminals) {
    if (!atom(t.handle) || t.worktreeId !== workspace || seen.has(t.handle)) refuse('ambiguous terminal binding');
    seen.add(t.handle);
  }
  return r.terminals;
}
try {
  let value = '';
  const [home, project] = args;
  switch (op) {
    case 'missing': {
      const d = input();
      if (d.ok !== false || d.error?.code !== 'repo_not_found') refuse('registration lookup is uncertain');
      break;
    }
    case 'receipt': {
      const r = receipt(home, project);
      if (r && r.state !== 'ready') refuse('unfinished Orca registration; reconcile the retained receipt before retrying');
      value = r ? r.repo : '';
      break;
    }
    case 'pending':
      if (receipt(home, project)) refuse('existing registration receipt');
      write(receiptPath(home, project), {home, path: project, state: 'pending'});
      break;
    case 'record': {
      const [,, repo, ownership, setup] = args;
      if (!atom(setup)) refuse('invalid Orca setup identity');
      const w = rootWorkspace(input(), project, repo);
      write(receiptPath(home, project), {home, path: project, state: 'ready', repo,
        setup, worktree: w.id, owned: ownership === 'owned'});
      value = repo;
      break;
    }
    case 'setup': {
      const [project, repo] = args;
      const r = result(input());
      if (!Array.isArray(r.setups)) refuse('missing Orca setup inventory');
      const matches = r.setups.filter(s => s.path === project);
      if (matches.length !== 1 || !atom(matches[0].id) || matches[0].repoId !== repo ||
          matches[0].hostId !== 'local' || matches[0].setupState !== 'ready')
        refuse('Orca project setup identity mismatch');
      value = matches[0].id;
      break;
    }
    case 'worker-label': {
      homeDir(home);
      const id = fs.readFileSync(path.join(home, '.fm-secondmate-home'), 'utf8').trim();
      if (!/^[A-Za-z0-9_-]+$/.test(id) || !project || /[\r\n\t]/.test(project))
        refuse('invalid secondmate worker label');
      value = `2ndmate-${id} · ${project}`;
      break;
    }
    case 'worker-workspace': {
      const [workspace, label] = args;
      const w = result(input()).worktree;
      if (!w || w.id !== workspace || w.displayName !== label ||
          w.parentWorktreeId !== null || w.lineage !== null)
        refuse('Orca worker label or independent placement was not confirmed');
      break;
    }
    case 'worker-terminal': {
      const [workspace, terminal, label] = args;
      const t = result(input()).terminal;
      if (!t || t.handle !== terminal || t.worktreeId !== workspace || t.title !== label)
        refuse('Orca worker terminal label was not confirmed');
      break;
    }
    case 'workspace': {
      const r = receipt(home, project);
      if (!r || !['ready', 'releasing'].includes(r.state)) refuse('missing persistent Orca workspace receipt');
      const w = rootWorkspace(input(), project, r.repo);
      if (args[2] !== r.setup) refuse('Orca setup identity changed');
      value = w.id;
      break;
    }
    case 'terminal-state': {
      const [workspace, terminal] = args;
      value = terminals(input(), workspace).some(t => t.handle === terminal) ? 'present' : 'absent';
      break;
    }
    case 'empty':
      if (terminals(input(), args[0]).length) refuse('Orca workspace still has terminals');
      break;
    case 'registrations': {
      const dir = homeDir(home);
      for (const file of fs.readdirSync(dir).sort()) {
        if (!file.endsWith('.json')) refuse('unfinished registration receipt write');
        const r = readJSON(path.join(dir, file));
        const verified = receipt(home, r.path);
        if (!verified || receiptPath(home, r.path) !== path.join(dir, file) || verified.state === 'pending') refuse('unfinished registration');
        if (verified.state !== 'released') value += [r.path, r.repo, r.setup, r.worktree, r.owned ? 'owned' : 'reused', r.state].join('\t') + '\n';
      }
      break;
    }
    case 'root-only': {
      const r = result(input());
      if (!Array.isArray(r.worktrees) || r.truncated !== false || r.totalCount !== r.worktrees.length ||
          r.worktrees.length !== 1 || r.worktrees[0].id !== args[0] || r.worktrees[0].isMainWorktree !== true)
        refuse('Orca registration still has worktrees or its inventory is incomplete');
      break;
    }
    case 'releasing':
    case 'released': {
      const r = receipt(home, project);
      if (!r || !['ready', 'releasing'].includes(r.state) || !r.owned) refuse('registration is not owned');
      write(receiptPath(home, project), {...r, state: op});
      break;
    }
    default: refuse('unknown Orca home operation');
  }
  process.stdout.write(value);
} catch (error) {
  console.error('error: ' + error.message);
  process.exitCode = 1;
}
