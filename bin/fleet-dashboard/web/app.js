// Admiral's Fleet Dashboard - React app, no build step.
//
// React and ReactDOM load as UMD <script> tags (see index.html) and land on
// window.React / window.ReactDOM. htm gives JSX-like markup without Babel or
// a bundler: html`<div>...</div>` compiles to React.createElement calls at
// runtime. Both react*.production.min.js and htm.module.js are vendored
// under vendor/ rather than pulled from a live CDN, so a page load never
// depends on an external host - see docs/dashboard.md "Why vendored, not CDN".
import htm from "./vendor/htm.module.js";

const { useState, useEffect, useCallback, useMemo, useRef } = React;
const html = htm.bind(React.createElement);

const STATUSES = ["needs_attention", "not_started", "working", "paused", "waiting", "testing", "complete"];
const STATUS_META = {
  needs_attention: { label: "Needs Attention" },
  not_started: { label: "Not Started" },
  working: { label: "Working" },
  paused: { label: "Paused" },
  waiting: { label: "Waiting" },
  testing: { label: "Testing" },
  complete: { label: "Complete" },
};
const CAPTAINS = ["firstmate", "captain_dj", "captain_river"];
const CAPTAIN_META = {
  firstmate: { label: "Firstmate" },
  captain_dj: { label: "Captain DJ" },
  captain_river: { label: "Captain River" },
};

// Ticks every minute (bin/fm-fleet-audit-tick.sh's header documents the cron
// cadence it assumes). Three missed ticks before the page calls the timer
// stalled, not one - a single slow tick is normal jitter, not an outage.
const TICK_EXPECTED_SECONDS = 60;
const TICK_STALE_SECONDS = TICK_EXPECTED_SECONDS * 3;
const TABS = [
  { key: "prompt", label: "Prompt" },
  { key: "interpretation", label: "Interpretation" },
  { key: "communication", label: "Communication" },
  { key: "needs", label: "What's Needed" },
];

const POLL_MS = 20000;

// ---- API ----

async function api(path, opts = {}) {
  const res = await fetch(`/api${path}`, {
    method: opts.method || "GET",
    headers: opts.body ? { "Content-Type": "application/json" } : undefined,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  const payload = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(payload.error || `request failed: ${res.status}`);
  }
  return payload;
}

function timeAgo(iso) {
  if (!iso) return "";
  const then = new Date(iso.endsWith("Z") ? iso : iso + "Z").getTime();
  const diffSec = Math.max(0, Math.floor((Date.now() - then) / 1000));
  if (diffSec < 60) return "just now";
  const min = Math.floor(diffSec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  return `${day}d ago`;
}

function fmtDateTime(iso) {
  if (!iso) return "";
  const d = new Date(iso.endsWith("Z") ? iso : iso + "Z");
  return d.toLocaleString();
}

// ---- small UI atoms ----

function StatusPill({ status }) {
  return html`<span class="pill status st-${status}">${STATUS_META[status]?.label || status}</span>`;
}

function CaptainPill({ captain }) {
  return html`<span class="pill captain cap-${captain}">${CAPTAIN_META[captain]?.label || captain}</span>`;
}

// ---- connectivity banner: loud and unmissable, never a quiet omission ----

function ConnBanner({ error, lastOkAt }) {
  if (!error) return null;
  return html`
    <div class="conn-banner" role="alert">
      <span class="icon">⚠</span>
      <div>
        <div>Cannot reach the dashboard server right now.</div>
        <div class="detail">
          ${"What you see below may be stale or incomplete - it is NOT confirmation the board is empty or healthy. "}
          ${lastOkAt ? `Last confirmed read: ${fmtDateTime(lastOkAt)}. ` : "No successful read yet this session. "}
          ${`Error: ${error}`}
        </div>
      </div>
    </div>
  `;
}

// ---- transient toast: immediate confirmation for an action whose real
// effect (a sweep completing) happens later, off-screen ----

function Toast({ toast }) {
  if (!toast) return null;
  return html`<div class="toast ${toast.kind || ""}" role="status">${toast.text}</div>`;
}

// ---- card ----

function Card({ task, allTasks, onOpen, onToggleStar, onQuickStatus, highlighted }) {
  const waitingOn = task.status === "waiting" && task.waiting_on_id
    ? allTasks.find((t) => t.id === task.waiting_on_id)
    : null;

  const stop = (fn) => (e) => { e.stopPropagation(); fn(); };

  return html`
    <div
      id="card-${task.id}"
      class="card st-${task.status} ${highlighted ? "highlight" : ""}"
      onClick=${() => onOpen(task.id)}
    >
      <div class="card-top">
        <div class="card-title">${task.title}</div>
        <button
          class="star-btn ${task.starred ? "on" : ""}"
          title=${task.starred ? "Unstar" : "Star"}
          onClick=${stop(() => onToggleStar(task))}
        >${task.starred ? "★" : "☆"}</button>
      </div>
      <div class="tag-row">
        <${StatusPill} status=${task.status} />
        <${CaptainPill} captain=${task.captain} />
      </div>
      ${task.status === "needs_attention" ? html`
        <div class="needs-attention-banner">
          ⚑ ${task.needs_attention_reason || "Needs his decision or action to continue."}
        </div>
      ` : null}
      ${task.status === "waiting" ? html`
        <div>
          ${waitingOn
            ? html`<button class="waiting-link-btn" onClick=${stop(() => onOpen(waitingOn.id))}>
                ⇒ waiting on: ${waitingOn.title}
              </button>`
            : task.waiting_reason
              ? html`<div class="empty-note" style=${{ margin: 0 }}>waiting: ${task.waiting_reason}</div>`
              : null}
        </div>
      ` : null}
      ${task.status === "testing" ? html`
        <button class="quick-action complete-btn" onClick=${stop(() => onQuickStatus(task, "complete"))}>
          Mark Complete
        </button>
      ` : null}
      ${task.status === "complete" ? html`
        <button class="quick-action reopen-btn" onClick=${stop(() => onQuickStatus(task, "not_started"))}>
          Reopen
        </button>
      ` : null}
      <div class="card-meta">
        <span class="card-captain">${CAPTAIN_META[task.captain]?.label || task.captain}</span>
        <span>${timeAgo(task.updated_at)}</span>
      </div>
    </div>
  `;
}

// ---- filters / search / sort ----

function Controls({ filters, setFilters, counts }) {
  const toggleStatus = (s) => {
    const next = new Set(filters.status);
    next.has(s) ? next.delete(s) : next.add(s);
    setFilters({ ...filters, status: next });
  };
  const toggleCaptain = (c) => {
    const next = new Set(filters.captain);
    next.has(c) ? next.delete(c) : next.add(c);
    setFilters({ ...filters, captain: next });
  };
  return html`
    <div class="controls">
      <input
        type="search" placeholder="Search titles..."
        value=${filters.search}
        onInput=${(e) => setFilters({ ...filters, search: e.target.value })}
      />
      <select value=${filters.sort} onChange=${(e) => setFilters({ ...filters, sort: e.target.value })}>
        <option value="updated">Sort: Recently updated</option>
        <option value="date">Sort: Date created</option>
        <option value="status">Sort: Status</option>
        <option value="title">Sort: Title</option>
      </select>
    </div>
    <div class="controls" style=${{ marginTop: 6 }}>
      <div class="chip-row">
        ${STATUSES.map((s) => html`
          <span
            class="chip ${filters.status.has(s) ? "active" : ""}"
            data-kind="status"
            style=${{ "--chip-color": `var(--st-${s})` }}
            onClick=${() => toggleStatus(s)}
          >${STATUS_META[s].label} (${counts.status[s] || 0})</span>
        `)}
      </div>
    </div>
    <div class="controls" style=${{ marginTop: 6 }}>
      <div class="chip-row">
        ${CAPTAINS.map((c) => html`
          <span
            class="chip ${filters.captain.has(c) ? "active" : ""}"
            data-kind="captain"
            style=${{ "--chip-color": `var(--cap-${c})` }}
            onClick=${() => toggleCaptain(c)}
          >${CAPTAIN_META[c].label} (${counts.captain[c] || 0})</span>
        `)}
      </div>
    </div>
  `;
}

// ---- expanded card overlay ----

function Tab({ tab, task, onAddNote }) {
  if (tab === "prompt") {
    return html`
      <div>
        <div class="prompt-hint">His initial prompt, unedited.</div>
        <div class="prompt-box">${task.initial_prompt}</div>
      </div>
    `;
  }
  const notes = task.notes.filter((n) => n.tab === tab);
  const emptyCopy = {
    interpretation: "No interpretation recorded yet - nothing is forced here.",
    communication: "No further communication recorded yet.",
    needs: "Nothing needed from him right now.",
  }[tab];
  const [draft, setDraft] = useState("");
  const [linkUrl, setLinkUrl] = useState("");
  const [linkLabel, setLinkLabel] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");

  const submit = async () => {
    if (!draft.trim() && !linkUrl.trim()) return;
    setBusy(true);
    setErr("");
    try {
      await onAddNote(tab, draft.trim(), linkUrl.trim(), linkLabel.trim());
      setDraft("");
      setLinkUrl("");
      setLinkLabel("");
    } catch (e) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  };

  return html`
    <div>
      ${notes.length === 0 ? html`<div class="tab-empty">${emptyCopy}</div>` : null}
      ${notes.map((n) => html`
        <div class="note-item" key=${n.id}>
          <div class="note-meta">
            <span class="note-author">${n.author}</span>
            <span>${fmtDateTime(n.created_at)}</span>
          </div>
          ${n.text ? html`<div class="note-text">${n.text}</div>` : null}
          ${n.link_url ? html`
            <a class="note-link" href=${n.link_url} target="_blank" rel="noopener noreferrer">
              ${n.link_label || n.link_url}
            </a>
          ` : null}
        </div>
      `)}
      <div class="compose">
        <textarea
          placeholder=${tab === "communication" ? "Add to the conversation about this task..." : "Add a note..."}
          value=${draft}
          onInput=${(e) => setDraft(e.target.value)}
        ></textarea>
        <input
          type="text" placeholder="Optional link (a URL he can open on his phone)"
          value=${linkUrl} onInput=${(e) => setLinkUrl(e.target.value)}
          style=${{
            background: "var(--surface2)", border: "1px solid var(--border)", color: "var(--text)",
            borderRadius: "6px", padding: "8px 10px", fontFamily: "var(--font)", fontSize: "13px",
          }}
        />
        ${linkUrl ? html`
          <input
            type="text" placeholder="Link label (optional)"
            value=${linkLabel} onInput=${(e) => setLinkLabel(e.target.value)}
            style=${{
              background: "var(--surface2)", border: "1px solid var(--border)", color: "var(--text)",
              borderRadius: "6px", padding: "8px 10px", fontFamily: "var(--font)", fontSize: "13px",
            }}
          />
        ` : null}
        ${err ? html`<div style=${{ color: "var(--danger)", fontSize: "12.5px" }}>${err}</div>` : null}
        <div class="compose-actions">
          <button disabled=${busy || (!draft.trim() && !linkUrl.trim())} onClick=${submit}>
            ${busy ? "Adding..." : "Add"}
          </button>
        </div>
      </div>
    </div>
  `;
}

function Overlay({ task, allTasks, onClose, onPatch, onStatus, onAddNote, onToggleStar }) {
  const [activeTab, setActiveTab] = useState("prompt");
  const [title, setTitle] = useState(task.title);
  const [agent, setAgent] = useState(task.agent);
  const [waitingTarget, setWaitingTarget] = useState(task.waiting_on_id || "");
  const [waitingReason, setWaitingReason] = useState(task.waiting_reason || "");
  const [showWaitingForm, setShowWaitingForm] = useState(false);
  const [naReason, setNaReason] = useState(task.needs_attention_reason || "");
  const [showNAForm, setShowNAForm] = useState(false);
  const [naErr, setNaErr] = useState("");

  useEffect(() => { setTitle(task.title); setAgent(task.agent); }, [task.id]);

  const otherTasks = allTasks.filter((t) => t.id !== task.id);

  const onStatusChange = (e) => {
    const next = e.target.value;
    if (next === "waiting") {
      setShowWaitingForm(true);
      return;
    }
    if (next === "needs_attention") {
      setNaErr("");
      setShowNAForm(true);
      return;
    }
    onStatus(task.id, next);
  };

  const confirmWaiting = () => {
    onStatus(task.id, "waiting", waitingTarget || null, waitingReason || null);
    setShowWaitingForm(false);
  };

  const confirmNeedsAttention = async () => {
    setNaErr("");
    try {
      await onStatus(task.id, "needs_attention", null, naReason || null);
      setShowNAForm(false);
    } catch (e) {
      setNaErr(e.message);
    }
  };

  return html`
    <div class="overlay" onClick=${(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div class="overlay-inner">
        <div class="overlay-head">
          <div style=${{ flex: 1 }}>
            <input
              class="title-edit" value=${title}
              onInput=${(e) => setTitle(e.target.value)}
              onBlur=${() => title.trim() && title !== task.title && onPatch({ title: title.trim() })}
            />
          </div>
          <button
            class="star-btn ${task.starred ? "on" : ""}"
            style=${{ fontSize: "22px" }}
            onClick=${() => onToggleStar(task)}
          >${task.starred ? "★" : "☆"}</button>
          <button class="close-btn" onClick=${onClose}>Close</button>
        </div>

        <div class="field-row">
          <span class="field-label">Status</span>
          <select class="status-select" value=${task.status} onChange=${onStatusChange}>
            ${STATUSES.map((s) => html`<option value=${s}>${STATUS_META[s].label}</option>`)}
          </select>
          <span class="field-label">Captain</span>
          <select
            class="captain-select" value=${task.captain}
            onChange=${(e) => onPatch({ captain: e.target.value })}
          >
            ${CAPTAINS.map((c) => html`<option value=${c}>${CAPTAIN_META[c].label}</option>`)}
          </select>
          <span class="field-label">Agent</span>
          <input
            class="agent-edit" value=${agent}
            onInput=${(e) => setAgent(e.target.value)}
            onBlur=${() => agent !== task.agent && onPatch({ agent })}
          />
        </div>

        ${showWaitingForm ? html`
          <div class="note-item" style=${{ marginTop: 8 }}>
            <div class="field-label" style=${{ marginBottom: 6 }}>What is this waiting on?</div>
            <select
              class="status-select" style=${{ marginBottom: 8, width: "100%" }}
              value=${waitingTarget} onChange=${(e) => setWaitingTarget(e.target.value)}
            >
              <option value="">(no other card - external wait)</option>
              ${otherTasks.map((t) => html`<option value=${t.id}>${t.title}</option>`)}
            </select>
            <input
              type="text" placeholder="Reason (shown on the card)"
              value=${waitingReason} onInput=${(e) => setWaitingReason(e.target.value)}
              style=${{
                width: "100%", background: "var(--surface2)", border: "1px solid var(--border)",
                color: "var(--text)", borderRadius: "6px", padding: "8px 10px",
                fontFamily: "var(--font)", fontSize: "13px", marginBottom: 8,
              }}
            />
            <div class="compose-actions">
              <button onClick=${confirmWaiting}>Set Waiting</button>
              <button
                onClick=${() => setShowWaitingForm(false)}
                style=${{ background: "var(--surface2)", color: "var(--text)" }}
              >Cancel</button>
            </div>
          </div>
        ` : null}

        ${showNAForm ? html`
          <div class="note-item" style=${{ marginTop: 8 }}>
            <div class="field-label" style=${{ marginBottom: 6 }}>
              What does he need to decide, approve, or supply?
            </div>
            <input
              type="text" placeholder="Reason (shown on the card - an ask, not a status update)"
              value=${naReason} onInput=${(e) => setNaReason(e.target.value)}
              style=${{
                width: "100%", background: "var(--surface2)", border: "1px solid var(--border)",
                color: "var(--text)", borderRadius: "6px", padding: "8px 10px",
                fontFamily: "var(--font)", fontSize: "13px", marginBottom: 8,
              }}
            />
            ${naErr ? html`<div style=${{ color: "var(--danger)", fontSize: "12.5px", marginBottom: 8 }}>${naErr}</div>` : null}
            <div class="compose-actions">
              <button disabled=${!naReason.trim()} onClick=${confirmNeedsAttention}>Set Needs Attention</button>
              <button
                onClick=${() => { setShowNAForm(false); setNaErr(""); }}
                style=${{ background: "var(--surface2)", color: "var(--text)" }}
              >Cancel</button>
            </div>
          </div>
        ` : null}

        ${task.status === "testing" ? html`
          <div class="field-row">
            <button class="quick-action complete-btn" onClick=${() => onStatus(task.id, "complete")}>
              Mark Complete
            </button>
          </div>
        ` : null}
        ${task.status === "complete" ? html`
          <div class="field-row">
            <button class="quick-action reopen-btn" onClick=${() => onStatus(task.id, "not_started")}>
              Reopen
            </button>
          </div>
        ` : null}

        <div class="tabs">
          ${TABS.map((t) => html`
            <button
              class="tab-btn ${activeTab === t.key ? "active" : ""}"
              onClick=${() => setActiveTab(t.key)}
            >${t.label}</button>
          `)}
        </div>
        <div class="tab-panel">
          <${Tab}
            tab=${activeTab} task=${task}
            onAddNote=${(tab, text, linkUrl, linkLabel) => onAddNote(task.id, tab, text, linkUrl, linkLabel)}
          />
        </div>
      </div>
    </div>
  `;
}

// ---- audit / discrepancy log section ----

function AuditSection({ auditStatus, onSetInterval, tasks, onGoToCard, onForceAudit, forcing }) {
  const [intervalDraft, setIntervalDraft] = useState("");
  const lastRun = auditStatus?.last_run;
  const log = auditStatus?.log || [];
  const lock = auditStatus?.sweep_lock;
  const sweeping = !!lock?.running;

  const lastTick = auditStatus?.last_tick_at;
  const tickAgeSec = lastTick
    ? (Date.now() - new Date(lastTick.endsWith("Z") ? lastTick : lastTick + "Z").getTime()) / 1000
    : null;
  const timerDead = tickAgeSec === null || tickAgeSec > TICK_STALE_SECONDS;

  return html`
    <div class="audit-section">
      <h2 class="section">Fleet Auditor</h2>
      <div class="audit-summary">
        <div class="audit-stat ${timerDead ? "alarm" : ""}">
          <div class="k">Timer</div>
          <div class="v">
            ${lastTick === null || lastTick === undefined
              ? "Never started - the interval timer is not installed."
              : timerDead
                ? `⚠ No heartbeat for ${timeAgo(lastTick)} - the timer may have stopped.`
                : `Alive - ticked ${timeAgo(lastTick)}`}
          </div>
        </div>
        <div class="audit-stat ${lastRun ? "" : "never"}">
          <div class="k">Last full check</div>
          <div class="v">
            ${lastRun ? fmtDateTime(lastRun.completed_at) : "Never run yet"}
            ${lastRun?.forced ? " (forced)" : ""}
            ${sweeping ? " · sweeping now…" : ""}
          </div>
        </div>
        <div class="audit-stat ${lastRun ? "" : "never"}">
          <div class="k">Time to check the whole board</div>
          <div class="v">${lastRun ? `${lastRun.duration_seconds.toFixed(1)}s for ${lastRun.tasks_checked} task(s)` : "—"}</div>
        </div>
        <div class="audit-stat ${lastRun ? (lastRun.discrepancies_found > 0 ? "found" : "clean") : "never"}">
          <div class="k">Last sweep result</div>
          <div class="v">
            ${!lastRun ? "—"
              : lastRun.discrepancies_found > 0
                ? `${lastRun.discrepancies_found} discrepancy(ies) found`
                : "Clean - nothing caught"}
          </div>
        </div>
      </div>

      <div class="audit-interval-row">
        Audit frequency: every ${auditStatus?.interval_minutes ?? "?"} minute(s).
        <input
          type="number" min="1" placeholder=${String(auditStatus?.interval_minutes ?? 15)}
          value=${intervalDraft} onInput=${(e) => setIntervalDraft(e.target.value)}
        />
        <button
          onClick=${() => { if (intervalDraft) { onSetInterval(Number(intervalDraft)); setIntervalDraft(""); } }}
        >Set</button>
      </div>

      <h2 class="section">Discrepancy Log</h2>
      ${log.length === 0
        ? html`<div class="log-none-yet">No discrepancies logged yet. This is not the same as "clean" - it means no audit run has flagged anything so far.</div>`
        : log.map((entry) => {
            const target = entry.task_id ? tasks.find((t) => t.id === entry.task_id) : null;
            return html`
              <div class="log-item ${entry.kind}" key=${entry.id}>
                <div class="log-when">${fmtDateTime(entry.created_at)} · ${entry.kind}${entry.task_id ? ` · ${entry.task_id}` : ""}</div>
                <div>${entry.text}</div>
                ${entry.task_id
                  ? (target
                      ? html`<button class="log-goto-btn" onClick=${() => onGoToCard(entry.task_id)}>↳ Go to card</button>`
                      : html`<div class="log-goto-missing">That card no longer exists.</div>`)
                  : null}
              </div>
            `;
          })}

      <div class="force-audit-row" style=${{ marginTop: 20 }}>
        <button class="force-audit-btn" disabled=${sweeping || forcing} onClick=${onForceAudit}>
          ${sweeping ? "Sweep running…" : forcing ? "Starting…" : "Force Audit Now"}
        </button>
        ${sweeping ? html`<span class="force-audit-status">A sweep is already in progress.</span>` : null}
      </div>
    </div>
  `;
}

// ---- root app ----

function App() {
  const [tasks, setTasks] = useState([]);
  const [connError, setConnError] = useState(null);
  const [lastOkAt, setLastOkAt] = useState(null);
  const [auditStatus, setAuditStatus] = useState(null);
  const [selectedId, setSelectedId] = useState(null);
  const [selectedTask, setSelectedTask] = useState(null);
  const [filters, setFilters] = useState({
    status: new Set(), captain: new Set(), search: "", sort: "updated",
  });
  const [pendingScrollId, setPendingScrollId] = useState(null);
  const [highlightId, setHighlightId] = useState(null);
  const [toast, setToast] = useState(null);
  const [forcing, setForcing] = useState(false);
  const [fastPolling, setFastPolling] = useState(false);
  const toastTimer = useRef(null);

  const showToast = useCallback((text, kind = "info") => {
    if (toastTimer.current) clearTimeout(toastTimer.current);
    setToast({ text, kind });
    toastTimer.current = setTimeout(() => setToast(null), 4000);
  }, []);

  // The list endpoint stays lean (no notes/history) so it scales with the
  // board's size; the expanded card fetches its own full detail instead.
  const refreshSelected = useCallback(async (id) => {
    if (!id) { setSelectedTask(null); return; }
    try {
      const task = await api(`/tasks/${id}`);
      setSelectedTask(task);
      setConnError(null);
      setLastOkAt(new Date().toISOString());
    } catch (e) {
      setConnError(e.message);
    }
  }, []);

  const refresh = useCallback(async () => {
    try {
      const [tasksRes, auditRes] = await Promise.all([
        api("/tasks"),
        api("/audit/status"),
      ]);
      setTasks(tasksRes.tasks);
      setAuditStatus(auditRes);
      setConnError(null);
      setLastOkAt(new Date().toISOString());
    } catch (e) {
      setConnError(e.message);
    }
    await refreshSelected(selectedId);
  }, [selectedId, refreshSelected]);

  useEffect(() => {
    refresh();
    const id = setInterval(refresh, fastPolling ? 3000 : POLL_MS);
    return () => clearInterval(id);
  }, [refresh, fastPolling]);

  useEffect(() => { refreshSelected(selectedId); }, [selectedId, refreshSelected]);

  const patchTask = async (id, fields) => {
    await api(`/tasks/${id}`, { method: "PATCH", body: fields });
    await refresh();
  };

  const setStatus = async (id, status, waitingOnId, reason) => {
    await api(`/tasks/${id}/status`, {
      method: "POST",
      body: { status, waiting_on_id: waitingOnId || null, reason: reason || null },
    });
    await refresh();
  };

  const addNote = async (id, tab, text, linkUrl, linkLabel) => {
    await api(`/tasks/${id}/notes`, {
      method: "POST",
      body: { tab, author: "admiral", text, link_url: linkUrl || null, link_label: linkLabel || null },
    });
    await refresh();
  };

  const toggleStar = async (task) => {
    await patchTask(task.id, { starred: !task.starred });
  };

  const setAuditInterval = async (minutes) => {
    await api("/settings/audit-interval", { method: "PUT", body: { minutes } });
    await refresh();
  };

  const onForceAudit = async () => {
    setForcing(true);
    try {
      const res = await api("/audit/force", { method: "POST" });
      if (res.started) {
        showToast(`Audit sweep started at ${new Date().toLocaleTimeString()}.`);
      } else {
        showToast(res.reason || "A sweep is already in progress.", "warn");
      }
      setFastPolling(true);
      setTimeout(() => setFastPolling(false), 60000);
      await refresh();
    } catch (e) {
      showToast(`Could not start the sweep: ${e.message}`, "warn");
    } finally {
      setForcing(false);
    }
  };

  const filtered = useMemo(() => {
    let list = tasks;
    if (filters.status.size > 0) list = list.filter((t) => filters.status.has(t.status));
    if (filters.captain.size > 0) list = list.filter((t) => filters.captain.has(t.captain));
    if (filters.search.trim()) {
      const q = filters.search.trim().toLowerCase();
      list = list.filter((t) => t.title.toLowerCase().includes(q) || (t.agent || "").toLowerCase().includes(q));
    }
    const sorted = [...list];
    if (filters.sort === "date") sorted.sort((a, b) => b.created_at.localeCompare(a.created_at));
    else if (filters.sort === "status") sorted.sort((a, b) => STATUSES.indexOf(a.status) - STATUSES.indexOf(b.status));
    else if (filters.sort === "title") sorted.sort((a, b) => a.title.localeCompare(b.title));
    else sorted.sort((a, b) => b.updated_at.localeCompare(a.updated_at));
    return sorted;
  }, [tasks, filters]);

  // Needs Attention is pulled out of every other section - blocking-on-him
  // work must be the first thing he sees, never buried among starred or
  // routine cards regardless of the active sort or filter.
  const needsAttention = useMemo(() => filtered.filter((t) => t.status === "needs_attention"), [filtered]);
  const favorites = useMemo(() => filtered.filter((t) => t.starred && t.status !== "needs_attention"), [filtered]);
  const rest = useMemo(() => filtered.filter((t) => !t.starred && t.status !== "needs_attention"), [filtered]);

  const counts = useMemo(() => {
    const status = {}, captain = {};
    tasks.forEach((t) => {
      status[t.status] = (status[t.status] || 0) + 1;
      captain[t.captain] = (captain[t.captain] || 0) + 1;
    });
    return { status, captain };
  }, [tasks]);

  // Jump to a card named by an audit log entry. Only clears a filter that
  // would actually hide the target - sort is left alone, since it only
  // reorders and scrollIntoView finds the card wherever it landed. Runs
  // after the DOM reflects any filter clear (the effect below, keyed on
  // `filtered`), so the node is guaranteed to exist by the time it scrolls.
  const goToCard = useCallback((taskId) => {
    const target = tasks.find((t) => t.id === taskId);
    if (!target) return;
    let overridden = false;
    const next = { ...filters };
    if (filters.status.size > 0 && !filters.status.has(target.status)) { next.status = new Set(); overridden = true; }
    if (filters.captain.size > 0 && !filters.captain.has(target.captain)) { next.captain = new Set(); overridden = true; }
    if (filters.search.trim() && !target.title.toLowerCase().includes(filters.search.trim().toLowerCase())) {
      next.search = ""; overridden = true;
    }
    if (overridden) {
      setFilters(next);
      showToast("Cleared filters to show this card.");
    }
    setPendingScrollId(taskId);
  }, [tasks, filters, showToast]);

  useEffect(() => {
    if (!pendingScrollId) return;
    const el = document.getElementById(`card-${pendingScrollId}`);
    if (!el) return;
    el.scrollIntoView({ behavior: "smooth", block: "center", inline: "center" });
    setHighlightId(pendingScrollId);
    setPendingScrollId(null);
    const t = setTimeout(() => setHighlightId(null), 1800);
    return () => clearTimeout(t);
  }, [pendingScrollId, filtered]);

  const selected = selectedTask && selectedTask.id === selectedId ? selectedTask : null;

  return html`
    <div class="wrap">
      <div class="head">
        <div class="eyebrow">Fleet Dashboard</div>
        <h1>The Admiral's task board</h1>
        <p class="sub">Every task the fleet is carrying, one card each. Star what matters most.</p>
      </div>

      <${ConnBanner} error=${connError} lastOkAt=${lastOkAt} />

      ${needsAttention.length > 0 ? html`
        <h2 class="section needs-attention-section">Needs Attention <span class="count">(${needsAttention.length})</span></h2>
        <div class="grid needs-attention-grid">
          ${needsAttention.map((t) => html`
            <${Card}
              key=${t.id} task=${t} allTasks=${tasks}
              onOpen=${setSelectedId} onToggleStar=${toggleStar}
              onQuickStatus=${(task, status) => setStatus(task.id, status)}
              highlighted=${highlightId === t.id}
            />
          `)}
        </div>
      ` : null}

      ${favorites.length > 0 ? html`
        <h2 class="section">Favorites <span class="count">(${favorites.length})</span></h2>
        <div class="favorites-row">
          ${favorites.map((t) => html`
            <${Card}
              key=${t.id} task=${t} allTasks=${tasks}
              onOpen=${setSelectedId} onToggleStar=${toggleStar}
              onQuickStatus=${(task, status) => setStatus(task.id, status)}
              highlighted=${highlightId === t.id}
            />
          `)}
        </div>
      ` : null}

      <h2 class="section">All Tasks <span class="count">(${rest.length})</span></h2>
      <${Controls} filters=${filters} setFilters=${setFilters} counts=${counts} />
      ${rest.length === 0 && tasks.length > 0
        ? html`<div class="empty-note">No tasks match the current filters.</div>`
        : null}
      ${tasks.length === 0 && !connError
        ? html`<div class="empty-note">Nothing on the board right now.</div>`
        : null}
      <div class="grid" style=${{ marginTop: 10 }}>
        ${rest.map((t) => html`
          <${Card}
            key=${t.id} task=${t} allTasks=${tasks}
            onOpen=${setSelectedId} onToggleStar=${toggleStar}
            onQuickStatus=${(task, status) => setStatus(task.id, status)}
            highlighted=${highlightId === t.id}
          />
        `)}
      </div>

      <${AuditSection}
        auditStatus=${auditStatus} onSetInterval=${setAuditInterval}
        tasks=${tasks} onGoToCard=${goToCard}
        onForceAudit=${onForceAudit} forcing=${forcing}
      />

      <footer class="page-foot">
        Fleet Dashboard · refreshes automatically every ${POLL_MS / 1000}s · agents update this board only through its API, never by editing this page.
      </footer>
    </div>

    <${Toast} toast=${toast} />

    ${selected ? html`
      <${Overlay}
        task=${selected} allTasks=${tasks}
        onClose=${() => setSelectedId(null)}
        onPatch=${(fields) => patchTask(selected.id, fields)}
        onStatus=${(id, status, waitingOnId, reason) => setStatus(id, status, waitingOnId, reason)}
        onAddNote=${addNote}
        onToggleStar=${toggleStar}
      />
    ` : null}
  `;
}

ReactDOM.createRoot(document.getElementById("root")).render(html`<${App} />`);
