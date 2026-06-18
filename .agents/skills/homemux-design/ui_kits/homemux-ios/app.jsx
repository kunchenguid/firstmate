// HomeMux iOS — interactive shell tying the screens + states together.
(function () {
  function App() {
    const allHosts = window.HMX_HOSTS;
    const [stage, setStage] = React.useState("onboarding"); // onboarding | home | terminal | paywall
    const [emptyHome, setEmptyHome] = React.useState(false);
    const [host, setHost] = React.useState(null);
    const [term, setTerm] = React.useState({ state: "connected", fallback: false, selecting: false });
    const [overlay, setOverlay] = React.useState(null); // add | settings | cmd | hostkey | password | tmux | tmuxEmpty

    const openTerminal = (h, opts = {}) => {
      setHost(h); setOverlay(null);
      setTerm({ state: "connected", fallback: false, selecting: false, ...opts });
      setStage("terminal");
    };
    const goTerm = (opts) => openTerminal(allHosts[1], opts);

    const groups = [
      ["Flow", [
        ["Onboarding", () => { setOverlay(null); setStage("onboarding"); }],
        ["Home", () => { setOverlay(null); setEmptyHome(false); setStage("home"); }],
        ["Empty", () => { setOverlay(null); setEmptyHome(true); setStage("home"); }],
      ]],
      ["Terminal", [
        ["Connected", () => goTerm({})],
        ["Connecting", () => goTerm({ state: "connecting" })],
        ["Failed", () => goTerm({ state: "failed" })],
        ["Mosh→SSH", () => goTerm({ fallback: true })],
        ["Selection", () => goTerm({ selecting: true })],
        ["Command", () => { goTerm({}); setOverlay("cmd"); }],
      ]],
      ["Sheets & prompts", [
        ["Add Host", () => { setStage("home"); setOverlay("add"); }],
        ["Settings", () => { setStage("home"); setOverlay("settings"); }],
        ["Host Key", () => { goTerm({ state: "connecting" }); setOverlay("hostkey"); }],
        ["Password", () => { goTerm({ state: "connecting" }); setOverlay("password"); }],
        ["tmux", () => { goTerm({}); setOverlay("tmux"); }],
        ["tmux · none", () => { goTerm({}); setOverlay("tmuxEmpty"); }],
        ["Paywall", () => { setOverlay(null); setStage("paywall"); }],
      ]],
    ];

    return (
      <div style={{ minHeight: "100vh", display: "flex", flexDirection: "column", alignItems: "center",
        justifyContent: "center", gap: 18, padding: "32px 16px",
        background: "radial-gradient(120% 90% at 50% 0%, #14181F 0%, #0A0C10 60%, #07090C 100%)" }}>
        <div style={{ position: "relative" }}>
          <window.IOSDevice dark>
            {stage === "home" && (
              <window.Home hosts={emptyHome ? [] : allHosts} onOpen={(h) => openTerminal(h)}
                onAdd={() => setOverlay("add")} onSettings={() => setOverlay("settings")} />
            )}
            {stage === "terminal" && host && (
              <window.Terminal host={host} state={term.state} fallback={term.fallback} selecting={term.selecting}
                onBack={() => setStage("home")} onCommandMenu={() => setOverlay("cmd")}
                onExitSelect={() => setTerm((t) => ({ ...t, selecting: false }))}
                onReconnect={() => setTerm({ state: "connected", fallback: true, selecting: false })} />
            )}
            {stage === "paywall" && <window.Paywall onBack={() => setStage("home")} />}
            {stage === "onboarding" && <window.Onboarding onDone={() => setStage("home")} />}

            {overlay === "add" && <window.AddHost onClose={() => setOverlay(null)} onSave={() => setOverlay(null)} />}
            {overlay === "settings" && <window.Settings onClose={() => setOverlay(null)} />}
            {overlay === "cmd" && <window.CommandMenu onClose={() => setOverlay(null)} />}
            {overlay === "hostkey" && <window.HostKeyPrompt onTrust={() => openTerminal(allHosts[1])} onCancel={() => setOverlay(null)} />}
            {overlay === "password" && <window.PasswordPrompt host={host} onConnect={() => openTerminal(allHosts[1])} onCancel={() => setOverlay(null)} />}
            {overlay === "tmux" && <window.TmuxPicker variant="sessions" onClose={() => setOverlay(null)} onAttach={() => openTerminal(allHosts[1])} />}
            {overlay === "tmuxEmpty" && <window.TmuxPicker variant="empty" onClose={() => setOverlay(null)} />}
          </window.IOSDevice>
        </div>

        {/* reviewer screen-jump bar (not part of the product) */}
        <div style={{ display: "flex", flexDirection: "column", gap: 8, maxWidth: 470, width: "100%" }}>
          {groups.map(([label, items]) => (
            <div key={label} style={{ display: "flex", flexWrap: "wrap", gap: 7, alignItems: "center", justifyContent: "center" }}>
              <span style={{ fontFamily: "var(--font-mono)", fontSize: 10, textTransform: "uppercase", letterSpacing: "0.08em",
                color: "var(--text-tertiary)", width: "100%", textAlign: "center" }}>{label}</span>
              {items.map(([t, fn]) => (
                <button key={t} onClick={fn} style={{ fontFamily: "var(--font-mono)", fontSize: 12,
                  color: "var(--text-secondary)", background: "rgba(255,255,255,0.04)", border: "1px solid var(--hairline)",
                  borderRadius: 99, padding: "6px 13px", cursor: "pointer" }}>{t}</button>
              ))}
            </div>
          ))}
        </div>
      </div>
    );
  }
  ReactDOM.createRoot(document.getElementById("root")).render(<App />);
})();
