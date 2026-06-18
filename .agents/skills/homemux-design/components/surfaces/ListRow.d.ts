import React from "react";

export interface ListRowProps extends React.HTMLAttributes<HTMLDivElement> {
  /** Leading element (use <IconTile> for the host-row glyph). */
  leading?: React.ReactNode;
  title: React.ReactNode;
  subtitle?: React.ReactNode;
  /** Caption line (auth · startup, transport, etc). */
  detail?: React.ReactNode;
  /** Trailing content (badges, palette dots). */
  trailing?: React.ReactNode;
  /** Show a trailing disclosure chevron. */
  chevron?: boolean;
}

export interface IconTileProps {
  size?: number;
  background?: string;
  tint?: string;
  children?: React.ReactNode;
  style?: React.CSSProperties;
}

/**
 * Inset-grouped list row — the saved-host row on the home screen.
 * @dsCard group="Components"
 * @startingPoint section="Surfaces" subtitle="List / host row" viewport="700x150"
 */
export function ListRow(props: ListRowProps): JSX.Element;
/** Rounded-square leading glyph tile. */
export function IconTile(props: IconTileProps): JSX.Element;
