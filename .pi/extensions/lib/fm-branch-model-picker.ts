// Ordering and filtering for /supervision-model's bounded, searchable model
// picker. docs/configuration.md owns its operator-facing behavior.
//
// This file holds only the choices Firstmate owns - which entries exist, in
// which order, and which survive a search query - so they stay testable
// without a terminal. The picker's rendering, scrolling, key handling, and
// branch-only component-choice rationale live beside pickBranchModel in
// fm-branch-supervision.ts.

/** One row of the supervision-branch picker. */
export interface BranchPickerItem {
  /** Stable identity of the choice, used to resolve the captain's pick. */
  value: string;
  /** What the row shows, and what a search query is matched against. */
  label: string;
  /** Optional trailing note, such as marking the current choice. */
  description?: string;
}

/** Signature of Pi's own `fuzzyFilter`, injected so this file stays UI-free. */
export type BranchPickerFuzzyFilter = <T>(items: T[], query: string, getText: (item: T) => string) => T[];

/**
 * Rows the picker shows at once. Pi's own model selector shows ten, and the
 * bound is what keeps a long catalog scrolling inside the dialog instead of
 * overflowing the terminal.
 */
export const BRANCH_PICKER_MAX_VISIBLE = 10;

/** The stable identity of the "follow main" row, which is always first. */
export const FOLLOW_MAIN_VALUE = "\0follow-main";

/**
 * Builds the picker's rows: "follow main" first, then the eligible models in
 * the order the caller resolved them. The current choice is marked so the
 * captain can see what is pinned without leaving the dialog.
 */
export function buildBranchModelItems(
  followMainLabel: string,
  modelLabels: readonly string[],
  currentPin: string | null,
): BranchPickerItem[] {
  const followMain: BranchPickerItem = {
    value: FOLLOW_MAIN_VALUE,
    label: followMainLabel,
    ...(currentPin === null ? { description: "current" } : {}),
  };
  return [
    followMain,
    ...modelLabels.map((label) => ({
      value: label,
      label,
      ...(currentPin !== null && label === currentPin ? { description: "current" } : {}),
    })),
  ];
}

/**
 * Applies a search query while keeping "follow main" first. Pi's fuzzy filter
 * ranks by match quality, which would otherwise be free to sort the "follow
 * main" row below a model, so it is filtered separately and prepended
 * whenever it still matches. An empty query keeps the built order.
 */
export function filterBranchPickerItems(
  items: readonly BranchPickerItem[],
  query: string,
  fuzzy: BranchPickerFuzzyFilter,
): BranchPickerItem[] {
  const trimmed = query.trim();
  if (trimmed === "") return [...items];
  const followMain = items.find((item) => item.value === FOLLOW_MAIN_VALUE);
  const rest = items.filter((item) => item.value !== FOLLOW_MAIN_VALUE);
  const matched = fuzzy([...rest], trimmed, (item) => item.label);
  if (!followMain) return matched;
  const followMainMatches = fuzzy([followMain], trimmed, (item) => item.label).length > 0;
  return followMainMatches ? [followMain, ...matched] : matched;
}
