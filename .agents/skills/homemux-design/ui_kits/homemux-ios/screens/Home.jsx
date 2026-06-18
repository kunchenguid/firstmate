// Home — saved connections list (ported from HomeView.swift)
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const { IconButton, Banner, ListRow, IconTile, Badge, PaletteDots, Icon, Button } = HMX;

  function EmptyHosts({ onAdd }) {
    return (
      <div style={{ margin: "6px 16px 0", padding: "28px 24px", borderRadius: "var(--radius-2xl)",
        background: "var(--material-regular)", WebkitBackdropFilter: "var(--blur-regular)", backdropFilter: "var(--blur-regular)",
        border: "1px solid var(--hairline)", display: "flex", flexDirection: "column", alignItems: "center", gap: 18, textAlign: "center" }}>
        <div style={{ width: 76, height: 76, borderRadius: "var(--radius-xl)", background: "var(--accent-soft)",
          display: "flex", alignItems: "center", justifyContent: "center", boxShadow: "0 0 32px var(--accent-glow)" }}>
          <Icon name="square-terminal" size={36} color="var(--accent)" />
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <div style={{ fontSize: "var(--type-title2)", fontWeight: "var(--weight-semibold)" }}>No Hosts Yet</div>
          <div style={{ fontSize: "var(--type-callout)", color: "var(--text-secondary)", lineHeight: 1.45 }}>
            Add your Mac mini, workstation, or homelab server to start a one-tap terminal session.
          </div>
        </div>
        <Button variant="prominent" fullWidth icon={<Icon name="plus" size={18} color="currentColor" />} onClick={onAdd}>Add First Host</Button>
      </div>
    );
  }

  function Home({ hosts, onOpen, onAdd, onSettings }) {
    const empty = !hosts || hosts.length === 0;
    return (
      <div style={{ minHeight: "100%", background: "var(--bg-base)", color: "var(--text-primary)",
        fontFamily: "var(--font-ui)", paddingBottom: 40 }}>
        {/* nav */}
        <div style={{ padding: "58px 16px 8px", display: "flex", flexDirection: "column", gap: 12 }}>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
            <IconButton name="settings" label="Settings" variant="plain" tint="var(--text-secondary)" onClick={onSettings} />
            <IconButton name="plus" label="Add Host" variant="plain" tint="var(--accent)" onClick={onAdd} />
          </div>
          <div style={{ fontSize: "var(--type-large-title)", fontWeight: "var(--weight-bold)",
            letterSpacing: "var(--tracking-tight)" }}>HomeMux</div>
        </div>

        {/* trial banner */}
        <div style={{ padding: "8px 16px 14px" }}>
          <Banner tone="accent" icon="clock" title="Trial · 12 days left"
            message="Full access is unlocked during the trial. No terminal features are gated." />
        </div>

        {empty ? <EmptyHosts onAdd={onAdd} /> : (
        <React.Fragment>
        {/* connections */}
        <div style={{ padding: "0 16px 6px", fontSize: "var(--type-footnote)", fontWeight: 600,
          letterSpacing: "0.04em", textTransform: "uppercase", color: "var(--text-tertiary)" }}>Connections</div>
        <div style={{ margin: "0 16px", borderRadius: "var(--radius-md)", overflow: "hidden",
          border: "1px solid var(--hairline)" }}>
          {hosts.map((h, i) => (
            <div key={h.id} style={{ borderTop: i ? "1px solid var(--separator)" : "none" }}>
              <ListRow chevron onClick={() => onOpen(h)}
                leading={
                  <IconTile background={h.theme === "ember-console" ? "#120E0B" : "var(--bg-abyss)"}
                    tint={h.theme === "ember-console" ? "#FFB06A" : "var(--accent)"}>
                    <Icon name="terminal" size={20} />
                  </IconTile>
                }
                title={h.title}
                subtitle={`${h.endpoint}:${h.port}`}
                detail={<><Icon name={h.startupIcon} size={13} /> {h.auth} · {h.startup}</>}
                trailing={<PaletteDots theme={h.theme} ring="var(--surface-1)" />}
              />
            </div>
          ))}
        </div>
        <div style={{ padding: "10px 18px 0", fontSize: "var(--type-footnote)", color: "var(--text-tertiary)", lineHeight: 1.4 }}>
          Tap a host to reconnect. Swipe or long-press for edit and delete actions.
        </div>
        </React.Fragment>
        )}
      </div>
    );
  }
  window.Home = Home;
})();
