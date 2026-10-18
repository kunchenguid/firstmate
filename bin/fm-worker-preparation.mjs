#!/usr/bin/env node
// Internal owner for fm-brief's typed worker selection and fm-spawn's prepared
// role/skill bodies. No runtime discovery, model call or shell/YAML execution.
// select [--worker-role ROLE.md] [--skill SKILL.md]... [--skill-root DIR]...
//   emits validated selection JSON; roots default to ~/.agents/skills.
// prepare <selection.json> <provenance.json> emits initial-input Markdown and
//   atomically records canonical sources, SHA-256 and role/independent origins.
// Metadata uses the canonical role subset: top-level name/description scalars,
// autoloadSkills as a block or inline list of literal skill names. Unsupported
// binding syntax is rejected, never interpreted as YAML code or silently lost.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';

const slug = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
function check(ok, message) { if (!ok) throw new Error(message); }
function text(value) { return typeof value === 'string' && value.length > 0 && !/[\x00-\x1f\x7f]/.test(value); }
function file(source) {
  check(text(source), 'source path must be a nonempty single-line string');
  const real = fs.realpathSync(source);
  check(fs.statSync(real).isFile(), `${source}: expected readable regular file`);
  const content = fs.readFileSync(real, 'utf8');
  check(content.trim().length > 0 && !content.includes('\0'), `${source}: empty or invalid content`);
  return { path: real, content, sha256: crypto.createHash('sha256').update(content).digest('hex') };
}
function scalar(value, source) {
  value = value.trim();
  if (value.startsWith('"')) {
    try { value = JSON.parse(value); } catch { throw new Error(`${source}: malformed quoted scalar`); }
  } else if (value.startsWith("'")) {
    check(/^'(?:[^']|'')*'$/.test(value), `${source}: malformed quoted scalar`);
    value = value.slice(1, -1).replace(/''/g, "'");
  } else {
    value = value.replace(/\s+#.*$/, '').trim();
    check(!/^[!&*\[{|>]/.test(value), `${source}: unsupported metadata scalar`);
  }
  check(text(value), `${source}: expected nonempty literal string`);
  return value;
}
function metadata(source) {
  const lines = source.content.replace(/\r\n/g, '\n').split('\n');
  check(lines[0] === '---', `${source.path}: missing frontmatter`);
  const end = lines.indexOf('---', 1);
  check(end > 0, `${source.path}: unterminated frontmatter`);
  const fields = new Map();
  for (let i = 1; i < end; i++) {
    const line = lines[i];
    if (!line.trim() || /^\s*#/.test(line)) continue;
    const match = /^([A-Za-z][A-Za-z0-9_-]*):(?:\s+(.*))?$/.exec(line);
    check(match, `${source.path}:${i + 1}: malformed or unsupported frontmatter`);
    const [, key, initial = ''] = match;
    check(!fields.has(key), `${source.path}: duplicate metadata field ${key}`);
    const nested = [];
    while (i + 1 < end && /^\s+\S/.test(lines[i + 1])) nested.push(lines[++i]);
    fields.set(key, { initial, nested });
  }
  const name = fields.get('name');
  const description = fields.get('description');
  check(name && description, `${source.path}: name and description required`);
  check(!name.nested.length, `${source.path}: name must be a scalar`);
  const parsedName = scalar(name.initial, source.path);
  // Descriptions may be YAML block strings; they are not binding input.
  check(description.initial.trim().length > 0, `${source.path}: description required`);
  const binding = fields.get('autoloadSkills');
  let associations = [];
  if (binding) {
    let value = binding.initial.replace(/\s+#.*$/, '').trim();
    if (value) {
      check(!binding.nested.length && /^\[.*\]$/.test(value), `${source.path}: autoloadSkills must be a literal list`);
      value = value.slice(1, -1).trim();
      associations = value ? value.split(',').map(item => scalar(item, `${source.path}: autoloadSkills`)) : [];
    } else {
      check(binding.nested.length > 0, `${source.path}: autoloadSkills must be a list, not null`);
      associations = binding.nested.map(line => {
        const match = /^\s+-\s+(.+)$/.exec(line);
        check(match, `${source.path}: malformed autoloadSkills list`);
        return scalar(match[1], `${source.path}: autoloadSkills`);
      });
    }
    check(associations.every(name => slug.test(name)), `${source.path}: autoloadSkills contains an invalid skill name`);
  }
  return { name: parsedName, associations };
}
function validateSelection(selection) {
  check(selection && selection.version === 1 && (selection.role === null || text(selection.role)) &&
    Array.isArray(selection.skills) && selection.skills.every(text) &&
    Array.isArray(selection.skillRoots) && selection.skillRoots.length > 0 && selection.skillRoots.every(text),
  'invalid worker-selection.json contract');
  check([selection.role, ...selection.skills, ...selection.skillRoots].filter(Boolean).every(path.isAbsolute),
    'worker selection paths must be absolute');
}
function resolve(selection) {
  validateSelection(selection);
  let role = null;
  if (selection.role) {
    role = file(selection.role);
    const parent = path.basename(path.dirname(role.path));
    check(path.basename(role.path) === 'ROLE.md' && path.basename(path.dirname(path.dirname(role.path))) === 'roles' && slug.test(parent),
      `${selection.role}: expected canonical roles/<role>/ROLE.md (managed symlinks supported)`);
    Object.assign(role, metadata(role));
    check(role.name === `fm-${parent}`, `${role.path}: name must be fm-${parent}`);
  }
  // Name lookup uses configured roots in precedence order, never the visible
  // model catalogue: hidden skills and installed directory symlinks remain valid.
  function named(name) {
    for (const root of selection.skillRoots) {
      const candidate = path.join(root, name, 'SKILL.md');
      try { fs.lstatSync(path.dirname(candidate)); } catch (error) {
        if (error.code === 'ENOENT') continue;
        throw error;
      }
      const source = file(candidate);
      check(metadata(source).name === name, `${candidate}: skill name must match ${name}`);
      return { ...source, name };
    }
    throw new Error(`${role?.path ?? 'worker selection'}: cannot resolve skill '${name}' in ${selection.skillRoots.join(', ')}`);
  }
  const skills = new Map();
  function add(source, origin) {
    if (skills.has(source.path)) {
      const origins = skills.get(source.path).origins;
      if (!origins.includes(origin)) origins.push(origin);
    } else skills.set(source.path, { ...source, origins: [origin] });
  }
  for (const name of role?.associations ?? []) add(named(name), 'role');
  for (const selected of selection.skills) {
    const source = file(selected);
    check(path.basename(source.path) === 'SKILL.md', `${selected}: expected SKILL.md`);
    const { name } = metadata(source);
    check(slug.test(name), `${selected}: invalid skill name`);
    // Authorization is by an installed entry's canonical identity, not raw path
    // prefix: supported managed links may point outside the configured root.
    const allowed = named(name);
    check(allowed.path === source.path, `${selected}: skill is not the selected source in configured skill roots`);
    add({ ...source, name }, 'independent');
  }
  return { role, skills: [...skills.values()] };
}
function record({ content, ...source }) { return source; }
function render(prepared) {
  const parts = ['# Selected worker preparation',
    'FirstMate supplied these role and skill bodies before launch; this is prepared-input injection, not native OMP agent selection. Project instructions and applicable project-local skills take precedence over this selected role and shared skills. The current worker identity and task boundaries remain authoritative.'];
  if (prepared.role) parts.push(`## Selected role: ${prepared.role.name}\nSource: ${prepared.role.path}\n\n${prepared.role.content}`);
  for (const skill of prepared.skills) parts.push(`## Prepared skill: ${skill.name}\nSource: ${skill.path}\nResolve relative skill references from: ${path.dirname(skill.path)}\nOrigins: ${skill.origins.join(', ')}\n\n${skill.content}`);
  return `${parts.join('\n\n')}\n`;
}
try {
  const [command, ...args] = process.argv.slice(2);
  if (command === 'select') {
    const selection = { version: 1, role: null, skills: [], skillRoots: [] };
    for (let i = 0; i < args.length; i += 2) {
      const flag = args[i], value = args[i + 1];
      check(text(value) && !value.startsWith('--'), `${flag}: missing value`);
      const absolute = path.resolve(value);
      if (flag === '--worker-role') {
        check(selection.role === null, '--worker-role may be supplied only once');
        selection.role = absolute;
      } else if (flag === '--skill') selection.skills.push(absolute);
      else if (flag === '--skill-root') selection.skillRoots.push(absolute);
      else throw new Error(`unknown worker selection flag ${flag}`);
    }
    if (!selection.skillRoots.length) selection.skillRoots.push(path.join(os.homedir(), '.agents/skills'));
    resolve(selection);
    console.log(JSON.stringify(selection, null, 2));
  } else if (command === 'prepare') {
    check(args.length === 2, 'prepare requires selection and provenance paths');
    const prepared = resolve(JSON.parse(fs.readFileSync(args[0], 'utf8')));
    const manifest = { version: 1, mechanism: 'firstmate-prepared-input', role: prepared.role ? record(prepared.role) : null, skills: prepared.skills.map(record) };
    const temp = `${args[1]}.${process.pid}.tmp`;
    try {
      fs.writeFileSync(temp, `${JSON.stringify(manifest, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
      fs.renameSync(temp, args[1]);
    } finally { if (fs.existsSync(temp)) fs.unlinkSync(temp); }
    process.stdout.write(render(prepared));
  } else throw new Error('expected select or prepare');
} catch (error) {
  console.error(`error: worker preparation: ${error.message}`);
  process.exitCode = 1;
}
