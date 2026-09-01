// PathUtil tests — cross-platform path semantics.
import { describe, it, expect } from 'vitest';
import path from 'node:path';
import {
  platformOf,
  isWindows,
  expandHome,
  samePath,
  toNative,
  toPosix,
  isAbsolute,
} from '../src/platform/path-util.js';

const WINDOWS_ENV = { FIRSTMATE_PLATFORM: 'win32' } as NodeJS.ProcessEnv;
const LINUX_ENV = { FIRSTMATE_PLATFORM: 'linux' } as NodeJS.ProcessEnv;

describe('PathUtil', () => {
  it('detects platform from env override', () => {
    expect(platformOf(WINDOWS_ENV)).toBe('win32');
    expect(platformOf(LINUX_ENV)).toBe('linux');
    expect(isWindows(WINDOWS_ENV)).toBe(true);
    expect(isWindows(LINUX_ENV)).toBe(false);
  });

  it('expands a leading tilde', () => {
    const home = expandHome('~/projects/foo');
    const suffix = 'projects' + path.sep + 'foo';
    expect(home.endsWith(suffix)).toBe(true);
  });

  it('compares case-insensitively on Windows, case-sensitively elsewhere', () => {
    expect(samePath('C:\\Users\\Me\\Project', 'c:\\users\\me\\project', WINDOWS_ENV)).toBe(true);
    expect(samePath('/home/me/project', '/home/me/Project', LINUX_ENV)).toBe(false);
    expect(samePath('/home/me/project', '/home/me/project', LINUX_ENV)).toBe(true);
  });

  it('normalizes separators per platform', () => {
    expect(toNative('C:/Users/Me/Project', WINDOWS_ENV)).toBe('C:\\Users\\Me\\Project');
    expect(toNative('/home/me/project', LINUX_ENV)).toBe('/home/me/project');
    expect(toPosix('C:\\Users\\Me')).toBe('C:/Users/Me');
  });

  it('recognizes absolute paths on both platforms', () => {
    expect(isAbsolute('C:\\Users\\Me')).toBe(true);
    expect(isAbsolute('/home/me')).toBe(true);
    expect(isAbsolute('relative/path')).toBe(false);
  });
});
