// Notify — per-OS user notifications.
// macOS: osascript notification. Linux: notify-send. Windows: PowerShell
// toast via the Windows.UI.Notifications API (falls back to a console beep
// when the toast API is unavailable).

import { spawn } from 'node:child_process';
import { platformOf } from './path-util.js';

export interface NotifyOptions {
  title: string;
  message: string;
}

export function notify(opts: NotifyOptions, env?: NodeJS.ProcessEnv): void {
  const platform = platformOf(env);
  const title = opts.title.replace(/["\\]/g, '\\$&');
  const message = opts.message.replace(/["\\]/g, '\\$&');

  let cmd: string | null = null;
  let args: string[] = [];

  if (platform === 'darwin') {
    cmd = 'osascript';
    args = ['-e', `display notification "${message}" with title "${title}"`];
  } else if (platform === 'linux') {
    cmd = 'notify-send';
    args = [title, message];
  } else if (platform === 'win32') {
    // PowerShell toast; spawn detached so the caller is not blocked.
    const ps = `
      [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
      $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
      $texts = $template.GetElementsByTagName('text')
      $texts.Item(0).AppendChild($template.CreateTextNode('${title}')) | Out-Null
      $texts.Item(1).AppendChild($template.CreateTextNode('${message}')) | Out-Null
      $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
      [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('firstmate').Show($toast)
    `;
    cmd = 'powershell.exe';
    args = ['-NoProfile', '-NonInteractive', '-Command', ps];
  }

  if (!cmd) return;
  const child = spawn(cmd, args, { stdio: 'ignore', detached: true, windowsHide: true });
  child.unref();
}

/** Fallback console alert used when the platform has no toast channel. */
export function beep(): void {
  process.stdout.write('\u0007');
}
