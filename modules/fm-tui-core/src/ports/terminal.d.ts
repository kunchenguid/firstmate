export interface Terminal {
  readonly tty: boolean;
  readonly color: boolean;
  write(text: string): void;
}
