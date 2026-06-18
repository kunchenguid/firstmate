import React from "react";

export interface StatusDotProps extends React.HTMLAttributes<HTMLSpanElement> {
  /** Connection state. */
  state?: "connected" | "connecting" | "failed" | "idle";
  /** Diameter in px. */
  size?: number;
  /** Force pulsing on/off (defaults: pulses while connecting). */
  pulse?: boolean;
}

/**
 * Glowing connection status indicator.
 * @dsCard group="Components"
 */
export function StatusDot(props: StatusDotProps): JSX.Element;
