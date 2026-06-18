// Settings — sheet (ported from SettingsView.swift)
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const { ThemePreviewCard, PaletteDots, Icon, Badge } = HMX;
  const Sheet = window.HMXSheet;

  const THEMES = [
    { id: "homemux-dark", name: "HomeMux Dark", appearance: "Dark" },
    { id: "ember-console", name: "Ember Console", appearance: "Dark" },
    { id: "coastline-light", name: "Coastline Light", appearance: "Light" },
    { id: "pine-mist", name: "Pine Mist", appearance: "Light" },
  ];

  function Row({ icon, title, detail, last }) {
    return (
      <div style={{ display: "flex", gap: 12, padding: "12px 14px", borderTop: last ? "1px solid var(--separator)" : "none" }}>
        <Icon name={icon} size={19} color="var(--accent)" />
        <div>
          <div style={{ fontSize: "var(--type-subheadline)", fontWeight: 600 }}>{title}</div>
          <div style={{ fontSize: "var(--type-footnote)", color: "var(--text-secondary)", lineHeight: 1.4 }}>{detail}</div>
        </div>
      </div>
    );
  }

  function Group({ label, footer, children }) {
    return (
      <div style={{ marginTop: 16 }}>
        <div style={{ fontSize: "var(--type-footnote)", fontWeight: 600, letterSpacing: "0.04em",
          textTransform: "uppercase", color: "var(--text-tertiary)", padding: "0 4px 8px" }}>{label}</div>
        <div style={{ background: "var(--surface-1)", border: "1px solid var(--hairline)",
          borderRadius: "var(--radius-md)", overflow: "hidden" }}>{children}</div>
        {footer ? <div style={{ fontSize: "var(--type-footnote)", color: "var(--text-tertiary)", padding: "8px 4px 0", lineHeight: 1.4 }}>{footer}</div> : null}
      </div>
    );
  }

  function Settings({ onClose }) {
    const [sel, setSel] = React.useState("homemux-dark");
    return (
      <Sheet title="Settings" onClose={onClose}>
        <div style={{ overflowY: "auto", padding: "0 16px 12px" }}>
          <Group label="Access">
            <Row icon="clock" title="Full-access trial" detail="12 days left. The trial includes the complete unrestricted app." />
          </Group>

          <Group label="Terminal Theme" footer="Built-in palettes are original to HomeMux. Named third-party schemes are deferred until a license review.">
            {THEMES.map((t, i) => (
              <div key={t.id} onClick={() => setSel(t.id)}
                style={{ display: "flex", alignItems: "center", gap: 12, padding: "11px 14px", cursor: "pointer",
                  borderTop: i ? "1px solid var(--separator)" : "none" }}>
                <PaletteDots theme={t.id} ring="var(--surface-1)" />
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: "var(--type-callout)" }}>{t.name}</div>
                  <div style={{ fontSize: "var(--type-caption)", color: "var(--text-secondary)" }}>{t.appearance}</div>
                </div>
                {sel === t.id ? <Icon name="circle-check" size={20} color="var(--accent)" /> : null}
              </div>
            ))}
            <div style={{ padding: 14, borderTop: "1px solid var(--separator)" }}>
              <ThemePreviewCard theme={sel} />
            </div>
          </Group>

          <Group label="Privacy">
            <Row icon="key-round" title="Keys stay in Keychain" detail="Passwords, keys, and passphrases are stored locally." />
            <Row icon="mic" title="Voice stays on device" detail="Dictation creates a draft first and never sends automatically." last />
            <Row icon="cloud-off" title="No account or cloud vault" detail="HomeMux connects directly to hosts you save on this device." last />
          </Group>

          <Group label="Help">
            <Row icon="circle-help" title="Replay Onboarding" detail="See the three-screen introduction again." />
          </Group>
        </div>
      </Sheet>
    );
  }
  window.Settings = Settings;
})();
