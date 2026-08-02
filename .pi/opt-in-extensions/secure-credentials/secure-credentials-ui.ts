import type { Theme } from "@earendil-works/pi-coding-agent";
import {
	CURSOR_MARKER,
	Key,
	matchesKey,
	truncateToWidth,
	wrapTextWithAnsi,
	type Component,
	type Focusable,
} from "@earendil-works/pi-tui";

import type {
	SecureCredentialInputOutcome,
	SecureCredentialOverwriteOutcome,
} from "./secure-credentials-contract.ts";

const MASKED_CREDENTIAL_PLACEHOLDER = "••••••••";
const BRACKETED_PASTE_START = "\x1b[200~";
const BRACKETED_PASTE_END = "\x1b[201~";

/** A single-line masked editor that keeps the IME cursor marker visible. */
export class MaskedCredentialEditor implements Component, Focusable {
	/** TUI sets this property when the editor owns focus. */
	focused = false;

	/** Called after a non-empty value is submitted and cleared from the editor. */
	onSubmit?: (value: string) => void;
	/** Called when Escape or Ctrl+C cancels the page. */
	onCancel?: () => void;
	/** Called when Enter is pressed with no value. */
	onEmptySubmit?: () => void;

	private value = "";
	private cursor = 0;
	private pasteBuffer = "";

	/** Clear the in-memory editor value and its pending paste buffer. */
	clear(): void {
		this.value = "";
		this.cursor = 0;
		this.pasteBuffer = "";
	}

	handleInput(data: string): void {
		if (matchesKey(data, Key.escape) || matchesKey(data, Key.ctrl("c"))) {
			this.clear();
			this.onCancel?.();
			return;
		}
		if (matchesKey(data, Key.enter)) {
			const submitted = this.value;
			this.clear();
			if (submitted.length === 0) {
				this.onEmptySubmit?.();
			} else {
				this.onSubmit?.(submitted);
			}
			return;
		}
		if (matchesKey(data, Key.backspace)) {
			this.deleteBackward();
			return;
		}
		if (matchesKey(data, Key.delete)) {
			this.deleteForward();
			return;
		}
		if (matchesKey(data, Key.left)) {
			this.moveLeft();
			return;
		}
		if (matchesKey(data, Key.right)) {
			this.moveRight();
			return;
		}
		if (matchesKey(data, Key.home)) {
			this.cursor = 0;
			return;
		}
		if (matchesKey(data, Key.end)) {
			this.cursor = this.value.length;
			return;
		}
		this.handleTextOrPaste(data);
	}

	render(width: number): string[] {
		const safeWidth = Math.max(1, width);
		const mask = Array.from(MASKED_CREDENTIAL_PLACEHOLDER);
		let content = mask.join("");
		if (this.focused) {
			const cursorIndex = Math.min(this.graphemeCountBeforeCursor(), mask.length - 1);
			const before = mask.slice(0, cursorIndex).join("");
			const atCursor = mask[cursorIndex] ?? " ";
			const after = mask.slice(cursorIndex + 1).join("");
			content = `${before}${CURSOR_MARKER}\x1b[7m${atCursor}\x1b[0m${after}`;
		}

		const line = truncateToWidth(content, safeWidth, "", true);
		if (this.focused && !line.includes(CURSOR_MARKER)) {
			return [`${CURSOR_MARKER}\x1b[7m \x1b[0m`];
		}
		return [line];
	}

	invalidate(): void {}

	private handleTextOrPaste(data: string): void {
		if (this.pasteBuffer.length > 0) {
			const combined = this.pasteBuffer + data;
			this.pasteBuffer = "";
			const end = combined.indexOf(BRACKETED_PASTE_END);
			if (end < 0) {
				this.pasteBuffer = combined;
				return;
			}
			this.insertPrintableText(combined.slice(0, end));
			this.handleTextOrPaste(combined.slice(end + BRACKETED_PASTE_END.length));
			return;
		}

		const start = data.indexOf(BRACKETED_PASTE_START);
		if (start >= 0) {
			this.insertPrintableText(data.slice(0, start));
			const pasted = data.slice(start + BRACKETED_PASTE_START.length);
			const end = pasted.indexOf(BRACKETED_PASTE_END);
			if (end < 0) {
				this.pasteBuffer = pasted;
				return;
			}
			this.insertPrintableText(pasted.slice(0, end));
			this.handleTextOrPaste(pasted.slice(end + BRACKETED_PASTE_END.length));
			return;
		}

		this.insertPrintableText(data);
	}

	private insertPrintableText(text: string): void {
		if (text.length === 0 || /[\u0000-\u001f\u007f]/u.test(text)) return;
		this.value = `${this.value.slice(0, this.cursor)}${text}${this.value.slice(this.cursor)}`;
		this.cursor += text.length;
	}

	private deleteBackward(): void {
		if (this.cursor === 0) return;
		const before = this.value.slice(0, this.cursor);
		const graphemes = Array.from(before);
		const previous = graphemes[graphemes.length - 1] ?? "";
		this.cursor -= previous.length;
		this.value = `${this.value.slice(0, this.cursor)}${this.value.slice(this.cursor + previous.length)}`;
	}

	private deleteForward(): void {
		if (this.cursor >= this.value.length) return;
		const after = Array.from(this.value.slice(this.cursor));
		const next = after[0] ?? "";
		this.value = `${this.value.slice(0, this.cursor)}${this.value.slice(this.cursor + next.length)}`;
	}

	private moveLeft(): void {
		if (this.cursor === 0) return;
		const before = Array.from(this.value.slice(0, this.cursor));
		this.cursor -= (before[before.length - 1] ?? "").length;
	}

	private moveRight(): void {
		if (this.cursor >= this.value.length) return;
		const after = Array.from(this.value.slice(this.cursor));
		this.cursor += (after[0] ?? "").length;
	}

	private graphemeCountBeforeCursor(): number {
		return Array.from(this.value.slice(0, this.cursor)).length;
	}
}

/** A TUI page that collects one credential without rendering its value. */
export class SecureCredentialInputPage implements Component, Focusable {
	private readonly editor: MaskedCredentialEditor;
	private _focused = false;
	private finished = false;
	private errorText = "";
	private readonly key: string;
	private readonly destination: string;
	private readonly theme: Theme;
	private readonly requestRender: () => void;
	private readonly done: (outcome: SecureCredentialInputOutcome) => void;

	constructor(
		key: string,
		destination: string,
		theme: Theme,
		requestRender: () => void,
		done: (outcome: SecureCredentialInputOutcome) => void,
	) {
		this.key = key;
		this.destination = destination;
		this.theme = theme;
		this.requestRender = requestRender;
		this.done = done;
		this.editor = new MaskedCredentialEditor();
		this.editor.onSubmit = (value) => this.finish({ kind: "submitted", value });
		this.editor.onCancel = () => this.finish({ kind: "cancelled" });
		this.editor.onEmptySubmit = () => {
			this.errorText = "A non-empty value is required.";
			this.requestRender();
		};
	}

	get focused(): boolean {
		return this._focused;
	}

	set focused(value: boolean) {
		this._focused = value;
		this.editor.focused = value;
	}

	handleInput(data: string): void {
		if (matchesKey(data, Key.escape) || matchesKey(data, Key.ctrl("c"))) {
			this.finish({ kind: "cancelled" });
			return;
		}
		this.editor.handleInput(data);
		this.requestRender();
	}

	render(width: number): string[] {
		const safeWidth = Math.max(1, width);
		const lines: string[] = [];
		const addWrapped = (text: string) => {
			lines.push(...wrapTextWithAnsi(text, safeWidth));
		};

		lines.push(this.theme.fg("borderAccent", "─".repeat(safeWidth)));
		addWrapped(this.theme.fg("accent", `Credential key: ${this.key}`));
		addWrapped(this.theme.fg("muted", `Destination: ${this.destination}`));
		lines.push("");
		lines.push(...this.editor.render(safeWidth));
		lines.push("");
		if (this.errorText) addWrapped(this.theme.fg("warning", this.errorText));
		addWrapped(this.theme.fg("dim", "Enter saves this value. Escape cancels."));
		lines.push(this.theme.fg("borderAccent", "─".repeat(safeWidth)));
		return lines.map((line) => truncateToWidth(line, safeWidth, "", true));
	}

	invalidate(): void {
		this.editor.invalidate();
	}

	dispose(): void {
		this.editor.clear();
	}

	private finish(outcome: SecureCredentialInputOutcome): void {
		if (this.finished) return;
		this.finished = true;
		this.editor.clear();
		this.done(outcome);
	}
}

/** A TUI page that requires an explicit choice before replacing an existing value. */
export class SecureCredentialOverwritePage implements Component {
	private selected: "replace" | "skip" = "skip";
	private finished = false;
	private readonly key: string;
	private readonly destination: string;
	private readonly theme: Theme;
	private readonly requestRender: () => void;
	private readonly done: (outcome: SecureCredentialOverwriteOutcome) => void;

	constructor(
		key: string,
		destination: string,
		theme: Theme,
		requestRender: () => void,
		done: (outcome: SecureCredentialOverwriteOutcome) => void,
	) {
		this.key = key;
		this.destination = destination;
		this.theme = theme;
		this.requestRender = requestRender;
		this.done = done;
	}

	handleInput(data: string): void {
		if (matchesKey(data, Key.escape) || matchesKey(data, Key.ctrl("c"))) {
			this.finish({ kind: "cancelled" });
			return;
		}
		if (matchesKey(data, Key.left) || matchesKey(data, Key.right) || matchesKey(data, Key.tab)) {
			this.selected = this.selected === "skip" ? "replace" : "skip";
			this.requestRender();
			return;
		}
		if (matchesKey(data, Key.enter)) {
			this.finish({ kind: this.selected });
		}
	}

	render(width: number): string[] {
		const safeWidth = Math.max(1, width);
		const lines: string[] = [];
		const addWrapped = (text: string) => {
			lines.push(...wrapTextWithAnsi(text, safeWidth));
		};
		const option = (kind: "replace" | "skip", label: string) => {
			const marker = this.selected === kind ? ">" : " ";
			const color = this.selected === kind ? "accent" : "muted";
			return this.theme.fg(color, `${marker} ${label}`);
		};

		lines.push(this.theme.fg("borderAccent", "─".repeat(safeWidth)));
		addWrapped(this.theme.fg("warning", `Credential key already exists: ${this.key}`));
		addWrapped(this.theme.fg("muted", `Destination: ${this.destination}`));
		lines.push("");
		lines.push(option("skip", "Keep the existing value"));
		lines.push(option("replace", "Replace it"));
		lines.push("");
		addWrapped(this.theme.fg("dim", "Left/Right or Tab chooses. Enter confirms. Escape cancels."));
		lines.push(this.theme.fg("borderAccent", "─".repeat(safeWidth)));
		return lines.map((line) => truncateToWidth(line, safeWidth, "", true));
	}

	invalidate(): void {}

	private finish(outcome: SecureCredentialOverwriteOutcome): void {
		if (this.finished) return;
		this.finished = true;
		this.done(outcome);
	}
}
