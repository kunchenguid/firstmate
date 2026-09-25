import { JevClient, type JevClientOptions } from './client.ts';
import { compact } from './compact.ts';
import type { CompactOptions, CompactResult, Message } from './types.ts';

export type CompactMessagesOptions = CompactOptions & JevClientOptions;

/** `compact` with a `JevClient` built from the options (key from `TYPESAFE_API_KEY` by default). */
export function compactMessages(
  messages: readonly Message[],
  options: CompactMessagesOptions = {},
): Promise<CompactResult> {
  return compact(messages, new JevClient(options), options);
}
