import React from "react";

export interface SwitchProps extends Omit<React.HTMLAttributes<HTMLButtonElement>, "onChange"> {
  checked?: boolean;
  onChange?: (next: boolean) => void;
  disabled?: boolean;
}

/**
 * iOS-style toggle switch (mint when on).
 * @dsCard group="Components"
 */
export function Switch(props: SwitchProps): JSX.Element;
