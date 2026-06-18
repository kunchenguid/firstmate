// Command Menu — floating command palette sheet (ported from CommandPaletteView + TerminalCommandCatalog)
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const { Icon } = HMX;

  const GROUPS = [
    { title: "Text", items: [
      { icon: "text-cursor-input", title: "Select Text", sub: "Enter explicit selection mode" },
      { icon: "copy", title: "Copy Visible Screen", sub: "Copy the current terminal buffer" },
      { icon: "clipboard", title: "Paste", sub: "Paste clipboard text into the session" },
    ]},
    { title: "Keys", items: [
      { icon: "corner-down-left", title: "Send Esc", sub: "Escape" },
      { icon: "command", title: "Ctrl-C", sub: "Interrupt" },
      { icon: "arrow-up-to-line", title: "Home", sub: "Move to line start" },
    ]},
    { title: "tmux", items: [
      { icon: "square-plus", title: "New Window", sub: "tmux new-window" },
      { icon: "square-arrow-right", title: "Next Window", sub: "tmux next-window" },
      { icon: "log-out", title: "Detach", sub: "tmux detach-client" },
    ]},
    { title: "Session", items: [
      { icon: "rotate-cw", title: "Reconnect", sub: "Close and reopen the session" },
      { icon: "layers", title: "List tmux Sessions", sub: "Open the attach session picker" },
      { icon: "circle-x", title: "Close Session", sub: "Disconnect and leave this screen" },
    ]},
  ];

  function CommandMenu({ onClose }) {
    return (
      <Sheet title="Command Menu" onClose={onClose}>
        <div style={{ padding: "0 16px 8px" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, background: "var(--surface-2)",
            border: "1px solid var(--hairline)", borderRadius: "var(--radius-sm)", padding: "9px 12px" }}>
            <Icon name="search" size={16} color="var(--text-tertiary)" />
            <span style={{ color: "var(--text-tertiary)", fontSize: "var(--type-subheadline)" }}>Search commands</span>
          </div>
        </div>
        <div style={{ overflowY: "auto", padding: "0 16px 8px" }}>
          {GROUPS.map((g) => (
            <div key={g.title} style={{ marginTop: 14 }}>
              <div style={{ fontSize: "var(--type-footnote)", fontWeight: 600, letterSpacing: "0.04em",
                textTransform: "uppercase", color: "var(--text-tertiary)", padding: "0 4px 6px" }}>{g.title}</div>
              <div style={{ background: "var(--surface-1)", border: "1px solid var(--hairline)",
                borderRadius: "var(--radius-md)", overflow: "hidden" }}>
                {g.items.map((it, i) => (
                  <div key={it.title} style={{ display: "flex", alignItems: "center", gap: 12, padding: "12px 14px",
                    borderTop: i ? "1px solid var(--separator)" : "none", cursor: "pointer" }}>
                    <Icon name={it.icon} size={19} color="var(--text-secondary)" />
                    <div style={{ flex: 1 }}>
                      <div style={{ fontSize: "var(--type-callout)" }}>{it.title}</div>
                      <div style={{ fontSize: "var(--type-caption)", color: "var(--text-tertiary)" }}>{it.sub}</div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </div>
      </Sheet>
    );
  }

  // Shared bottom sheet shell.
  function Sheet({ title, onClose, children, maxHeight = "82%" }) {
    return (
      <div onClick={onClose} style={{ position: "absolute", inset: 0, zIndex: 90,
        background: "rgba(0,0,0,0.45)", display: "flex", flexDirection: "column", justifyContent: "flex-end" }}>
        <div onClick={(e) => e.stopPropagation()} style={{ maxHeight, background: "var(--bg-base)",
          borderTopLeftRadius: "var(--radius-2xl)", borderTopRightRadius: "var(--radius-2xl)",
          border: "1px solid var(--hairline)", borderBottom: "none", boxShadow: "var(--shadow-sheet)",
          display: "flex", flexDirection: "column", overflow: "hidden", color: "var(--text-primary)",
          fontFamily: "var(--font-ui)" }}>
          <div style={{ display: "flex", justifyContent: "center", paddingTop: 8 }}>
            <span style={{ width: 36, height: 5, borderRadius: 99, background: "var(--surface-3)" }} />
          </div>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "10px 16px 12px" }}>
            <span style={{ fontSize: "var(--type-headline)", fontWeight: 600 }}>{title}</span>
            <span onClick={onClose} style={{ fontSize: "var(--type-callout)", color: "var(--accent)", cursor: "pointer" }}>Close</span>
          </div>
          {children}
          <div style={{ height: 28, flex: "none" }} />
        </div>
      </div>
    );
  }

  window.CommandMenu = CommandMenu;
  window.HMXSheet = Sheet;
})();
