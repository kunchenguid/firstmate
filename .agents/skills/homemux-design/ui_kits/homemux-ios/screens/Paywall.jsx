// Paywall — trial ended (ported from PaywallView)
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const { Icon, Button, AppIcon } = HMX;

  const FEATURES = [
    { icon: "server", title: "Unlimited saved hosts", detail: "Keep using your SSH, Mosh, and one-tap tmux connections." },
    { icon: "command", title: "Command menu & terminal polish", detail: "Selection mode, special keys, tmux actions, paste, and voice draft stay available." },
    { icon: "palette", title: "Themes & future client features", detail: "Built-in terminal themes and client-side upgrades are included." },
    { icon: "cloud-off", title: "No account or subscription", detail: "Credentials stay local. No recurring plan, no cloud vault." },
  ];

  function Paywall({ onBack }) {
    return (
      <div style={{ position: "absolute", inset: 0, zIndex: 70, background: "var(--bg-base)",
        color: "var(--text-primary)", fontFamily: "var(--font-ui)", overflowY: "auto" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 6, padding: "56px 12px 6px" }}>
          <IconBack onBack={onBack} />
          <span style={{ fontSize: "var(--type-headline)", fontWeight: 600 }}>HomeMux Pro</span>
        </div>

        <div style={{ padding: "8px 16px 32px", display: "flex", flexDirection: "column", gap: 18 }}>
          {/* hero */}
          <div style={{ padding: "24px 20px", borderRadius: "var(--radius-2xl)", background: "var(--material-regular)",
            WebkitBackdropFilter: "var(--blur-regular)", backdropFilter: "var(--blur-regular)",
            border: "1px solid var(--accent-line)", display: "flex", flexDirection: "column", gap: 16 }}>
            <AppIcon size={64} radius={16} />
            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              <div style={{ fontSize: "var(--type-title1)", fontWeight: "var(--weight-bold)", letterSpacing: "var(--tracking-tight)" }}>Your trial has ended</div>
              <div style={{ fontSize: "var(--type-callout)", color: "var(--text-secondary)", lineHeight: 1.45 }}>
                Buy HomeMux once to keep full access to SSH, Mosh, tmux shortcuts, themes, and the command menu.
              </div>
            </div>
          </div>

          {/* features */}
          <div>
            <div style={{ fontSize: "var(--type-footnote)", fontWeight: 600, letterSpacing: "0.04em",
              textTransform: "uppercase", color: "var(--text-tertiary)", padding: "0 4px 8px" }}>Included forever</div>
            <div style={{ background: "var(--surface-1)", border: "1px solid var(--hairline)",
              borderRadius: "var(--radius-md)", overflow: "hidden" }}>
              {FEATURES.map((f, i) => (
                <div key={f.title} style={{ display: "flex", gap: 12, padding: "13px 14px", borderTop: i ? "1px solid var(--separator)" : "none" }}>
                  <Icon name={f.icon} size={19} color="var(--accent)" />
                  <div>
                    <div style={{ fontSize: "var(--type-subheadline)", fontWeight: 600 }}>{f.title}</div>
                    <div style={{ fontSize: "var(--type-footnote)", color: "var(--text-secondary)", lineHeight: 1.4 }}>{f.detail}</div>
                  </div>
                </div>
              ))}
            </div>
          </div>

          {/* actions */}
          <div style={{ display: "flex", flexDirection: "column", gap: 11 }}>
            <Button variant="prominent" fullWidth>Buy Lifetime Unlock · $49</Button>
            <Button variant="bordered" fullWidth>Restore Purchase</Button>
            <div style={{ fontSize: "var(--type-footnote)", color: "var(--text-tertiary)", lineHeight: 1.45, padding: "4px 4px 0" }}>
              A one-time, non-consumable purchase handled by Apple. No subscription, no account, no cloud vault.
            </div>
          </div>
        </div>
      </div>
    );
  }

  function IconBack({ onBack }) {
    return (
      <button onClick={onBack} aria-label="Back" style={{ width: 32, height: 32, display: "inline-flex",
        alignItems: "center", justifyContent: "center", background: "transparent", border: "none", cursor: "pointer", color: "var(--accent)" }}>
        <Icon name="chevron-left" size={22} color="currentColor" />
      </button>
    );
  }

  window.Paywall = Paywall;
})();
