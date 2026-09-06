// Scheduler — per-OS background launch.
// macOS: launchctl (LaunchAgent plist). Linux: systemd user unit. Windows:
// Task Scheduler (schtasks) at logon. Used by the remote-job worker and the
// pty-host autostart so they survive firstmate's own session restarts.

import { spawn } from 'node:child_process';
import { platformOf } from './path-util.js';

export interface ScheduledTaskSpec {
  name: string;
  /** Command to run at logon. */
  command: string;
  /** Arguments array. */
  args: string[];
  /** Working directory. */
  cwd: string;
}

export async function ensureScheduled(spec: ScheduledTaskSpec, env?: NodeJS.ProcessEnv): Promise<void> {
  const platform = platformOf(env);
  if (platform === 'win32') {
    await runSchtasks(spec);
  } else if (platform === 'darwin') {
    await runLaunchAgent(spec);
  } else {
    await runSystemd(spec);
  }
}

async function runSchtasks(spec: ScheduledTaskSpec): Promise<void> {
  // Register a logon task running the command via cmd (handles .cmd shims).
  const run = `cmd.exe /c ""${spec.command}" ${spec.args.map(quote).join(' ')}"`;
  const action = `/TR "${run}"`;
  await exec('schtasks.exe', ['/Create', '/F', '/TN', `firstmate-${spec.name}`, '/SC', 'ONLOGON', '/RL', 'LIMITED', action]);
}

async function runLaunchAgent(spec: ScheduledTaskSpec): Promise<void> {
  const label = `dev.firstmate.${spec.name}`;
  const plistPath = `${process.env.HOME}/Library/LaunchAgents/${label}.plist`;
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key><array>
    <string>${spec.command}</string>${spec.args.map((a) => `\n    <string>${a}</string>`).join('')}
  </array>
  <key>WorkingDirectory</key><string>${spec.cwd}</string>
  <key>RunAtLoad</key><true/>
</dict></plist>`;
  const { promises: fs } = await import('node:fs');
  await fs.mkdir(`${process.env.HOME}/Library/LaunchAgents`, { recursive: true });
  await fs.writeFile(plistPath, plist, 'utf8');
  await exec('launchctl', ['load', '-w', plistPath]);
}

async function runSystemd(spec: ScheduledTaskSpec): Promise<void> {
  const unit = `firstmate-${spec.name}.service`;
  const unitPath = `${process.env.HOME}/.config/systemd/user/${unit}`;
  const body = `[Unit]
Description=firstmate ${spec.name}
[Service]
Type=simple
WorkingDirectory=${spec.cwd}
ExecStart=${spec.command} ${spec.args.join(' ')}
Restart=on-failure
[Install]
WantedBy=default.target
`;
  const { promises: fs } = await import('node:fs');
  await fs.mkdir(`${process.env.HOME}/.config/systemd/user`, { recursive: true });
  await fs.writeFile(unitPath, body, 'utf8');
  await exec('systemctl', ['--user', 'daemon-reload']);
  await exec('systemctl', ['--user', 'enable', unit]);
}

function quote(a: string): string {
  return /[\s"]/.test(a) ? `"${a.replace(/"/g, '\\"')}"` : a;
}

function exec(cmd: string, args: string[]): Promise<void> {
  return new Promise((resolve) => {
    const p = spawn(cmd, args, { stdio: 'ignore' });
    p.on('error', () => resolve());
    p.on('exit', () => resolve());
  });
}
