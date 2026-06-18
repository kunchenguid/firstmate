// Add Host — host editor sheet (ported from HostEditorView.swift)
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const { TextField, SegmentedControl, Switch, ThemePreviewCard, Button, Icon } = HMX;
  const Sheet = window.HMXSheet;

  function Section({ label, children }) {
    return (
      <div style={{ marginTop: 16 }}>
        <div style={{ fontSize: "var(--type-footnote)", fontWeight: 600, letterSpacing: "0.04em",
          textTransform: "uppercase", color: "var(--text-tertiary)", padding: "0 4px 8px" }}>{label}</div>
        <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>{children}</div>
      </div>
    );
  }

  function AddHost({ onClose, onSave }) {
    const [name, setName] = React.useState("Mac mini · claude");
    const [host, setHost] = React.useState("mac-mini.local");
    const [user, setUser] = React.useState("alex");
    const [transport, setTransport] = React.useState("automatic");
    const [auth, setAuth] = React.useState("key");
    const [tmux, setTmux] = React.useState(true);
    const [session, setSession] = React.useState("claude");

    return (
      <Sheet title="Add Host" onClose={onClose}>
        <div style={{ overflowY: "auto", padding: "0 16px 12px" }}>
          <Section label="Connection">
            <TextField label="Display name" value={name} onChange={setName} />
            <TextField label="Host" value={host} onChange={setHost}
              leading={<Icon name="server" size={16} color="var(--text-tertiary)" />} />
            <TextField label="Username" value={user} onChange={setUser} />
          </Section>

          <Section label="Transport">
            <SegmentedControl value={transport} onChange={setTransport}
              options={[{label:"Automatic",value:"automatic"},{label:"SSH",value:"ssh"},{label:"Mosh",value:"mosh"}]} />
            <div style={{ fontSize: "var(--type-footnote)", color: "var(--text-tertiary)", padding: "0 4px", lineHeight: 1.4 }}>
              Automatic uses Mosh when available and falls back to SSH. You never choose up front.
            </div>
          </Section>

          <Section label="Authentication">
            <SegmentedControl value={auth} onChange={setAuth}
              options={[{label:"Password",value:"pwd"},{label:"Private Key",value:"key"}]} />
            {auth === "key" ? (
              <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
                <div style={{ background: "var(--bg-abyss)", border: "1px solid var(--hairline)",
                  borderRadius: "var(--radius-sm)", padding: "12px 13px", minHeight: 92,
                  fontFamily: "var(--font-mono)", fontSize: "var(--type-footnote)", color: "var(--text-tertiary)", lineHeight: 1.5 }}>
                  Paste OpenSSH Ed25519 private key…
                </div>
                <span style={{ fontSize: "var(--type-footnote)", color: "var(--text-tertiary)", padding: "0 4px", lineHeight: 1.4 }}>
                  Stored in the iOS Keychain. The key never leaves this device.
                </span>
              </div>
            ) : (
              <TextField label="Password" type="password" placeholder="••••••••" value="" onChange={() => {}} />
            )}
          </Section>

          <Section label="Startup">
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between",
              background: "var(--surface-1)", border: "1px solid var(--hairline)", borderRadius: "var(--radius-md)", padding: "12px 14px" }}>
              <span style={{ fontSize: "var(--type-callout)" }}>One-tap tmux session</span>
              <Switch checked={tmux} onChange={setTmux} />
            </div>
            {tmux && (
              <>
                <TextField label="Session name" mono value={session} onChange={setSession} />
                <div style={{ fontFamily: "var(--font-mono)", fontSize: "var(--type-footnote)", color: "var(--text-secondary)",
                  background: "var(--bg-abyss)", border: "1px solid var(--hairline)", borderRadius: 10, padding: "10px 12px" }}>
                  tmux new-session -A -s {session || "session"}
                </div>
              </>
            )}
          </Section>

          <Section label="Appearance">
            <ThemePreviewCard theme="homemux-dark" />
          </Section>

          <div style={{ marginTop: 18 }}>
            <Button variant="prominent" fullWidth onClick={onSave}>Save Host</Button>
          </div>
        </div>
      </Sheet>
    );
  }
  window.AddHost = AddHost;
})();
