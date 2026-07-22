#!/usr/bin/env node
// Strict parser and resolver for config/github-accounts.json.
// docs/configuration.md is the single full schema owner.
// This helper never reads credentials and emits only fixed, validated metadata fields.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const GENERIC_ERROR = "invalid GitHub account routing configuration";
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const codeRoot = path.resolve(scriptDir, "..");
const fmHomeInput = path.resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || codeRoot);
let fmHome = fmHomeInput;
try {
  fmHome = fs.realpathSync.native(fmHomeInput);
} catch (error) {
  if (error?.code !== "ENOENT") throw error;
}
const configPath = path.join(fmHome, "config", "github-accounts.json");
const projectsFile = path.resolve(process.env.FM_DATA_OVERRIDE || path.join(fmHome, "data"), "projects.md");

function fail(message = GENERIC_ERROR, code = 2) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(code);
}

class StrictJSONParser {
  constructor(text) {
    this.text = text;
    this.index = 0;
  }

  parse() {
    const value = this.value();
    this.space();
    if (this.index !== this.text.length) throw new Error("trailing data");
    return value;
  }

  space() {
    while (/\s/u.test(this.text[this.index] || "")) this.index += 1;
  }

  value() {
    this.space();
    const ch = this.text[this.index];
    if (ch === "{") return this.object();
    if (ch === "[") return this.array();
    if (ch === '"') return this.string();
    if (ch === "t" && this.text.slice(this.index, this.index + 4) === "true") {
      this.index += 4;
      return true;
    }
    if (ch === "f" && this.text.slice(this.index, this.index + 5) === "false") {
      this.index += 5;
      return false;
    }
    if (ch === "n" && this.text.slice(this.index, this.index + 4) === "null") {
      this.index += 4;
      return null;
    }
    if (ch === "-" || /[0-9]/u.test(ch || "")) return this.number();
    throw new Error("invalid value");
  }

  object() {
    this.index += 1;
    const result = Object.create(null);
    const seen = new Set();
    this.space();
    if (this.text[this.index] === "}") {
      this.index += 1;
      return result;
    }
    while (true) {
      this.space();
      if (this.text[this.index] !== '"') throw new Error("invalid object key");
      const key = this.string();
      const normalized = key.toLowerCase();
      if (seen.has(normalized)) throw new Error("duplicate key");
      seen.add(normalized);
      this.space();
      if (this.text[this.index] !== ":") throw new Error("missing colon");
      this.index += 1;
      result[key] = this.value();
      this.space();
      if (this.text[this.index] === "}") {
        this.index += 1;
        return result;
      }
      if (this.text[this.index] !== ",") throw new Error("missing comma");
      this.index += 1;
    }
  }

  array() {
    this.index += 1;
    const result = [];
    this.space();
    if (this.text[this.index] === "]") {
      this.index += 1;
      return result;
    }
    while (true) {
      result.push(this.value());
      this.space();
      if (this.text[this.index] === "]") {
        this.index += 1;
        return result;
      }
      if (this.text[this.index] !== ",") throw new Error("missing comma");
      this.index += 1;
    }
  }

  string() {
    const start = this.index;
    this.index += 1;
    while (this.index < this.text.length) {
      const ch = this.text[this.index];
      if (ch === '"') {
        this.index += 1;
        return JSON.parse(this.text.slice(start, this.index));
      }
      if (ch === "\\") {
        this.index += 2;
      } else {
        if (ch.charCodeAt(0) < 0x20) throw new Error("control in string");
        this.index += 1;
      }
    }
    throw new Error("unterminated string");
  }

  number() {
    const rest = this.text.slice(this.index);
    const match = rest.match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/u);
    if (!match) throw new Error("invalid number");
    this.index += match[0].length;
    const value = Number(match[0]);
    if (!Number.isFinite(value)) throw new Error("invalid number");
    return value;
  }
}

function object(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(value, allowed, required = allowed) {
  if (!object(value)) throw new Error("not object");
  const keys = Object.keys(value);
  for (const key of keys) if (!allowed.includes(key)) throw new Error("unknown field");
  for (const key of required) if (!Object.hasOwn(value, key)) throw new Error("missing field");
}

function singleLine(value, max = 256) {
  return typeof value === "string" && value.length > 0 && value.length <= max && !/[\u0000-\u001f\u007f]/u.test(value) && value.trim() === value;
}

function rejectCredentialStrings(value) {
  if (typeof value === "string") {
    if (/(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,})/u.test(value)) throw new Error("credential-shaped value");
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) rejectCredentialStrings(item);
    return;
  }
  if (object(value)) {
    for (const [key, item] of Object.entries(value)) {
      rejectCredentialStrings(key);
      rejectCredentialStrings(item);
    }
  }
}

function profileID(value) {
  return singleLine(value, 64) && /^[A-Za-z0-9][A-Za-z0-9._-]*$/u.test(value);
}

function projectName(value) {
  return singleLine(value, 100) && /^[A-Za-z0-9][A-Za-z0-9._-]*$/u.test(value);
}

function login(value) {
  return singleLine(value, 39) && /^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/u.test(value) && !value.includes("--");
}

function identity(value) {
  exactKeys(value, ["name", "email"]);
  if (!singleLine(value.name, 200) || !singleLine(value.email, 254) || !/^[^ <>\t@]+@[^ <>\t@]+$/u.test(value.email)) {
    throw new Error("invalid identity");
  }
}

function canonicalExecutable(value, basename) {
  if (!singleLine(value, 4096) || !path.isAbsolute(value) || path.basename(value) !== basename) throw new Error("invalid executable");
  const info = fs.statSync(value);
  if (!info.isFile() || (process.platform !== "win32" && (info.mode & 0o111) === 0)) throw new Error("invalid executable");
  const resolved = fs.realpathSync(value);
  if (!fs.statSync(resolved).isFile() || unsafeManagedPath(resolved)) throw new Error("invalid executable");
  return path.resolve(value);
}

function canonicalNamedExecutable(value, basename) {
  const executable = canonicalExecutable(value, basename);
  const resolved = fs.realpathSync.native(executable);
  if (path.basename(resolved) !== basename) throw new Error("invalid executable");
  return resolved;
}

function validateRepositoryGraphQL(query, nameVariable, suppliedOwner, suppliedName) {
  if (typeof query !== "string" || Buffer.byteLength(query, "utf8") > 16 * 1024 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(query)
    || !["name", "repo"].includes(nameVariable)) throw new Error("invalid GraphQL request");
  const tokens = query.match(/"(?:\\["\\/bfnrt]|\\u[0-9A-Fa-f]{4}|[^"\\\u0000-\u001f])*"|\$[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*|[!$():=@\[\]{|},]|\d+/gu);
  if (!tokens || tokens.join("") !== query.replace(/[ \t\r\n]/gu, "")) throw new Error("invalid GraphQL request");
  let index = 0;
  const take = (expected) => {
    if (tokens[index] !== expected) throw new Error("invalid GraphQL request");
    index += 1;
  };
  const readRepositoryValue = (variable, validator) => {
    const token = tokens[index];
    if (token === `$${variable}`) {
      index += 1;
      return null;
    }
    if (!token?.startsWith('"')) throw new Error("invalid GraphQL request");
    index += 1;
    const value = JSON.parse(token);
    if (!validator(value)) throw new Error("invalid GraphQL request");
    return value;
  };
  if (tokens[index] === "query") {
    take("query");
    if (tokens[index] === "(") {
      take("(");
      take("$owner");
      take(":");
      take("String");
      take("!");
      take(",");
      take(`$${nameVariable}`);
      take(":");
      take("String");
      take("!");
      take(")");
    }
  }
  take("{");
  take("repository");
  take("(");
  take("owner");
  take(":");
  const inlineOwner = readRepositoryValue("owner", login);
  take(",");
  take("name");
  take(":");
  const inlineName = readRepositoryValue(nameVariable, projectName);
  take(")");
  take("{");
  let selections = 0;
  while (tokens[index] !== "}") {
    const field = tokens[index];
    if (field === "id") {
      index += 1;
    } else if (field === "issues" || field === "pullRequests") {
      index += 1;
      if (tokens[index] === "(") {
        take("(");
        if (tokens[index] !== ")") {
          take("states");
          take(":");
          take("[");
          let states = 0;
          while (tokens[index] !== "]") {
            const state = tokens[index];
            const allowed = field === "issues" ? ["OPEN", "CLOSED"] : ["OPEN", "CLOSED", "MERGED"];
            if (!allowed.includes(state)) throw new Error("invalid GraphQL request");
            index += 1;
            states += 1;
            if (tokens[index] === ",") take(",");
            else if (tokens[index] !== "]") throw new Error("invalid GraphQL request");
          }
          if (states === 0) throw new Error("invalid GraphQL request");
          take("]");
        }
        take(")");
      }
      take("{");
      take("totalCount");
      take("}");
    } else {
      throw new Error("invalid GraphQL request");
    }
    selections += 1;
  }
  if (selections === 0) throw new Error("invalid GraphQL request");
  take("}");
  take("}");
  if (index !== tokens.length) throw new Error("invalid GraphQL request");
  const owner = inlineOwner ?? suppliedOwner;
  const name = inlineName ?? suppliedName;
  if (!login(owner) || !projectName(name)) throw new Error("invalid GraphQL request");
  if ((inlineOwner === null) !== (inlineName === null)) throw new Error("invalid GraphQL request");
  return {owner, name};
}

function within(candidate, root) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== "..");
}

function unsafeManagedPath(candidate) {
  const unsafeRoots = [codeRoot, fmHome, path.join(fmHome, "projects"), path.join(fmHome, "data"), path.join(fmHome, "state")]
    .map((entry) => {
      const absolute = path.resolve(entry);
      try {
        return fs.realpathSync(absolute);
      } catch {
        return absolute;
      }
    });
  return unsafeRoots.some((root) => within(candidate, root)) || candidate.split(path.sep).includes(".treehouse");
}

function safeProfileDir(value) {
  if (!singleLine(value, 4096) || !path.isAbsolute(value)) throw new Error("invalid profile directory");
  const lstat = fs.lstatSync(value);
  if (!lstat.isDirectory() || lstat.isSymbolicLink()) throw new Error("invalid profile directory");
  const resolved = fs.realpathSync(value);
  if (unsafeManagedPath(resolved)) throw new Error("unsafe profile directory");
  return resolved;
}

function parseRepository(raw) {
  if (!singleLine(raw, 2048) || raw.includes("@") || raw.includes("\\")) throw new Error("invalid repository");
  let candidate = raw;
  if (!candidate.includes("://")) candidate = `https://${candidate}`;
  const parsed = new URL(candidate);
  if (parsed.protocol !== "https:" || parsed.hostname.toLowerCase() !== "github.com" || parsed.port || parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error("invalid repository");
  }
  const parts = parsed.pathname.replace(/^\/+|\/+$/gu, "").replace(/\.git$/u, "").split("/");
  if (parts.length === 4 && parts[2] === "pull" && /^[1-9][0-9]*$/u.test(parts[3])) parts.splice(2);
  if (parts.length !== 2 || !parts.every((part) => /^[A-Za-z0-9._-]+$/u.test(part) && part !== "." && part !== "..")) {
    throw new Error("invalid repository");
  }
  return `github.com/${parts[0]}/${parts[1]}`;
}

function parseOwner(raw) {
  if (!singleLine(raw, 512) || raw.includes("@") || raw.includes("\\")) throw new Error("invalid owner");
  let candidate = raw;
  if (!candidate.includes("://")) candidate = `https://${candidate}`;
  const parsed = new URL(candidate);
  if (parsed.protocol !== "https:" || parsed.hostname.toLowerCase() !== "github.com" || parsed.port || parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error("invalid owner");
  }
  const parts = parsed.pathname.replace(/^\/+|\/+$/gu, "").split("/");
  if (parts.length !== 1 || !login(parts[0])) throw new Error("invalid owner");
  return `github.com/${parts[0]}`;
}

function normalizedMap(raw, keyValidator, valueValidator) {
  if (!object(raw)) throw new Error("invalid map");
  const result = new Map();
  for (const [key, value] of Object.entries(raw)) {
    const canonical = keyValidator(key);
    const normalized = canonical.toLowerCase();
    if (result.has(normalized)) throw new Error("duplicate normalized key");
    valueValidator(value);
    result.set(normalized, { key: canonical, value });
  }
  return result;
}

function load() {
  const parts = path.relative(fmHome, configPath).split(path.sep).filter(Boolean);
  let current = fmHome;
  let lstat = null;
  try {
    const homeStat = fs.lstatSync(current);
    if (!homeStat.isDirectory() || homeStat.isSymbolicLink()) throw new Error("unsafe config file");
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
  for (const part of parts) {
    current = path.join(current, part);
    try {
      lstat = fs.lstatSync(current);
    } catch (error) {
      if (error?.code === "ENOENT") return null;
      throw error;
    }
    if (lstat.isSymbolicLink() || (current !== configPath && !lstat.isDirectory())) {
      throw new Error("unsafe config file");
    }
  }
  if (!lstat.isFile() || lstat.isSymbolicLink() || (process.platform !== "win32" && (lstat.mode & 0o777) !== 0o600) || lstat.size > 64 * 1024) {
    throw new Error("unsafe config file");
  }
  const parsed = new StrictJSONParser(fs.readFileSync(configPath, "utf8")).parse();
  rejectCredentialStrings(parsed);
  exactKeys(parsed, ["version", "gh_binary", "git_binary", "gh_axi_binary", "require_secure_storage", "profiles", "bindings"]);
  if (parsed.version !== 1 || parsed.require_secure_storage !== true) throw new Error("unsupported config");
  const ghBinary = canonicalExecutable(parsed.gh_binary, "gh");
  const gitBinary = canonicalExecutable(parsed.git_binary, "git");
  const ghAxiBinary = canonicalExecutable(parsed.gh_axi_binary, "gh-axi");

  if (!object(parsed.profiles) || Object.keys(parsed.profiles).length === 0) throw new Error("missing profiles");
  const profiles = new Map();
  const profileDirectories = new Set();
  for (const [id, value] of Object.entries(parsed.profiles)) {
    if (!profileID(id)) throw new Error("invalid profile id");
    const normalized = id.toLowerCase();
    if (profiles.has(normalized)) throw new Error("duplicate normalized profile");
    exactKeys(value, ["host", "expected_login", "gh_config_dir", "git_protocol", "fork_owner", "commit_identity"], ["host", "expected_login", "gh_config_dir", "git_protocol"]);
    if (typeof value.host !== "string" || value.host.toLowerCase() !== "github.com" || value.host !== value.host.trim()) throw new Error("invalid host");
    if (!login(value.expected_login) || value.git_protocol !== "https") throw new Error("invalid profile");
    if (Object.hasOwn(value, "fork_owner") && !login(value.fork_owner)) throw new Error("invalid fork owner");
    if (Object.hasOwn(value, "commit_identity")) identity(value.commit_identity);
    const ghConfigDir = safeProfileDir(value.gh_config_dir);
    if (profileDirectories.has(ghConfigDir)) throw new Error("shared profile directory");
    profileDirectories.add(ghConfigDir);
    profiles.set(normalized, {
      id,
      host: "github.com",
      expectedLogin: value.expected_login,
      ghConfigDir,
      forkOwner: value.fork_owner || "",
      commitName: value.commit_identity?.name || "",
      commitEmail: value.commit_identity?.email || "",
    });
  }

  exactKeys(parsed.bindings, ["projects", "repositories", "owners"]);
  const profileReference = (value) => {
    if (!profileID(value) || !profiles.has(value.toLowerCase())) throw new Error("unknown profile reference");
  };
  const projects = normalizedMap(parsed.bindings.projects, (value) => {
    if (!projectName(value)) throw new Error("invalid project binding");
    return value;
  }, profileReference);
  const repositories = normalizedMap(parsed.bindings.repositories, parseRepository, profileReference);
  const owners = normalizedMap(parsed.bindings.owners, parseOwner, profileReference);
  if (projects.size + repositories.size + owners.size === 0) throw new Error("missing bindings");

  return { ghBinary, gitBinary, ghAxiBinary, profiles, projects, repositories, owners, serialized: parsed };
}

function registeredProjects() {
  try {
    const names = new Set();
    for (const line of fs.readFileSync(projectsFile, "utf8").split(/\r?\n/u)) {
      const match = line.match(/^- ([A-Za-z0-9][A-Za-z0-9._-]*)\s/u);
      if (match) names.add(match[1].toLowerCase());
    }
    return names;
  } catch {
    return new Set();
  }
}

function option(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] || "" : "";
}

function emit(key, value) {
  if (String(value).includes("\t") || String(value).includes("\n")) throw new Error("unsafe output");
  process.stdout.write(`${key}\t${value}\n`);
}

function resolve(config) {
  const rawProject = option("--project");
  const rawRepository = option("--repository");
  const requiredProfile = option("--profile");
  const allowUnregisteredProject = process.argv.includes("--allow-unregistered-project");
  const project = rawProject ? rawProject.toLowerCase() : "";
  if (rawProject && !projectName(rawProject)) throw new Error("invalid project");
  const repository = rawRepository ? parseRepository(rawRepository) : "";
  if (!repository) throw new Error("missing repository");
  const repositoryKey = repository.toLowerCase();
  const ownerKey = repository.split("/").slice(0, 2).join("/").toLowerCase();
  const registered = project ? registeredProjects().has(project) : false;
  if (allowUnregisteredProject && (!project || registered)) {
    throw new Error("invalid preregistration");
  }
  const candidates = [];
  if (project && (registered || allowUnregisteredProject) && config.projects.has(project)) candidates.push(config.projects.get(project).value);
  if (config.repositories.has(repositoryKey)) candidates.push(config.repositories.get(repositoryKey).value);
  if (config.owners.has(ownerKey)) candidates.push(config.owners.get(ownerKey).value);
  if (allowUnregisteredProject && candidates.length === 0) throw new Error("invalid preregistration");
  if (candidates.length === 0 && !requiredProfile) throw new Error("unknown route");
  if (requiredProfile && !profileID(requiredProfile)) throw new Error("profile route mismatch");
  const selectedNames = new Set(candidates.map((value) => value.toLowerCase()));
  if (selectedNames.size > 1) throw new Error("conflicting route");
  const normalized = candidates.length > 0 ? candidates[0].toLowerCase() : requiredProfile.toLowerCase();
  if (requiredProfile && requiredProfile.toLowerCase() !== normalized) throw new Error("profile route mismatch");
  const selected = config.profiles.get(normalized);
  if (!selected) throw new Error("removed profile");
  emit("mode", "strict");
  emit("profile_id", selected.id);
  emit("gh_binary", config.ghBinary);
  emit("git_binary", config.gitBinary);
  emit("gh_axi_binary", config.ghAxiBinary);
  emit("gh_config_dir", selected.ghConfigDir);
  emit("host", selected.host);
  emit("expected_login", selected.expectedLogin);
  emit("fork_owner", selected.forkOwner);
  emit("commit_name", selected.commitName);
  emit("commit_email", selected.commitEmail);
  emit("repository", repository);
  emit("project", rawProject);
}

try {
  const action = process.argv[2] || "validate";
  const config = load();
  if (!config) {
    emit("mode", "legacy");
    process.exit(0);
  }
  if (action === "validate") {
    emit("mode", "strict");
    emit("gh_binary", config.ghBinary);
    emit("git_binary", config.gitBinary);
    emit("gh_axi_binary", config.ghAxiBinary);
    process.exit(0);
  }
  if (action === "sanitize") {
    process.stdout.write(`${JSON.stringify(config.serialized, null, 2)}\n`);
    process.exit(0);
  }
  if (action === "canonicalize-executable") {
    const basename = option("--basename");
    if (basename !== "no-mistakes") throw new Error("invalid executable request");
    emit("executable", canonicalNamedExecutable(option("--path"), basename));
    process.exit(0);
  }
  if (action === "validate-graphql-read") {
    const result = validateRepositoryGraphQL(option("--query"), option("--name-variable"), option("--owner"), option("--name"));
    emit("owner", result.owner);
    emit("name", result.name);
    process.exit(0);
  }
  if (action === "resolve") {
    resolve(config);
    process.exit(0);
  }
  if (action === "canonicalize-repository") {
    let raw = option("--repository");
    if (/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+(?:\.git)?$/u.test(raw)) raw = `github.com/${raw}`;
    emit("repository", parseRepository(raw));
    process.exit(0);
  }
  fail("invalid GitHub routing request");
} catch (error) {
  if (error?.message === "unknown route") fail("no GitHub account route matches the registered project, repository, or owner");
  if (error?.message === "conflicting route") fail("GitHub account bindings conflict for this project and repository");
  if (error?.message === "removed profile") fail("the recorded GitHub account profile no longer exists");
  if (error?.message === "profile route mismatch") fail("the recorded GitHub account profile no longer matches this project");
  if (error?.message === "invalid preregistration") fail("the pre-registration GitHub project route is unavailable");
  fail();
}
