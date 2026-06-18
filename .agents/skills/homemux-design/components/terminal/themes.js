// HomeMux built-in terminal themes (ported from TerminalTheme.swift).
// Shared business data for PaletteDots / ThemePreviewCard. Styling stays in CSS.

export const THEMES = {
  "homemux-dark": {
    id: "homemux-dark", name: "HomeMux Dark", appearance: "Dark",
    bg: "#0A0D12", fg: "#DDE5F1", caret: "#7CF7B6", accent: "#7CF7B6",
    ansi: ["#151A22","#FF6B72","#67E8A5","#F6C177","#7AA2FF","#C792EA","#5EDDE6","#DDE5F1",
           "#5A6472","#FF8F95","#8AF0BB","#F9D99A","#9BB8FF","#D9A5F2","#8BEAF0","#F7FAFF"],
  },
  "coastline-light": {
    id: "coastline-light", name: "Coastline Light", appearance: "Light",
    bg: "#F8FBFF", fg: "#16202C", caret: "#0969B3", accent: "#0969B3",
    ansi: ["#102030","#B83248","#177A4D","#9B6A00","#1C64B7","#8752A3","#0C7C86","#E4EAF2",
           "#5D6A78","#D94D61","#209B63","#BA8200","#2F7FDF","#A96AC5","#109AA6","#FFFFFF"],
  },
  "ember-console": {
    id: "ember-console", name: "Ember Console", appearance: "Dark",
    bg: "#120E0B", fg: "#F3E5D8", caret: "#FFB06A", accent: "#FFB06A",
    ansi: ["#211813","#FF6A5C","#86D88A","#E8B75F","#74A4FF","#D087D6","#69C9C4","#E8D6C7",
           "#6F5A4E","#FF8E82","#A8E6A9","#F5D68A","#9BBCFF","#E0A1E5","#91DAD6","#FFF4EA"],
  },
  "pine-mist": {
    id: "pine-mist", name: "Pine Mist", appearance: "Light",
    bg: "#F4F7F2", fg: "#18251E", caret: "#2D7D5F", accent: "#2D7D5F",
    ansi: ["#102018","#B4474A","#2D7D5F","#8B6F20","#3E6FA3","#7C5B91","#2F8087","#E1E8DF",
           "#607267","#D25E62","#3F9C78","#A9862C","#5789C1","#9671AD","#3F9AA1","#FFFFFF"],
  },
};

export function resolveTheme(theme) {
  if (!theme) return THEMES["homemux-dark"];
  if (typeof theme === "string") return THEMES[theme] || THEMES["homemux-dark"];
  return theme;
}
