// Terminal — the live session + its states (ported from TerminalSessionView.swift)
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const { IconButton, Badge, StatusDot, KeyCap, Icon, Button, Banner } = HMX;

  function TerminalBody({ state }) {
    if (state === "connecting") {
      return (
        <div style={{ fontFamily: "var(--font-mono)", fontSize: 13.5, lineHeight: 1.62, padding: "16px" }}>
          <div style={{ color: "var(--t-8)" }}>Resolving mac-mini.local…</div>
          <div style={{ color: "var(--t-8)" }}>Probing transport · mosh-server</div>
          <div style={{ color: "var(--t-11)" }}>Establishing secure channel…</div>
        </div>
      );
    }
    return (
      <div style={{ fontFamily: "var(--font-mono)", fontSize: 13.5, lineHeight: 1.62,
        padding: "16px 16px 6px", whiteSpace: "pre-wrap", wordBreak: "break-word",
        opacity: state === "failed" ? 0.4 : 1 }}>
        <div style={{ color: "var(--t-8)" }}>Last login: Tue Jun 17 09:14 on ttys004</div>
        <div><span style={{ color: "var(--t-10)" }}>alex@mac-mini</span> <span style={{ color: "var(--t-4)" }}>~/code/app</span></div>
        <div><span style={{ color: "var(--t-2)" }}>❯</span> <span style={{ color: "var(--t-fg)" }}>tmux attach -t claude</span></div>
        <div style={{ color: "var(--t-8)", marginTop: 4 }}>[claude] resuming session · 3 windows</div>
        <div style={{ color: "var(--t-fg)" }}><span style={{ color: "var(--t-2)" }}>●</span> Edited <span style={{ color: "var(--t-4)" }}>src/api/server.ts</span> <span style={{ color: "var(--t-2)" }}>+42</span> <span style={{ color: "var(--t-1)" }}>-8</span></div>
        <div style={{ color: "var(--t-fg)" }}><span style={{ color: "var(--t-2)" }}>✓</span> 128 tests passed <span style={{ color: "var(--t-8)" }}>(2.4s)</span></div>
        <div style={{ marginTop: 4 }}><span style={{ color: "var(--t-2)" }}>❯</span> <span style={{ color: "var(--t-fg)" }}>npm run build</span></div>
        <div style={{ color: "var(--t-8)" }}>  vite v5.2 building for production…</div>
        <div style={{ color: "var(--t-11)" }}>  transforming modules  <span style={{ color: "var(--t-2)" }}>████████████</span><span style={{ color: "var(--t-8)" }}>░░</span>  86%</div>
        {state === "connected" && (
          <div style={{ marginTop: 2 }}>
            <span style={{ color: "var(--t-2)" }}>❯</span>{" "}
            <span style={{ display: "inline-block", width: 8.5, height: 17, background: "var(--t-caret)",
              verticalAlign: "-3px", borderRadius: 1, animation: "hmx-caret 1.1s steps(2) infinite" }} />
          </div>
        )}
        <style>{"@keyframes hmx-caret{50%{opacity:0}}"}</style>
      </div>
    );
  }

  // Explicit text-selection mode overlay.
  function SelectionOverlay({ onExit }) {
    return (
      <div style={{ position: "absolute", inset: 0, zIndex: 5 }}>
        <div style={{ position: "absolute", inset: 0, background: "rgba(0,0,0,0.18)" }} />
        {/* highlighted region */}
        <div style={{ position: "absolute", top: 92, left: 28, width: 232, height: 22,
          background: "color-mix(in srgb, var(--accent) 32%, transparent)", borderRadius: 3 }} />
        <div style={{ position: "absolute", top: 114, left: 16, width: 150, height: 22,
          background: "color-mix(in srgb, var(--accent) 32%, transparent)", borderRadius: 3 }} />
        {/* top hint */}
        <div style={{ position: "absolute", top: 12, left: 12, right: 12, display: "flex", alignItems: "center", gap: 8,
          padding: "9px 13px", borderRadius: "var(--radius-pill)", background: "var(--material-regular)",
          WebkitBackdropFilter: "var(--blur-regular)", backdropFilter: "var(--blur-regular)", border: "1px solid var(--accent-line)" }}>
          <Icon name="text-cursor-input" size={15} color="var(--accent)" />
          <span style={{ fontSize: "var(--type-footnote)", fontWeight: 600 }}>Selection Mode</span>
          <span style={{ fontSize: "var(--type-caption)", color: "var(--text-secondary)", marginLeft: "auto" }}>Drag to select terminal text</span>
        </div>
      </div>
    );
  }

  function SelectionBar({ onExit }) {
    return (
      <div style={{ display: "flex", gap: 8, overflowX: "auto", padding: "10px 12px 30px",
        background: "var(--material-bar)", WebkitBackdropFilter: "var(--blur-thin)", backdropFilter: "var(--blur-thin)",
        borderTop: "1px solid var(--accent-line)" }}>
        <Button size="small" variant="bordered" onClick={onExit}>Copy</Button>
        <Button size="small" variant="prominent" onClick={onExit}>Copy &amp; Exit</Button>
        <Button size="small" variant="bordered">Select Visible</Button>
        <Button size="small" variant="plain" onClick={onExit}>Cancel</Button>
      </div>
    );
  }

  function Terminal({ host, onBack, onCommandMenu, state = "connected", fallback = false, selecting = false, onExitSelect, onReconnect }) {
    const themeClass = "term-" + host.theme;
    const statusText = state === "failed" ? "Connection failed" : state === "connecting" ? "Connecting…" : "Connected";
    return (
      <div className={themeClass} style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column",
        background: "var(--t-bg)", color: "var(--text-primary)", fontFamily: "var(--font-ui)" }}>

        {/* status bar */}
        <div style={{ paddingTop: 54, background: "var(--material-bar)",
          WebkitBackdropFilter: "var(--blur-regular)", backdropFilter: "var(--blur-regular)",
          borderBottom: "1px solid " + (state === "failed" ? "var(--danger-soft)" : "var(--accent-line)") }}>
          <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 12px" }}>
            <IconButton name="chevron-left" label="Back" variant="plain" tint="var(--accent)" size={32} onClick={onBack} />
            <StatusDot state={state} />
            <div style={{ minWidth: 0, flex: 1 }}>
              <div style={{ fontSize: "var(--type-caption)", fontWeight: 600, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{statusText}</div>
              <div style={{ fontSize: "var(--type-caption2)", color: "var(--text-secondary)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{host.endpoint}:{host.port}</div>
            </div>
            {state === "connected" && <Badge tint="var(--status-connected)">{fallback ? "SSH" : host.activeTransport}</Badge>}
            <IconButton name="ellipsis" label="Session actions" variant="plain" tint="var(--text-secondary)" size={32} />
          </div>
        </div>

        {/* recovery banner */}
        {state === "failed" && (
          <div style={{ padding: "10px 12px 2px" }}>
            <Banner tone="danger" title="Could not connect"
              message="Mosh appears installed, but UDP could not reach this host. Falling back is available."
              action={<Button size="small" onClick={onReconnect}>Reconnect</Button>} />
          </div>
        )}

        {/* terminal viewport */}
        <div style={{ flex: 1, overflow: "auto", position: "relative" }}>
          <TerminalBody state={state} />

          {selecting && <SelectionOverlay onExit={onExitSelect} />}

          {/* Mosh fallback notice */}
          {fallback && state === "connected" && !selecting && (
            <div style={{ position: "sticky", top: 12, display: "flex", justifyContent: "center", pointerEvents: "none" }}>
              <div style={{ display: "inline-flex", alignItems: "center", gap: 7, padding: "8px 13px",
                borderRadius: "var(--radius-pill)", background: "var(--material-regular)",
                WebkitBackdropFilter: "var(--blur-regular)", backdropFilter: "var(--blur-regular)",
                border: "1px solid var(--hairline)", fontSize: "var(--type-caption)", color: "var(--text-secondary)" }}>
                <Icon name="info" size={13} color="var(--status-info)" />
                Connected with SSH · Mosh isn’t installed on this machine.
              </div>
            </div>
          )}

          {/* floating command button */}
          {!selecting && state === "connected" && (
            <div style={{ position: "sticky", bottom: 14, display: "flex", justifyContent: "flex-end",
              paddingRight: 16, pointerEvents: "none" }}>
              <div style={{ pointerEvents: "auto" }}>
                <IconButton name="command" label="Command menu" shape="circle" size={52}
                  onClick={onCommandMenu} style={{ boxShadow: "var(--shadow-float)" }} />
              </div>
            </div>
          )}
        </div>

        {/* bottom: selection bar OR keyboard accessory row */}
        {selecting ? <SelectionBar onExit={onExitSelect} /> : (
          <div style={{ display: "flex", gap: 8, overflowX: "auto", padding: "10px 10px 30px",
            background: "var(--material-bar)", WebkitBackdropFilter: "var(--blur-thin)", backdropFilter: "var(--blur-thin)",
            borderTop: "1px solid var(--hairline)" }}>
            <KeyCap><span style={{ display: "inline-flex", alignItems: "center", gap: 5 }}><Icon name="mic" size={14} /> Mic</span></KeyCap>
            <KeyCap>Esc</KeyCap>
            <KeyCap>Tab</KeyCap>
            <KeyCap active>Ctrl</KeyCap>
            <KeyCap>←</KeyCap><KeyCap>↓</KeyCap><KeyCap>↑</KeyCap><KeyCap>→</KeyCap>
            <KeyCap>Ctrl-C</KeyCap><KeyCap>Ctrl-D</KeyCap><KeyCap>Ctrl-Z</KeyCap><KeyCap>Paste</KeyCap>
          </div>
        )}
      </div>
    );
  }
  window.Terminal = Terminal;
})();
