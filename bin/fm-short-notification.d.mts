export const SHORT_RESULT_INLINE_CHARACTERS: 4096;
export const SHORT_RESULT_NOTICE_CHARACTERS: 1024;
export const SHORT_RESULT_LOADED_EVENT: 'firstmate:short-result-loaded';
export function successfulNotification(home: string, id: string): string | null;
export function successfulInlineNotification(home: string, id: string): string | null;
export function successfulResultSummary(home: string, id: string): string | null;
