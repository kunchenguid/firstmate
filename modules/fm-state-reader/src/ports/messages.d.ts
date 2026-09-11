export type MessageKind = 'request' | 'reply' | 'note' | 'needs-decision';
/** Shared runtime codec: bin/fm-task-inbox-lib.sh. No adapter-specific wire shape. */
export interface Message {
  schema: 'fm-message.v1';
  id: string;
  thread: string | null;
  at: string;
  from: string;
  to: string[];
  kind: MessageKind;
  ref: string | null;
  text: string;
}
export interface MessageOptions { thread?: string; kind?: MessageKind; ref?: string }
export interface MessageReceipt { id: string; thread: string; delivered: string[]; partial: boolean }
export interface MessageEntry { name: string; message: Message }
export interface MessagePort {
  send(to: string[], text: string, options?: MessageOptions): Promise<MessageReceipt>;
  reply(ref: string, text: string): Promise<MessageReceipt>;
  retry(id: string, thread: string): Promise<MessageReceipt>;
  receive(): Promise<MessageEntry[]>;
  acknowledge(name: string): Promise<void>;
}
