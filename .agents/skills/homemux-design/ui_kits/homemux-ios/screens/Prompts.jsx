// Prompts — iOS alert dialog (host-key trust) + password sheet
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const { Icon } = HMX;

  // Centered iOS-style alert.
  function AlertDialog({ children }) {
    return (
      <div style={{ position: "absolute", inset: 0, zIndex: 95, display: "flex", alignItems: "center",
        justifyContent: "center", padding: 28, background: "rgba(0,0,0,0.5)" }}>
        <div style={{ width: "100%", maxWidth: 290, borderRadius: "var(--radius-xl)", overflow: "hidden",
          background: "var(--material-regular)", WebkitBackdropFilter: "var(--blur-regular)", backdropFilter: "var(--blur-regular)",
          border: "1px solid var(--hairline-strong)", boxShadow: "var(--shadow-card)", fontFamily: "var(--font-ui)",
          color: "var(--text-primary)" }}>
          {children}
        </div>
      </div>
    );
  }

  function AlertButtons({ buttons }) {
    return (
      <div style={{ display: "flex", borderTop: "1px solid var(--hairline)" }}>
        {buttons.map((b, i) => (
          <button key={b.label} onClick={b.onClick} style={{ flex: 1, padding: "13px 8px", border: "none",
            borderLeft: i ? "1px solid var(--hairline)" : "none", background: "transparent", cursor: "pointer",
            fontFamily: "var(--font-ui)", fontSize: "var(--type-callout)",
            fontWeight: b.bold ? "var(--weight-bold)" : "var(--weight-regular)",
            color: b.destructive ? "var(--danger)" : "var(--accent)" }}>{b.label}</button>
        ))}
      </div>
    );
  }

  function HostKeyPrompt({ onTrust, onCancel }) {
    return (
      <AlertDialog>
        <div style={{ padding: "20px 18px 16px", textAlign: "center", display: "flex", flexDirection: "column", gap: 9 }}>
          <div style={{ alignSelf: "center", width: 42, height: 42, borderRadius: "50%", background: "var(--warning-soft)",
            display: "flex", alignItems: "center", justifyContent: "center", marginBottom: 2 }}>
            <Icon name="shield-alert" size={22} color="var(--warning)" />
          </div>
          <div style={{ fontSize: "var(--type-headline)", fontWeight: 600 }}>Trust this host key?</div>
          <div style={{ fontSize: "var(--type-footnote)", color: "var(--text-secondary)", lineHeight: 1.45 }}>
            mac-mini.local:22 presented <b style={{ color: "var(--text-primary)" }}>ssh-ed25519</b>. Accept only if this matches your server.
          </div>
          <div style={{ fontFamily: "var(--font-mono)", fontSize: 11, color: "var(--text-secondary)",
            background: "var(--bg-abyss)", border: "1px solid var(--hairline)", borderRadius: 10, padding: "9px 10px",
            wordBreak: "break-all", lineHeight: 1.5 }}>SHA256:Hb9k2P+rQ0xLZ7v8mWp3cF1uYt6Ns4Aa0Dd5Ee2Bb</div>
        </div>
        <AlertButtons buttons={[
          { label: "Cancel", onClick: onCancel },
          { label: "Trust", bold: true, onClick: onTrust },
        ]} />
      </AlertDialog>
    );
  }

  function PasswordPrompt({ host, onConnect, onCancel }) {
    const Sheet = window.HMXSheet;
    const { Button } = HMX;
    return (
      <Sheet title="Enter Password" onClose={onCancel} maxHeight="auto">
        <div style={{ padding: "0 16px 16px", display: "flex", flexDirection: "column", gap: 8 }}>
          <div style={{ fontSize: "var(--type-footnote)", fontWeight: 600, letterSpacing: "0.04em",
            textTransform: "uppercase", color: "var(--text-tertiary)", padding: "0 4px 2px" }}>SSH Password</div>
          <div style={{ display: "flex", alignItems: "center", gap: 8, background: "var(--surface-2)",
            border: "1px solid var(--accent-line)", borderRadius: "var(--radius-sm)", padding: "0 12px" }}>
            <Icon name="lock" size={16} color="var(--text-tertiary)" />
            <div style={{ flex: 1, padding: "12px 0", fontFamily: "var(--font-mono)", letterSpacing: 3, color: "var(--text-primary)" }}>••••••••••</div>
          </div>
          <div style={{ fontSize: "var(--type-footnote)", color: "var(--text-tertiary)", padding: "2px 4px 6px" }}>
            {host ? `${host.endpoint}:${host.port}` : "root@example.com:22"} · stored only in the iOS Keychain.
          </div>
          <Button variant="prominent" fullWidth onClick={onConnect}>Connect</Button>
        </div>
      </Sheet>
    );
  }

  window.HostKeyPrompt = HostKeyPrompt;
  window.PasswordPrompt = PasswordPrompt;
})();
