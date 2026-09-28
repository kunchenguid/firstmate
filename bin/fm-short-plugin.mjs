// The sole trusted short-session extension. No package discovery or installation.
// Use Pi's supported resource override to exclude the plugin's management tools;
// its provider, request, transcript and compaction handlers remain initialized.
import fs from 'node:fs';
import path from 'node:path';
export const shortPlugin = { name: 'pi-openai-codex-compat', entrypoint: './extensions/index.ts' };
export const shortPluginEnvironment = {
  FAST_MODE: 'false', RESPONSES_LITE: 'false', APPLY_PATCH: 'false',
  APPLY_PATCH_DEBUG: 'false', APPLY_PATCH_DIAGNOSTICS: 'false', TOOL_BACKGROUND: 'subtle',
  SHELL_TOOL: 'unified_exec', IMAGE_GENERATION: 'false', IMAGE_DETAIL: 'auto', WEB_RUN: 'false',
  AUTO_COMPACT_AT_PERCENT: 'off', WEB_SEARCH_MODE: 'disabled', TEXT_VERBOSITY: 'low',
  REASONING_SUMMARY: 'off', REASONING_MODE: 'standard',
};
const pluginTools = new Set(['exec_command', 'write_stdin', 'shell_command', 'apply_patch', 'image_gen.imagegen', 'web.run']);
export async function shortPluginLoader(sdk, dir, settingsManager, systemPrompt) {
  if (typeof sdk?.getAgentDir !== 'function' || typeof sdk?.DefaultResourceLoader !== 'function') {
    throw Error('short-agent required Pi resource APIs unavailable');
  }
  const packageDir = path.join(sdk.getAgentDir(), 'npm/node_modules', shortPlugin.name);
  let manifest;
  try { manifest = JSON.parse(fs.readFileSync(path.join(packageDir, 'package.json'), 'utf8')); }
  catch { throw Error(`short-agent requires installed ${shortPlugin.name}`); }
  if (manifest.name !== shortPlugin.name ||
      JSON.stringify(manifest.pi?.extensions) !== JSON.stringify([shortPlugin.entrypoint])) {
    throw Error('short-agent plugin identity/entrypoint mismatch');
  }
  const plugin = { name: shortPlugin.name,
    version: typeof manifest.version === 'string' && manifest.version.trim() ? manifest.version : 'unknown' };
  const entry = fs.realpathSync(path.join(packageDir, shortPlugin.entrypoint));
  if (!entry.startsWith(fs.realpathSync(packageDir) + path.sep)) throw Error('short-agent plugin entry escapes package');
  // Runtime authentication has already been initialized from its original store.
  // Plugin config and installation identity now belong only to this child.
  process.env.PI_CODING_AGENT_DIR = dir;
  for (const [key, value] of Object.entries(shortPluginEnvironment)) process.env[`PI_OPENAI_CODEX_COMPAT_${key}`] = value;
  const loader = new sdk.DefaultResourceLoader({ cwd: dir, agentDir: dir, settingsManager,
    noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
    additionalExtensionPaths: [entry], systemPrompt, systemPromptOverride: () => systemPrompt,
    appendSystemPromptOverride: () => [], agentsFilesOverride: () => ({ agentsFiles: [] }),
    extensionsOverride: result => {
      if (result.errors.length || result.extensions.length !== 1 || fs.realpathSync(result.extensions[0].resolvedPath) !== entry) {
        throw Error('short-agent plugin load failed or unexpected extension discovered');
      }
      const extension = result.extensions[0];
      if (!(extension.tools instanceof Map) || !(extension.commands instanceof Map) ||
          !(extension.shortcuts instanceof Map) || !(extension.handlers instanceof Map) ||
          !extension.handlers.has('session_start')) {
        throw Error('short-agent plugin required runtime capabilities unavailable');
      }
      for (const name of extension.tools.keys()) if (!pluginTools.has(name)) throw Error('short-agent plugin registered an unexpected tool');
      // Removing registrations, not just hiding active names, prevents later
      // plugin activation from granting filesystem, shell or network tools.
      extension.tools.clear();
      extension.commands.clear();
      extension.shortcuts.clear();
      return result;
    },
  });
  await loader.reload();
  return { loader, plugin };
}
