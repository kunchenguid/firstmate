import React from "react";

export interface TextFieldProps extends Omit<React.InputHTMLAttributes<HTMLInputElement>, "onChange"> {
  label?: string;
  value?: string;
  onChange?: (value: string) => void;
  placeholder?: string;
  /** Use the terminal monospace font (commands, session names). */
  mono?: boolean;
  /** Leading icon/adornment node. */
  leading?: React.ReactNode;
  /** Helper text below the field. */
  footnote?: string;
}

/**
 * Grouped form text field — host, username, tmux command draft.
 * @dsCard group="Components"
 */
export function TextField(props: TextFieldProps): JSX.Element;
