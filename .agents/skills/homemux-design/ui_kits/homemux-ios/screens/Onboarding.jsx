// Onboarding — 3-page intro (ported from OnboardingView.swift)
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const { Button, Icon, ThemePreviewCard } = HMX;

  const PAGES = [
    { icon: "square-terminal", title: "One tap back into tmux",
      body: "HomeMux is built for the terminal sessions you already keep alive. Add a host once, then jump back into your shell or saved tmux session from iPhone." },
    { icon: "shield-check", title: "Local-first by design",
      body: "Keys stay in Keychain. Voice input runs on device and only creates a draft. No account, no cloud vault, no telemetry by default." },
    { icon: "circle-plus", title: "Start with one host",
      body: "Save your Mac mini, workstation, VPS, or homelab server. Automatic transport and tmux shortcuts can be tuned after the first connection." },
  ];

  function Onboarding({ onDone }) {
    const [page, setPage] = React.useState(0);
    const last = page === PAGES.length - 1;
    const p = PAGES[page];
    return (
      <div style={{
        position: "absolute", inset: 0, zIndex: 80,
        background: "linear-gradient(160deg, #0E141C 0%, #0A0D12 55%, #06080C 100%)",
        display: "flex", flexDirection: "column",
        color: "var(--text-primary)", fontFamily: "var(--font-ui)",
      }}>
        <div style={{ display: "flex", justifyContent: "flex-end", padding: "60px 20px 0" }}>
          <Button variant="bordered" size="small" onClick={onDone}>Skip</Button>
        </div>

        <div style={{ flex: 1, display: "flex", flexDirection: "column", alignItems: "center",
          justifyContent: "center", gap: 26, padding: "0 30px", textAlign: "center" }}>
          <div style={{ width: 116, height: 116, borderRadius: "var(--radius-3xl)",
            background: "var(--accent-soft)", display: "flex", alignItems: "center", justifyContent: "center",
            boxShadow: "0 0 40px var(--accent-glow)" }}>
            <Icon name={p.icon} size={52} color="var(--accent)" strokeWidth={2} />
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
            <div style={{ fontSize: 30, fontWeight: "var(--weight-bold)", letterSpacing: "var(--tracking-tight)", lineHeight: 1.1 }}>{p.title}</div>
            <div style={{ fontSize: "var(--type-callout)", color: "var(--text-secondary)", lineHeight: 1.5 }}>{p.body}</div>
          </div>
          <div style={{ width: "100%", maxWidth: 320 }}>
            <ThemePreviewCard theme="homemux-dark" showTitle={false} />
          </div>
        </div>

        <div style={{ display: "flex", justifyContent: "center", gap: 7, paddingBottom: 22 }}>
          {PAGES.map((_, i) => (
            <span key={i} style={{ width: i === page ? 22 : 7, height: 7, borderRadius: 99,
              background: i === page ? "var(--accent)" : "var(--surface-3)", transition: "all var(--dur-base) var(--ease-snappy)" }} />
          ))}
        </div>

        <div style={{ padding: "0 30px 40px", display: "flex", flexDirection: "column", gap: 14 }}>
          <Button variant="prominent" fullWidth
            icon={<Icon name={last ? "plus" : "arrow-right"} size={18} color="currentColor" />}
            onClick={() => (last ? onDone() : setPage(page + 1))}>
            {last ? "Add First Host" : "Continue"}
          </Button>
          <div style={{ fontSize: "var(--type-footnote)", color: "var(--text-tertiary)", textAlign: "center" }}>
            You can replay this introduction from Settings.
          </div>
        </div>
      </div>
    );
  }
  window.Onboarding = Onboarding;
})();
