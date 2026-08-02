// Firstmate's primary-only structured questions tool.
//
// This extension owns only local presentation and answer collection.
// Durable decisions, authority, backlog records, and worker escalation remain outside this file.
// The tool is registered from session_start only after Pi proves TUI mode and the primary scope.
// The private marker is intentionally read from the canonical project root and is never created here.
// PX08 can use the focused test's deterministic payload in a disposable primary checkout.
// That demo creates its marker only in temporary test state and never enables this repository.

import { lstatSync, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  getMarkdownTheme,
  type ExtensionAPI,
  type ExtensionMode,
  type Theme,
  type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import {
  Editor,
  Key,
  Markdown,
  matchesKey,
  type Component,
  type EditorTheme,
  type Focusable,
  type TUI,
  truncateToWidth,
  visibleWidth,
  wrapTextWithAnsi,
} from "@earendil-works/pi-tui";
import { Type, type Static } from "typebox";

const ASK_USER_MARKER_NAME = "ask-user-tui";
const SECOND_MATE_MARKER_NAME = ".fm-secondmate-home";
const COLUMN_DIVIDER = " │ ";
const FREE_TEXT_OPTION_ID = "__free_text__";

const AskUserOptionSchema = Type.Object({
  id: Type.String({
    description: "Stable option identifier returned in selectedOptionIds.",
  }),
  label: Type.String({
    description: "Short user-facing option label.",
  }),
  description: Type.Optional(
    Type.String({
      description: "Optional explanation of the consequence or tradeoff.",
    }),
  ),
  preview: Type.Optional(
    Type.String({
      description: "Optional Markdown preview shown when this option is focused.",
    }),
  ),
  recommended: Type.Optional(
    Type.Boolean({
      description: "Marks this option as recommended without selecting it.",
    }),
  ),
});

const AskUserQuestionSchema = Type.Object({
  id: Type.String({
    description: "Stable question identifier returned in questionId.",
  }),
  header: Type.Optional(
    Type.String({
      description: "Optional short heading shown on the question page.",
    }),
  ),
  question: Type.String({
    description: "Question text shown to the captain.",
  }),
  options: Type.Optional(
    Type.Array(AskUserOptionSchema, {
      description: "Optional choices. Omit this field for a free-text-only question.",
    }),
  ),
  allowMultiple: Type.Optional(
    Type.Boolean({
      description: "Allow several option IDs to be selected with Space before Enter.",
    }),
  ),
  allowFreeText: Type.Optional(
    Type.Boolean({
      description: "Add a free-text answer path. Defaults to true.",
    }),
  ),
});

const AskUserQuestionsParamsSchema = Type.Object({
  questions: Type.Array(AskUserQuestionSchema, {
    description: "Questions to show one page at a time in the primary TUI.",
  }),
});

export type AskUserOption = Static<typeof AskUserOptionSchema>;
export type AskUserQuestion = Static<typeof AskUserQuestionSchema>;
export type AskUserQuestionsParams = Static<typeof AskUserQuestionsParamsSchema>;

/** One structured answer containing stable IDs and optional captain-entered free text. */
export interface AskUserQuestionAnswer {
  questionId: string;
  selectedOptionIds: string[];
  freeText?: string;
}

/** The answer payload returned by ask_user_questions when the TUI is submitted. */
export interface AskUserQuestionsResponse {
  answers: AskUserQuestionAnswer[];
}

/** Tool details distinguish deliberate cancellation, external abort, and submission. */
export interface AskUserQuestionsDetails {
  response: AskUserQuestionsResponse | null;
  cancelled: boolean;
  aborted: boolean;
  error?: string;
}

type NormalizedOption = {
  id: string;
  label: string;
  description?: string;
  preview?: string;
  recommended: boolean;
};

type NormalizedQuestion = {
  id: string;
  header: string;
  prompt: string;
  options: NormalizedOption[];
  allowMultiple: boolean;
  allowFreeText: boolean;
};

type QuestionState = {
  cursorIndex: number;
  selectedOptionIds: Set<string>;
  freeText: string;
  freeTextError?: string;
};

type OptionItem = NormalizedOption & { kind: "option" };

type FreeTextItem = {
  kind: "free-text";
  id: typeof FREE_TEXT_OPTION_ID;
  label: string;
  description: string;
};

type QuestionItem = OptionItem | FreeTextItem;

type AskUserQuestionsUiOutcome =
  | { kind: "submitted"; response: AskUserQuestionsResponse }
  | { kind: "cancelled"; aborted: boolean };

type NormalizationResult =
  | { questions: NormalizedQuestion[] }
  | { error: string };

const extensionRoot = canonicalPath(resolve(dirname(fileURLToPath(import.meta.url)), "../.."));

function canonicalPath(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return resolve(path);
  }
}

function hasPathEntry(path: string): boolean {
  try {
    lstatSync(path);
    return true;
  } catch {
    return false;
  }
}

function isRegularNonSymlinkFile(path: string): boolean {
  try {
    const stat = lstatSync(path);
    return stat.isFile() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
}

function isDirectory(path: string): boolean {
  try {
    return lstatSync(path).isDirectory();
  } catch {
    return false;
  }
}

function hasSecondmateHomeMarker(root: string): boolean {
  return hasPathEntry(join(root, SECOND_MATE_MARKER_NAME));
}

function isPlainGitCheckout(root: string): boolean {
  const gitDir = spawnSync("git", ["-C", root, "rev-parse", "--git-dir"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  const commonDir = spawnSync("git", ["-C", root, "rev-parse", "--git-common-dir"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (gitDir.status !== 0 || commonDir.status !== 0) return false;
  return gitDir.stdout.trim() === commonDir.stdout.trim();
}

/**
 * Checks the primary TUI activation contract without trusting FM_HOME or other environment values.
 */
export function isAskUserTuiEligible(cwd: string, mode: ExtensionMode = "tui"): boolean {
  if (mode !== "tui") return false;

  const canonicalCwd = canonicalPath(cwd);
  if (canonicalCwd !== extensionRoot) return false;
  if (hasSecondmateHomeMarker(canonicalCwd)) return false;
  if (!isRegularNonSymlinkFile(join(canonicalCwd, "AGENTS.md"))) return false;
  if (!isDirectory(join(canonicalCwd, "bin"))) return false;
  if (!isRegularNonSymlinkFile(join(canonicalCwd, "bin", "fm-session-start.sh"))) return false;
  if (!isPlainGitCheckout(canonicalCwd)) return false;
  if (!isDirectory(join(canonicalCwd, "config"))) return false;

  const markerPath = join(canonicalCwd, "config", ASK_USER_MARKER_NAME);
  return isRegularNonSymlinkFile(markerPath);
}

function normalizeQuestions(params: AskUserQuestionsParams): NormalizationResult {
  if (!params || !Array.isArray(params.questions) || params.questions.length === 0) {
    return { error: "ask_user_questions requires at least one question" };
  }

  const questionIds = new Set<string>();
  const questions: NormalizedQuestion[] = [];

  for (const question of params.questions) {
    if (!question || typeof question !== "object") {
      return { error: "ask_user_questions received a malformed question" };
    }
    if (typeof question.id !== "string" || question.id.length === 0) {
      return { error: "ask_user_questions requires a non-empty question id" };
    }
    if (questionIds.has(question.id)) {
      return { error: `ask_user_questions received duplicate question id: ${question.id}` };
    }
    questionIds.add(question.id);

    if (typeof question.question !== "string" || question.question.trim().length === 0) {
      return { error: `ask_user_questions received empty question text: ${question.id}` };
    }

    const allowFreeText = question.allowFreeText !== false;
    const rawOptions = question.options;
    if (rawOptions !== undefined && !Array.isArray(rawOptions)) {
      return { error: `ask_user_questions received malformed options: ${question.id}` };
    }
    if (rawOptions !== undefined && rawOptions.length === 0 && !allowFreeText) {
      return { error: `ask_user_questions received empty options: ${question.id}` };
    }
    if (rawOptions === undefined && !allowFreeText) {
      return { error: `ask_user_questions needs options or free text: ${question.id}` };
    }

    const optionIds = new Set<string>();
    const options: NormalizedOption[] = [];
    for (const option of rawOptions ?? []) {
      if (!option || typeof option !== "object") {
        return { error: `ask_user_questions received malformed option: ${question.id}` };
      }
      if (typeof option.id !== "string" || option.id.length === 0) {
        return { error: `ask_user_questions requires a non-empty option id: ${question.id}` };
      }
      if (option.id === FREE_TEXT_OPTION_ID) {
        return { error: `ask_user_questions reserves the free-text option id: ${option.id}` };
      }
      if (optionIds.has(option.id)) {
        return { error: `ask_user_questions received duplicate option id: ${option.id}` };
      }
      optionIds.add(option.id);
      if (typeof option.label !== "string" || option.label.trim().length === 0) {
        return { error: `ask_user_questions received empty option label: ${option.id}` };
      }
      if (option.description !== undefined && typeof option.description !== "string") {
        return { error: `ask_user_questions received malformed option description: ${option.id}` };
      }
      if (option.preview !== undefined && typeof option.preview !== "string") {
        return { error: `ask_user_questions received malformed Markdown preview: ${option.id}` };
      }
      if (option.recommended !== undefined && typeof option.recommended !== "boolean") {
        return { error: `ask_user_questions received malformed recommendation: ${option.id}` };
      }
      options.push({
        id: option.id,
        label: option.label,
        description: option.description,
        preview: option.preview,
        recommended: option.recommended === true,
      });
    }

    questions.push({
      id: question.id,
      header:
        typeof question.header === "string" && question.header.trim().length > 0
          ? question.header
          : question.id,
      prompt: question.question,
      options,
      allowMultiple: question.allowMultiple === true,
      allowFreeText,
    });
  }

  return { questions };
}

function cancelledResult(aborted: boolean, error?: string): {
  content: [{ type: "text"; text: string }];
  details: AskUserQuestionsDetails;
} {
  const text = error
    ? error
    : aborted
      ? "ask_user_questions was interrupted before receiving a response"
      : "ask_user_questions was cancelled before receiving a response";
  return {
    content: [{ type: "text", text }],
    details: { response: null, cancelled: true, aborted, ...(error ? { error } : {}) },
  };
}

function submittedResult(response: AskUserQuestionsResponse): {
  content: [{ type: "text"; text: string }];
  details: AskUserQuestionsDetails;
} {
  return {
    content: [{ type: "text", text: JSON.stringify(response) }],
    details: { response, cancelled: false, aborted: false },
  };
}

function isRecommendedOption(option: NormalizedOption): boolean {
  return option.recommended || /\(\s*recommended\s*\)\s*$/i.test(option.label);
}

function padLine(line: string, width: number): string {
  return line + " ".repeat(Math.max(0, width - visibleWidth(line)));
}

function wrapToWidth(text: string, width: number): string[] {
  const safeWidth = Math.max(1, width);
  return wrapTextWithAnsi(text, safeWidth).map((line) => truncateToWidth(line, safeWidth, ""));
}

class AskUserQuestionsScreen implements Component, Focusable {
  private readonly tui: TUI;
  private readonly theme: Theme;
  private readonly questions: NormalizedQuestion[];
  private readonly states: QuestionState[];
  private readonly done: (result: AskUserQuestionsUiOutcome) => void;
  private readonly editor: Editor;
  private readonly removeAbortListener: (() => void) | undefined;
  private _focused = false;
  private currentPage = 0;
  private showingReview = false;
  private freeTextMode = false;
  private pageScroll = 0;
  private lastViewport = 1;
  private lastMaxScroll = 0;
  private cachedWidth: number | undefined;
  private cachedLines: string[] | undefined;
  private finished = false;
  private disposed = false;

  constructor(
    tui: TUI,
    theme: Theme,
    questions: NormalizedQuestion[],
    signal: AbortSignal | undefined,
    done: (result: AskUserQuestionsUiOutcome) => void,
  ) {
    this.tui = tui;
    this.theme = theme;
    this.questions = questions;
    this.done = done;
    this.states = questions.map(() => ({ cursorIndex: 0, selectedOptionIds: new Set(), freeText: "" }));

    const editorTheme: EditorTheme = {
      borderColor: (text: string) => theme.fg("accent", text),
      selectList: {
        selectedPrefix: (text: string) => theme.fg("accent", text),
        selectedText: (text: string) => theme.fg("accent", text),
        description: (text: string) => theme.fg("muted", text),
        scrollInfo: (text: string) => theme.fg("dim", text),
        noMatch: (text: string) => theme.fg("warning", text),
      },
    };
    this.editor = new Editor(tui, editorTheme);
    this.editor.onChange = (text) => {
      const state = this.states[this.currentPage];
      if (!state) return;
      state.freeText = text;
      state.freeTextError = undefined;
      this.refresh();
    };
    this.editor.onSubmit = (text) => {
      this.submitFreeText(text);
    };

    if (signal) {
      const onAbort = () => {
        this.finish({ kind: "cancelled", aborted: true });
      };
      if (signal.aborted) {
        onAbort();
      } else {
        signal.addEventListener("abort", onAbort, { once: true });
        this.removeAbortListener = () => signal.removeEventListener("abort", onAbort);
      }
    }

    const currentQuestion = this.questions[0];
    if (currentQuestion && currentQuestion.options.length === 0 && currentQuestion.allowFreeText) {
      this.enterFreeText();
    }
  }

  get focused(): boolean {
    return this._focused;
  }

  set focused(value: boolean) {
    this._focused = value;
    this.syncEditorFocus();
  }

  handleInput(data: string): void {
    if (this.finished || this.disposed) return;

    if (this.freeTextMode) {
      if (matchesKey(data, Key.escape) || matchesKey(data, Key.ctrl("c"))) {
        this.finish({ kind: "cancelled", aborted: false });
        return;
      }
      this.editor.handleInput(data);
      this.refresh();
      return;
    }

    if (this.showingReview) {
      this.handleReviewInput(data);
      return;
    }

    if (matchesKey(data, Key.escape) || matchesKey(data, Key.ctrl("c"))) {
      this.finish({ kind: "cancelled", aborted: false });
      return;
    }
    if (matchesKey(data, Key.left) || matchesKey(data, Key.shift("tab"))) {
      this.movePage(-1);
      return;
    }
    if (matchesKey(data, Key.right) || matchesKey(data, Key.tab)) {
      this.movePage(1);
      return;
    }
    if (matchesKey(data, Key.pageUp)) {
      this.pageScroll = Math.max(0, this.pageScroll - this.lastViewport);
      this.refresh();
      return;
    }
    if (matchesKey(data, Key.pageDown)) {
      this.pageScroll = Math.min(this.lastMaxScroll, this.pageScroll + this.lastViewport);
      this.refresh();
      return;
    }
    if (matchesKey(data, Key.home)) {
      this.pageScroll = 0;
      this.refresh();
      return;
    }
    if (matchesKey(data, Key.end)) {
      this.pageScroll = this.lastMaxScroll;
      this.refresh();
      return;
    }

    const question = this.currentQuestion();
    if (!question) return;
    const items = this.questionItems(question);
    const state = this.states[this.currentPage]!;

    if (matchesKey(data, Key.up)) {
      state.cursorIndex = (state.cursorIndex - 1 + items.length) % items.length;
      state.freeTextError = undefined;
      this.pageScroll = 0;
      this.refresh();
      return;
    }
    if (matchesKey(data, Key.down)) {
      state.cursorIndex = (state.cursorIndex + 1) % items.length;
      state.freeTextError = undefined;
      this.pageScroll = 0;
      this.refresh();
      return;
    }
    if (question.allowMultiple && matchesKey(data, Key.space)) {
      const item = items[state.cursorIndex];
      if (item && item.kind !== "free-text") {
        if (state.selectedOptionIds.has(item.id)) state.selectedOptionIds.delete(item.id);
        else state.selectedOptionIds.add(item.id);
        state.freeTextError = undefined;
        this.refresh();
      }
      return;
    }
    if (matchesKey(data, Key.enter)) {
      this.commitCurrentItem();
    }
  }

  render(width: number): string[] {
    const renderWidth = Math.max(1, width);
    if (this.cachedLines && this.cachedWidth === renderWidth) return this.cachedLines;

    const header = this.renderHeader(renderWidth);
    const footer = this.renderFooter(renderWidth);
    const body = this.showingReview ? this.renderReviewBody(renderWidth) : this.renderQuestionBody(renderWidth);
    const terminalRows = this.tui.terminal?.rows;
    const stdoutRows = process.stdout.rows;
    const rows =
      typeof terminalRows === "number" && terminalRows > 0
        ? terminalRows
        : typeof stdoutRows === "number" && stdoutRows > 0
          ? stdoutRows
          : header.length + body.length + footer.length;
    const viewport = Math.max(1, rows - header.length - footer.length);
    this.lastViewport = viewport;
    this.lastMaxScroll = Math.max(0, body.length - viewport);
    this.pageScroll = Math.min(this.pageScroll, this.lastMaxScroll);

    const visibleBody = body.slice(this.pageScroll, this.pageScroll + viewport);
    if (this.lastMaxScroll > 0 && visibleBody.length > 0) {
      if (this.pageScroll > 0) {
        visibleBody[0] = truncateToWidth(
          this.theme.fg("dim", `↑ ${this.pageScroll} more`),
          renderWidth,
          "",
        );
      }
      const hiddenBelow = body.length - (this.pageScroll + visibleBody.length);
      if (hiddenBelow > 0) {
        visibleBody[visibleBody.length - 1] = truncateToWidth(
          this.theme.fg("dim", `↓ ${hiddenBelow} more · PgUp/PgDn`),
          renderWidth,
          "",
        );
      }
    }

    const lines = [...header, ...visibleBody, ...footer].map((line) => truncateToWidth(line, renderWidth, ""));
    this.cachedWidth = renderWidth;
    this.cachedLines = lines;
    return lines;
  }

  invalidate(): void {
    this.cachedWidth = undefined;
    this.cachedLines = undefined;
    this.editor.invalidate();
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.removeAbortListener?.();
    this.editor.onChange = undefined;
    this.editor.onSubmit = undefined;
  }

  private currentQuestion(): NormalizedQuestion | undefined {
    return this.questions[this.currentPage];
  }

  private questionItems(question: NormalizedQuestion): QuestionItem[] {
    const items: QuestionItem[] = question.options.map((option) => ({ ...option, kind: "option" as const }));
    if (question.allowFreeText) {
      items.push({
        kind: "free-text",
        id: FREE_TEXT_OPTION_ID,
        label: "Write a free-text answer",
        description: "Type an answer in your own words.",
      });
    }
    return items;
  }

  private currentState(): QuestionState {
    return this.states[this.currentPage]!;
  }

  private currentItem(): QuestionItem | undefined {
    const question = this.currentQuestion();
    if (!question) return undefined;
    return this.questionItems(question)[this.currentState().cursorIndex];
  }

  private isAnswered(state: QuestionState): boolean {
    return state.selectedOptionIds.size > 0 || state.freeText.trim().length > 0;
  }

  private allAnswered(): boolean {
    return this.states.every((state) => this.isAnswered(state));
  }

  private movePage(direction: -1 | 1): void {
    if (this.questions.length === 0) return;
    this.freeTextMode = false;
    this.syncEditorFocus();
    this.currentPage = (this.currentPage + direction + this.questions.length) % this.questions.length;
    const question = this.currentQuestion();
    const items = question ? this.questionItems(question) : [];
    const state = this.currentState();
    state.cursorIndex = Math.min(state.cursorIndex, Math.max(0, items.length - 1));
    this.pageScroll = 0;
    this.refresh();
  }

  private commitCurrentItem(): void {
    const question = this.currentQuestion();
    const state = this.currentState();
    const item = this.currentItem();
    if (!question || !item) return;

    if (item.kind === "free-text") {
      this.enterFreeText();
      return;
    }

    if (question.allowMultiple) {
      if (!this.isAnswered(state)) {
        state.freeTextError = "Select at least one option or write a free-text answer.";
        this.refresh();
        return;
      }
      this.advanceAfterAnswer();
      return;
    }

    state.selectedOptionIds = new Set([item.id]);
    state.freeText = "";
    state.freeTextError = undefined;
    this.advanceAfterAnswer();
  }

  private enterFreeText(): void {
    const state = this.currentState();
    this.freeTextMode = true;
    state.freeTextError = undefined;
    this.editor.setText(state.freeText);
    this.syncEditorFocus();
    this.refresh();
  }

  private submitFreeText(text: string): void {
    const state = this.currentState();
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      state.freeTextError = "Free-text answers cannot be empty.";
      this.refresh();
      return;
    }
    state.freeText = trimmed;
    state.selectedOptionIds = this.currentQuestion()?.allowMultiple ? state.selectedOptionIds : new Set();
    state.freeTextError = undefined;
    this.freeTextMode = false;
    this.syncEditorFocus();
    this.advanceAfterAnswer();
  }

  private advanceAfterAnswer(): void {
    this.pageScroll = 0;
    if (this.currentPage < this.questions.length - 1) {
      this.currentPage += 1;
      this.freeTextMode = false;
      const question = this.currentQuestion();
      const items = question ? this.questionItems(question) : [];
      this.currentState().cursorIndex = Math.min(this.currentState().cursorIndex, Math.max(0, items.length - 1));
      this.syncEditorFocus();
      this.refresh();
      return;
    }
    if (this.allAnswered()) {
      this.showingReview = true;
      this.freeTextMode = false;
      this.syncEditorFocus();
      this.refresh();
      return;
    }
    this.refresh();
  }

  private handleReviewInput(data: string): void {
    if (matchesKey(data, Key.escape) || matchesKey(data, Key.ctrl("c"))) {
      this.finish({ kind: "cancelled", aborted: false });
      return;
    }
    if (matchesKey(data, Key.left)) {
      this.showingReview = false;
      this.currentPage = this.questions.length - 1;
      this.pageScroll = 0;
      this.refresh();
      return;
    }
    if (matchesKey(data, Key.pageUp)) {
      this.pageScroll = Math.max(0, this.pageScroll - this.lastViewport);
      this.refresh();
      return;
    }
    if (matchesKey(data, Key.pageDown)) {
      this.pageScroll = Math.min(this.lastMaxScroll, this.pageScroll + this.lastViewport);
      this.refresh();
      return;
    }
    if ((matchesKey(data, Key.enter) || matchesKey(data, Key.right)) && this.allAnswered()) {
      this.finish({ kind: "submitted", response: this.buildResponse() });
    }
  }

  private buildResponse(): AskUserQuestionsResponse {
    const answers: AskUserQuestionAnswer[] = [];
    for (let index = 0; index < this.questions.length; index += 1) {
      const question = this.questions[index]!;
      const state = this.states[index]!;
      const selectedOptionIds = question.options
        .filter((option) => state.selectedOptionIds.has(option.id))
        .map((option) => option.id);
      const freeText = state.freeText.trim();
      answers.push({
        questionId: question.id,
        selectedOptionIds,
        ...(freeText.length > 0 ? { freeText } : {}),
      });
    }
    return { answers };
  }

  private finish(outcome: AskUserQuestionsUiOutcome): void {
    if (this.finished || this.disposed) return;
    this.finished = true;
    this.removeAbortListener?.();
    this.done(outcome);
  }

  private syncEditorFocus(): void {
    this.editor.focused = this._focused && this.freeTextMode;
  }

  private refresh(): void {
    this.cachedWidth = undefined;
    this.cachedLines = undefined;
    this.tui.requestRender();
  }

  private renderHeader(width: number): string[] {
    const question = this.currentQuestion();
    const title = this.showingReview
      ? "Review answers"
      : `${question?.header ?? "Question"}  ${this.currentPage + 1}/${this.questions.length}`;
    const pageStates = this.questions.map((item, index) => {
      const state = this.states[index]!;
      const marker = this.isAnswered(state) ? "●" : "○";
      const color = this.isAnswered(state) ? "success" : "muted";
      return index === this.currentPage && !this.showingReview
        ? this.theme.fg("accent", `[${marker} ${item.header}]`)
        : this.theme.fg(color, `${marker} ${item.header}`);
    });
    const rows = [
      this.theme.fg("borderAccent", "─".repeat(width)),
      truncateToWidth(`${this.theme.fg("accent", this.theme.bold(title))}  ${pageStates.join("  ")}`, width, ""),
      "",
    ];
    return rows;
  }

  private renderFooter(width: number): string[] {
    const hint = this.showingReview
      ? "Enter submit · Left edit · Esc cancel · PgUp/PgDn scroll"
      : this.freeTextMode
        ? "Enter confirm text · Esc cancel · PgUp/PgDn scroll"
        : this.currentQuestion()?.allowMultiple
          ? "↑↓ focus · Space toggle · Enter next · Tab page · Esc cancel"
          : "↑↓ focus · Enter choose · Tab page · Esc cancel";
    return ["", ...wrapToWidth(this.theme.fg("dim", hint), width), this.theme.fg("borderAccent", "─".repeat(width))];
  }

  private renderQuestionBody(width: number): string[] {
    const question = this.currentQuestion();
    if (!question) return [this.theme.fg("error", "No question is available.")];
    const state = this.currentState();
    const items = this.questionItems(question);
    const currentItem = items[state.cursorIndex];
    const preview = currentItem && currentItem.kind !== "free-text" ? currentItem.preview?.trim() : undefined;
    const dividerWidth = visibleWidth(COLUMN_DIVIDER);
    const leftWidth = Math.max(1, Math.floor((width - dividerWidth) / 2));
    const rightWidth = Math.max(1, width - dividerWidth - leftWidth);

    const left = this.renderQuestionColumn(question, state, items, leftWidth);
    if (!preview || leftWidth <= 1 || rightWidth <= 1) {
      const stacked = [...this.renderQuestionColumn(question, state, items, width)];
      if (preview) {
        stacked.push("");
        stacked.push(this.theme.fg("accent", "Preview"));
        stacked.push(...this.renderMarkdown(preview, width));
      }
      return stacked;
    }

    const right = [this.theme.fg("accent", "Preview"), ...this.renderMarkdown(preview, rightWidth)];
    const lineCount = Math.max(left.length, right.length);
    const merged: string[] = [];
    for (let index = 0; index < lineCount; index += 1) {
      const leftLine = padLine(truncateToWidth(left[index] ?? "", leftWidth, ""), leftWidth);
      const rightLine = truncateToWidth(right[index] ?? "", rightWidth, "");
      merged.push(leftLine + this.theme.fg("dim", COLUMN_DIVIDER) + rightLine);
    }
    return merged;
  }

  private renderQuestionColumn(
    question: NormalizedQuestion,
    state: QuestionState,
    items: QuestionItem[],
    width: number,
  ): string[] {
    const lines: string[] = [];
    lines.push(...wrapToWidth(this.theme.fg("text", question.prompt), width));
    if (question.allowMultiple) lines.push(...wrapToWidth(this.theme.fg("muted", "Select all that apply."), width));
    lines.push("");

    for (let index = 0; index < items.length; index += 1) {
      const item = items[index]!;
      const focused = index === state.cursorIndex && !this.freeTextMode;
      if (item.kind === "free-text") {
        const entered = state.freeText.trim().length > 0;
        const prefix = entered ? "✎ " : "✎ ";
        const label = `${prefix}${item.label}`;
        const styled = focused
          ? this.theme.fg("accent", `> ${label}`)
          : this.theme.fg(entered ? "success" : "text", `  ${label}`);
        lines.push(...wrapToWidth(styled, width));
        lines.push(...wrapToWidth(this.theme.fg("muted", `    ${item.description}`), width));
        continue;
      }

      const checked = state.selectedOptionIds.has(item.id);
      const marker = question.allowMultiple ? (checked ? "☑" : "☐") : (checked ? "●" : "○");
      const recommendation = isRecommendedOption(item) ? this.theme.fg("success", " (recommended)") : "";
      const label = `${marker} ${item.label}${recommendation}`;
      const styled = focused
        ? this.theme.fg("accent", `> ${label}`)
        : this.theme.fg(checked ? "success" : "text", `  ${label}`);
      lines.push(...wrapToWidth(styled, width));
      if (item.description) lines.push(...wrapToWidth(this.theme.fg("muted", `    ${item.description}`), width));
    }

    if (this.freeTextMode) {
      lines.push("");
      lines.push(this.theme.fg("muted", "Your free-text answer:"));
      lines.push(...this.editor.render(Math.max(1, width - 2)).map((line) => truncateToWidth(` ${line}`, width, "")));
      if (state.freeTextError) lines.push(...wrapToWidth(this.theme.fg("warning", state.freeTextError), width));
    } else if (state.freeText.trim().length > 0) {
      lines.push("");
      lines.push(...wrapToWidth(this.theme.fg("muted", `Free text: ${state.freeText.trim()}`), width));
    } else if (state.freeTextError) {
      lines.push("");
      lines.push(...wrapToWidth(this.theme.fg("warning", state.freeTextError), width));
    }

    return lines;
  }

  private renderReviewBody(width: number): string[] {
    const lines: string[] = [this.theme.fg("text", "Review the structured answers before submission."), ""];
    for (let index = 0; index < this.questions.length; index += 1) {
      const question = this.questions[index]!;
      const state = this.states[index]!;
      const selected = question.options
        .filter((option) => state.selectedOptionIds.has(option.id))
        .map((option) => `${option.id}: ${option.label}`);
      if (selected.length === 0) selected.push("(none)");
      lines.push(...wrapToWidth(this.theme.fg("accent", question.id), width));
      lines.push(...wrapToWidth(this.theme.fg("muted", question.prompt), width));
      for (const value of selected) lines.push(...wrapToWidth(`  ${value}`, width));
      if (state.freeText.trim().length > 0) {
        lines.push(...wrapToWidth(`  freeText: ${state.freeText.trim()}`, width));
      }
      lines.push("");
    }
    if (this.allAnswered()) lines.push(this.theme.fg("success", "All questions have answers."));
    else lines.push(this.theme.fg("warning", "Some questions still need an answer."));
    return lines;
  }

  private renderMarkdown(markdown: string, width: number): string[] {
    const component = new Markdown(markdown, 0, 0, getMarkdownTheme());
    return component.render(Math.max(1, width)).map((line) => truncateToWidth(line, Math.max(1, width), ""));
  }
}

function createAskUserQuestionsTool(): ToolDefinition<typeof AskUserQuestionsParamsSchema, AskUserQuestionsDetails> {
  return {
    name: "ask_user_questions",
    label: "Ask user questions",
    description:
      "Present structured questions to the captain in the primary TUI and return stable option IDs plus optional free text. This tool collects answers only and never approves or records a durable decision.",
    promptSnippet: "Ask the captain structured local TUI questions before proceeding, without deciding or recording authority.",
    promptGuidelines: [
      "Use ask_user_questions only in the eligible primary TUI when a concrete choice needs captain input.",
      "Use stable question and option IDs so the structured answer can be mapped without relying on labels.",
      "Mark recommended options with recommended: true and explain the consequence or tradeoff in description. ask_user_questions never preselects recommendations.",
      "Use allowMultiple: true when several option IDs can be selected. Use allowFreeText for a question that needs an answer in the captain's own words.",
      "Use preview for concise Markdown that helps compare the focused option. The preview is local UI content and is not an approval or decision record.",
      "Do not use ask_user_questions for merge, discard, security, credentials, messaging, or irreversible approval. Durable decisions remain with Firstmate authority and decision-hold-lifecycle.",
    ],
    parameters: AskUserQuestionsParamsSchema,
    executionMode: "sequential",
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      if (!isAskUserTuiEligible(ctx.cwd, ctx.mode)) {
        return cancelledResult(false, "ask_user_questions is available only in the marked main-primary TUI");
      }
      if (signal?.aborted) return cancelledResult(true);

      const normalized = normalizeQuestions(params);
      if ("error" in normalized) return cancelledResult(false, normalized.error);

      let screen: AskUserQuestionsScreen | undefined;
      const outcome = await ctx.ui.custom<AskUserQuestionsUiOutcome>((tui, theme, _keybindings, done) => {
        screen = new AskUserQuestionsScreen(tui, theme, normalized.questions, signal, done);
        return screen;
      });
      screen?.dispose();

      if (!outcome || outcome.kind === "cancelled") {
        return cancelledResult(outcome?.kind === "cancelled" ? outcome.aborted : signal?.aborted === true);
      }
      return submittedResult(outcome.response);
    },
    renderCall(args, theme) {
      const questionCount = Array.isArray(args.questions) ? args.questions.length : 0;
      const headers = Array.isArray(args.questions)
        ? args.questions
            .map((question) => (typeof question.header === "string" && question.header ? question.header : question.id))
            .join(", ")
        : "";
      let text = theme.fg("toolTitle", theme.bold("ask_user_questions "));
      text += theme.fg("muted", `${questionCount} question${questionCount === 1 ? "" : "s"}`);
      if (headers) text += theme.fg("dim", ` (${headers})`);
      return new (class implements Component {
        render(width: number): string[] {
          return wrapToWidth(text, width);
        }
        invalidate(): void {}
      })();
    },
    renderResult(result, _options, theme) {
      const details = result.details;
      if (details.cancelled) {
        return new (class implements Component {
          render(): string[] {
            return [theme.fg("warning", details.aborted ? "Interrupted" : "Cancelled")];
          }
          invalidate(): void {}
        })();
      }

      const response = details.response;
      if (!response) {
        return new (class implements Component {
          render(): string[] {
            return [theme.fg("error", "ask_user_questions returned no response")];
          }
          invalidate(): void {}
        })();
      }

      const lines = response.answers.map((answer) => {
        const selected = answer.selectedOptionIds.length > 0 ? answer.selectedOptionIds.join(", ") : "(free text)";
        const freeText = answer.freeText ? ` ${theme.fg("muted", `freeText: ${answer.freeText}`)}` : "";
        return `${theme.fg("success", "✓ ")}${theme.fg("accent", answer.questionId)}: ${selected}${freeText}`;
      });
      return new (class implements Component {
        render(width: number): string[] {
          return lines.flatMap((line) => wrapToWidth(line, width));
        }
        invalidate(): void {}
      })();
    },
  };
}

export default function fmAskUserTui(pi: ExtensionAPI): void {
  let registered = false;

  pi.on("session_start", async (_event, ctx) => {
    if (registered || !isAskUserTuiEligible(ctx.cwd, ctx.mode)) return;
    pi.registerTool(createAskUserQuestionsTool());
    registered = true;
  });
}
