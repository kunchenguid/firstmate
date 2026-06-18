import React from "react";

export interface SegmentOption {
  label: string;
  value: string;
}

export interface SegmentedControlProps extends Omit<React.HTMLAttributes<HTMLDivElement>, "onChange"> {
  /** Options as strings or {label, value}. */
  options: Array<string | SegmentOption>;
  /** Currently-selected value. */
  value: string;
  onChange?: (value: string) => void;
}

/**
 * iOS segmented picker — Transport (Automatic/SSH/Mosh), auth method.
 * @dsCard group="Components"
 * @startingPoint section="Forms" subtitle="Segmented picker" viewport="700x150"
 */
export function SegmentedControl(props: SegmentedControlProps): JSX.Element;
