// fm-commandcode-mod.ts - Firstmate's Command Code worker mod: the semantic
// busy-state writer for one task incarnation (bin/fm-busy-lib.sh owns the
// contract; bin/fm-busy-event.sh is the only writer this mod calls).
//
// Loaded per process by bin/fm-spawn.sh with `--mod <this file>` and four
// `--mod-option` values, so nothing is written into the captain's Command Code
// settings or the project. Command Code's `--config` is not a per-process
// switch: it persists the setting to ~/.commandcode/config.json, which is why
// this wiring rides a session-scoped mod instead (verified, Command Code 1.74.1).
//
//   fmWriter  absolute path of bin/fm-busy-event.sh
//   fmState   absolute state directory of the owning Firstmate home
//   fmId      task id
//   fmGen     busy generation armed for this incarnation
//
// A missing option makes every handler a no-op, so a raw launch of this mod
// can never write a record. Lifecycle (verified live, Command Code 1.74.1):
//   run_start          one user turn began -> busy
//   run_end            the turn finished, including an Escape interrupt
//                      (stopReason `interrupted`) -> idle; a normal end also
//                      touches state/<id>.turn-ended, the watcher notification
//   onSessionEnd       /quit or process shutdown -> idle
// Writes are synchronous so two events of one incarnation can never reorder,
// and a refused event (stale generation) is ignored: the writer is
// generation-bound and the agent's own lifecycle must never break on it.

import {spawnSync} from 'node:child_process';
import {closeSync, openSync, utimesSync} from 'node:fs';

const OPTIONS = ['fmWriter', 'fmState', 'fmId', 'fmGen'] as const;

export default function (cmd: any): void {
	for (const name of OPTIONS) {
		cmd.addFlag(name, {type: 'string', default: '', description: `Firstmate busy-state ${name}`});
	}

	const option = (name: (typeof OPTIONS)[number]): string => {
		const value = cmd.getFlag(name);
		return typeof value === 'string' ? value : '';
	};

	const apply = (state: 'busy' | 'idle', event: string): boolean => {
		const writer = option('fmWriter');
		const dir = option('fmState');
		const id = option('fmId');
		const gen = option('fmGen');
		if (!writer || !dir || !id || !gen) return false;
		const result = spawnSync(
			writer,
			['apply', dir, id, state, '--gen', gen, '--source', 'commandcode-mod', '--event', event],
			{stdio: 'ignore', timeout: 10000},
		);
		return result.status === 0;
	};

	cmd.on('run_start', () => {
		apply('busy', 'run-start');
	});

	cmd.on('run_end', (event: any) => {
		if (!apply('idle', 'run-end')) return;
		if (event?.result?.stopReason === 'interrupted') return;
		const marker = `${option('fmState')}/${option('fmId')}.turn-ended`;
		try {
			closeSync(openSync(marker, 'a'));
			const now = new Date();
			utimesSync(marker, now, now);
		} catch {
			// The notification is best effort; the busy record already settled.
		}
	});

	cmd.hooks({
		onSessionEnd: () => {
			apply('idle', 'session-end');
		},
	});
}
