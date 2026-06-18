import React from "react";

export interface BannerProps extends React.HTMLAttributes<HTMLDivElement> {
  /** Semantic tone — sets icon well color + default glyph. */
  tone?: "warning" | "danger" | "accent" | "info";
  /** Override the Lucide icon name. */
  icon?: string;
  title: React.ReactNode;
  message?: React.ReactNode;
  /** Trailing action node (usually a small <Button>). */
  action?: React.ReactNode;
}

/**
 * Inline message banner — connection recovery, trial state, Mosh fallback.
 * @dsCard group="Components"
 * @startingPoint section="Surfaces" subtitle="Inline banner / notice" viewport="700x160"
 */
export function Banner(props: BannerProps): JSX.Element;
