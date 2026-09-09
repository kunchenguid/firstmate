#!/usr/bin/env node
// Real-browser page verification. Sole owner of the fm-verify-page contract:
// see bin/fm-verify-page.sh for the CLI surface and docs/known-tool-defects.md
// for the chrome-devtools-axi failure this replaces.
//
// Every failure path throws or rejects and is caught by main(), which prints
// the real error to stderr and exits 1. Nothing here is allowed to print a
// success line without the underlying action having actually completed and
// been checked - the whole reason this tool exists is that chrome-devtools-axi
// reported "screenshot: /tmp/shot.png" while writing no file.

import { chromium } from "playwright-core";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// --- CLI parsing ---------------------------------------------------------

function parseArgs(argv) {
  const opts = { url: null, screenshot: null, timeoutMs: 30000, waitUntil: "load", textMax: 4000 };
  const rest = [...argv];
  while (rest.length) {
    const arg = rest.shift();
    switch (arg) {
      case "--screenshot":
        opts.screenshot = rest.shift();
        break;
      case "--timeout":
        opts.timeoutMs = Number(rest.shift());
        break;
      case "--wait-until":
        opts.waitUntil = rest.shift();
        break;
      case "--text-max":
        opts.textMax = Number(rest.shift());
        break;
      default:
        if (opts.url === null) {
          opts.url = arg;
        } else {
          throw new Error(`unexpected argument: ${arg}`);
        }
    }
  }
  if (!opts.url) throw new Error("usage: fm-verify-page.sh <url> [--screenshot <path>] [--timeout <ms>] [--wait-until <state>] [--text-max <n>]");
  if (!/^https?:\/\//i.test(opts.url)) throw new Error(`refusing non-http(s) URL: ${opts.url}`);
  if (!Number.isFinite(opts.timeoutMs) || opts.timeoutMs <= 0) throw new Error(`invalid --timeout: ${opts.timeoutMs}`);
  if (!Number.isFinite(opts.textMax) || opts.textMax <= 0) throw new Error(`invalid --text-max: ${opts.textMax}`);
  return opts;
}

// --- No-root chromium native-dependency repair ----------------------------
//
// This sandbox's chromium build links libnspr4/libnss3/libnssutil3/libsmime3,
// which are not preinstalled here and there is no root access to `apt-get
// install` them system-wide (see docs/known-tool-defects.md for the exact
// reproduction). apt-get download and dpkg-deb -x both work unprivileged, so
// on the specific "error while loading shared libraries" failure this fetches
// the two owning .debs into a user-owned cache once and points chromium at
// them via LD_LIBRARY_PATH. Any other launch failure, or a failure of this
// repair itself, propagates as the real error - this never converts a failure
// into a false success.

const NSS_LIB_CACHE = join(homedir(), ".cache", "firstmate", "fm-verify-page-nss-libs");
const NSS_LIB_DIR = join(NSS_LIB_CACHE, "usr", "lib", "x86_64-linux-gnu");
const NSS_PACKAGES = ["libnspr4", "libnss3"];
const NSS_REQUIRED_FILES = ["libnspr4.so", "libnss3.so"];
const MISSING_LIB_RE = /error while loading shared libraries: (lib(?:nspr4|nss3|nssutil3|smime3|softokn3|freebl3)\.so)/;

function nssLibsPresent() {
  if (!existsSync(NSS_LIB_DIR)) return false;
  try {
    const files = readdirSync(NSS_LIB_DIR);
    return NSS_REQUIRED_FILES.every((f) => files.includes(f));
  } catch {
    return false;
  }
}

function applyNssLibPath() {
  const parts = [NSS_LIB_DIR, process.env.LD_LIBRARY_PATH].filter(Boolean);
  process.env.LD_LIBRARY_PATH = parts.join(":");
}

function bootstrapNssLibs() {
  mkdirSync(NSS_LIB_CACHE, { recursive: true });
  const dlDir = join(NSS_LIB_CACHE, "_dl");
  mkdirSync(dlDir, { recursive: true });
  execFileSync("apt-get", ["download", ...NSS_PACKAGES], { cwd: dlDir, stdio: "pipe" });
  const debs = readdirSync(dlDir).filter((f) => f.endsWith(".deb"));
  if (debs.length === 0) throw new Error("apt-get download produced no .deb files");
  for (const deb of debs) {
    execFileSync("dpkg-deb", ["-x", join(dlDir, deb), NSS_LIB_CACHE], { stdio: "pipe" });
  }
}

async function launchChromium() {
  if (nssLibsPresent()) applyNssLibPath();
  try {
    return await chromium.launch({ headless: true });
  } catch (err) {
    const msg = String((err && err.message) || err);
    const match = MISSING_LIB_RE.exec(msg);
    if (!match) throw err;
    if (!nssLibsPresent()) {
      process.stderr.write(`fm-verify-page: chromium is missing ${match[1]}; attempting a one-time local repair (apt-get download + dpkg-deb -x, no root)...\n`);
      bootstrapNssLibs();
    }
    if (!nssLibsPresent()) {
      throw new Error(`local dependency repair did not produce ${NSS_LIB_DIR}; original launch error: ${msg.split("\n")[0]}`);
    }
    applyNssLibPath();
    return await chromium.launch({ headless: true });
  }
}

// --- Verification run ------------------------------------------------------

async function run(opts) {
  const browser = await launchChromium();
  try {
    const page = await browser.newPage();
    page.setDefaultTimeout(opts.timeoutMs);
    const response = await page.goto(opts.url, { waitUntil: opts.waitUntil, timeout: opts.timeoutMs });
    if (!response) throw new Error(`navigation to ${opts.url} produced no response (blocked, or downloaded as a non-navigable resource)`);

    const status = response.status();
    const finalUrl = response.url();
    const title = await page.title();
    const text = await page.evaluate(() => document.body ? document.body.innerText : "");
    const truncatedText = text.length > opts.textMax ? `${text.slice(0, opts.textMax)}…` : text;

    let screenshotPath = null;
    if (opts.screenshot) {
      await page.screenshot({ path: opts.screenshot, fullPage: true });
      if (!existsSync(opts.screenshot)) {
        throw new Error(`screenshot() returned but no file exists at ${opts.screenshot}`);
      }
      const size = statSync(opts.screenshot).size;
      if (size <= 0) {
        throw new Error(`screenshot() wrote an empty file at ${opts.screenshot} (0 bytes)`);
      }
      screenshotPath = opts.screenshot;
    }

    return {
      url: opts.url,
      final_url: finalUrl,
      status,
      title,
      text: truncatedText,
      screenshot: screenshotPath,
    };
  } finally {
    await browser.close();
  }
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`fm-verify-page: ${err.message}\n`);
    process.exit(1);
  }
  try {
    const result = await run(opts);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } catch (err) {
    const msg = String((err && err.message) || err).split("\n")[0];
    process.stderr.write(`fm-verify-page: ${msg}\n`);
    process.exit(1);
  }
}

main();
