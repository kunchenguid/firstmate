// tmux session picker (ported from TmuxSessionPicker) — sessions / empty / not-installed
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const { Icon, Button } = HMX;

  const SESSIONS = [
    { name: "claude", windows: 3, attached: false },
    { name: "codex", windows: 2, attached: false },
    { name: "backend", windows: 5, attached: true },
  ];

  function Unavailable({ icon, title, body }) {
    return (
      <div style={{ padding: "34px 28px 40px", display: "flex", flexDirection: "column", alignItems: "center",
        gap: 12, textAlign: "center" }}>
        <div style={{ width: 64, height: 64, borderRadius: "var(--radius-lg)", background: "var(--surface-2)",
          border: "1px solid var(--hairline)", display: "flex", alignItems: "center", justifyContent: "center" }}>
          <Icon name={icon} size={28} color="var(--text-tertiary)" />
        </div>
        <div style={{ fontSize: "var(--type-headline)", fontWeight: 600 }}>{title}</div>
        <div style={{ fontSize: "var(--type-footnote)", color: "var(--text-secondary)", lineHeight: 1.45, maxWidth: 280 }}>{body}</div>
      </div>
    );
  }

  function TmuxPicker({ variant = "sessions", onClose, onAttach }) {
    const Sheet = window.HMXSheet;
    return (
      <Sheet title="Attach tmux" onClose={onClose}>
        {variant === "notInstalled" && (
          <Unavailable icon="package-x" title="tmux is not installed"
            body="Install tmux on the host, then tap Reconnect and try again." />
        )}
        {variant === "empty" && (
          <Unavailable icon="layers" title="No tmux sessions yet"
            body="Start a tmux session on the host, or save a one-tap tmux shortcut to create its named session automatically." />
        )}
        {variant === "sessions" && (
          <div style={{ overflowY: "auto", padding: "0 16px 8px" }}>
            <div style={{ fontSize: "var(--type-footnote)", color: "var(--text-tertiary)", padding: "0 4px 8px" }}>
              3 sessions detected on mac-mini.local. Tap to attach.
            </div>
            <div style={{ background: "var(--surface-1)", border: "1px solid var(--hairline)",
              borderRadius: "var(--radius-md)", overflow: "hidden" }}>
              {SESSIONS.map((s, i) => (
                <div key={s.name} onClick={onAttach} style={{ display: "flex", alignItems: "center", gap: 12,
                  padding: "13px 14px", cursor: "pointer", borderTop: i ? "1px solid var(--separator)" : "none" }}>
                  <span style={{ width: 36, height: 36, flex: "none", display: "flex", alignItems: "center", justifyContent: "center",
                    borderRadius: 9, background: "var(--bg-abyss)", border: "1px solid var(--accent-line)", color: "var(--accent)" }}>
                    <Icon name="layers" size={18} />
                  </span>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontFamily: "var(--font-mono)", fontSize: "var(--type-callout)", display: "flex", alignItems: "center", gap: 8 }}>
                      {s.name}
                      {s.attached && <span style={{ fontFamily: "var(--font-ui)", fontSize: "var(--type-caption2)", fontWeight: 600,
                        color: "var(--status-connected)", background: "color-mix(in srgb, var(--status-connected) 14%, transparent)",
                        padding: "2px 7px", borderRadius: 99 }}>attached</span>}
                    </div>
                    <div style={{ fontSize: "var(--type-caption)", color: "var(--text-tertiary)" }}>{s.windows} windows</div>
                  </div>
                  <Icon name="chevron-right" size={16} color="var(--text-tertiary)" />
                </div>
              ))}
            </div>
            <div style={{ marginTop: 14 }}>
              <Button variant="bordered" fullWidth icon={<Icon name="rotate-cw" size={16} color="currentColor" />}>Refresh</Button>
            </div>
          </div>
        )}
      </Sheet>
    );
  }
  window.TmuxPicker = TmuxPicker;
})();
