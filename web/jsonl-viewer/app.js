const state = {
  token: "",
  sessions: [],
  selected: null,
  entries: [],
  cursor: "tail",
  identity: "",
  eof: false,
  partialBytes: 0,
  loading: false,
  selectionGeneration: 0,
  requestGeneration: 0,
  timer: null,
};

const elements = {
  token: document.getElementById("token"),
  connect: document.getElementById("connect"),
  source: document.getElementById("source"),
  sessionSearch: document.getElementById("session-search"),
  sessions: document.getElementById("sessions"),
  sessionTitle: document.getElementById("session-title"),
  status: document.getElementById("status"),
  eventSearch: document.getElementById("event-search"),
  roleFilter: document.getElementById("role-filter"),
  typeFilter: document.getElementById("type-filter"),
  fromStart: document.getElementById("from-start"),
  loadMore: document.getElementById("load-more"),
  follow: document.getElementById("follow"),
  notice: document.getElementById("notice"),
  events: document.getElementById("events"),
};

function setStatus(message, error = false) {
  elements.status.textContent = message;
  elements.status.classList.toggle("error", error);
}

async function api(path) {
  const response = await fetch(path, { headers: { Authorization: `Bearer ${state.token}` }, cache: "no-store" });
  const body = await response.json().catch(() => ({ error: `HTTP ${response.status}` }));
  if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`);
  return body;
}

function timestampOf(value) {
  return value?.timestamp ?? value?.message?.timestamp ?? value?.at ?? value?.time ?? null;
}

function roleOf(value) {
  return String(value?.message?.role ?? value?.role ?? (value?.customType ? "custom" : "event"));
}

function typeOf(value) {
  return String(value?.type ?? value?.message?.type ?? "unknown");
}

function appendText(container, text, className = "block") {
  if (text === undefined || text === null || text === "") return;
  const paragraph = document.createElement("p");
  paragraph.className = className;
  paragraph.textContent = typeof text === "string" ? text : JSON.stringify(text, null, 2);
  container.append(paragraph);
}

function renderContent(container, content) {
  if (typeof content === "string") return appendText(container, content);
  if (!Array.isArray(content)) return appendText(container, content);
  for (const block of content) {
    if (typeof block === "string") { appendText(container, block); continue; }
    if (!block || typeof block !== "object") { appendText(container, block); continue; }
    if (block.type === "text") { appendText(container, block.text); continue; }
    const details = document.createElement("details");
    const summary = document.createElement("summary");
    const label = block.type === "toolCall" ? `Tool call: ${block.name ?? block.toolName ?? "unknown"}`
      : block.type === "toolResult" ? `Tool result: ${block.toolName ?? "unknown"}`
      : block.type === "thinking" ? "Thinking"
      : `Nested content: ${block.type ?? "unknown"}`;
    summary.textContent = label;
    const pre = document.createElement("pre");
    pre.textContent = block.type === "thinking" && block.thinking ? block.thinking : JSON.stringify(block, null, 2);
    details.append(summary, pre);
    container.append(details);
  }
}

function summaryOf(value, event) {
  if (event.error === "malformed_json") return `Malformed JSON at byte ${event.offset}: ${event.detail}`;
  if (event.error === "line_too_large") return `Line at byte ${event.offset} omitted because its ${event.bytes.toLocaleString()} bytes exceed the 8 MiB display limit.`;
  if (value?.message?.role === "toolResult") return `Tool result: ${value.message.toolName ?? "unknown tool"}${value.message.isError ? " (error)" : ""}`;
  if (value?.customType) return value.customType;
  if (value?.type === "http_response") return `HTTP request ${value.request ?? "?"}: ${value.status ?? "unknown"}`;
  if (value?.type === "read") return `Read ${value.bytes ?? "?"} bytes at offset ${value.offset ?? "?"}`;
  if (value?.type === "session") return `Session ${value.id ?? ""}`.trim();
  return typeOf(value);
}

function renderEntry(entry) {
  const value = entry.value;
  const fragment = document.getElementById("event-template").content.cloneNode(true);
  const card = fragment.querySelector("article");
  const role = roleOf(value);
  const type = typeOf(value);
  card.dataset.role = role;
  card.dataset.type = type;
  card.dataset.search = `${role} ${type} ${entry.raw ?? ""}`.toLowerCase();
  if (entry.error) card.classList.add("error");
  fragment.querySelector("time").textContent = timestampOf(value) ? new Date(timestampOf(value)).toLocaleString() : `byte ${entry.offset}`;
  fragment.querySelector(".role").textContent = role;
  fragment.querySelector(".type").textContent = type;
  fragment.querySelector(".event-summary").textContent = summaryOf(value, entry);
  const content = fragment.querySelector(".event-content");
  if (value?.message) renderContent(content, value.message.content);
  else if (value?.content !== undefined) renderContent(content, value.content);
  else if (value?.data !== undefined) renderContent(content, value.data);
  const raw = fragment.querySelector(".raw");
  if (entry.raw === null) raw.hidden = true;
  else raw.querySelector("pre").textContent = entry.raw ?? "";
  return card;
}

function refreshFilterOptions() {
  for (const [element, values] of [
    [elements.roleFilter, new Set(state.entries.map(entry => roleOf(entry.value)))],
    [elements.typeFilter, new Set(state.entries.map(entry => typeOf(entry.value)))],
  ]) {
    const selected = element.value;
    while (element.options.length > 1) element.remove(1);
    for (const value of [...values].sort()) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = value;
      element.append(option);
    }
    element.value = [...values].includes(selected) ? selected : "all";
  }
}

function applyFilters() {
  const query = elements.eventSearch.value.toLowerCase();
  for (const card of elements.events.querySelectorAll(".event-card")) {
    card.hidden = (query && !card.dataset.search.includes(query))
      || (elements.roleFilter.value !== "all" && card.dataset.role !== elements.roleFilter.value)
      || (elements.typeFilter.value !== "all" && card.dataset.type !== elements.typeFilter.value);
  }
}

function addBoundary(message) {
  const boundary = document.createElement("div");
  boundary.className = "boundary";
  boundary.textContent = message;
  elements.events.append(boundary);
}

function appendEntries(entries) {
  state.entries.push(...entries);
  const fragment = document.createDocumentFragment();
  for (const entry of entries) fragment.append(renderEntry(entry));
  elements.events.append(fragment);
  refreshFilterOptions();
  applyFilters();
}

function showNotice(message = "") {
  elements.notice.hidden = !message;
  elements.notice.textContent = message;
}

function requestIsCurrent(selectionGeneration, requestGeneration, source, id) {
  return state.selectionGeneration === selectionGeneration
    && state.requestGeneration === requestGeneration
    && state.selected?.source === source
    && state.selected?.id === id;
}

async function loadEvents({ resetDisplay = false, fromStart = false } = {}) {
  if (!state.selected || (state.loading && !resetDisplay)) return;
  const { source, id } = state.selected;
  const selectionGeneration = state.selectionGeneration;
  const requestGeneration = ++state.requestGeneration;
  state.loading = true;
  elements.loadMore.disabled = true;
  try {
    if (resetDisplay) {
      state.entries = [];
      state.cursor = fromStart ? 0 : "tail";
      state.identity = "";
      state.partialBytes = 0;
      elements.events.replaceChildren();
      showNotice();
    }
    const query = new URLSearchParams({ source, id, cursor: String(state.cursor) });
    if (state.identity) query.set("identity", state.identity);
    const body = await api(`/api/events?${query}`);
    if (!requestIsCurrent(selectionGeneration, requestGeneration, source, id)) return;
    if (body.reset) addBoundary(`The journal was ${body.reset}. Previously displayed events are retained; the replacement continues below.`);
    if (body.omittedPrefixBytes) showNotice(`Showing the live tail. ${body.omittedPrefixBytes.toLocaleString()} earlier bytes are not loaded; use “Load from start” for the complete file.`);
    if (body.partialBytes) showNotice(`Waiting for a newline: the final ${body.partialBytes.toLocaleString()} bytes are incomplete and have not been presented as an event.`);
    else if (!body.omittedPrefixBytes) showNotice();
    appendEntries(body.events);
    state.cursor = body.nextCursor;
    state.identity = body.identity;
    state.eof = body.eof;
    state.partialBytes = body.partialBytes;
    setStatus(`${state.entries.length.toLocaleString()} events shown · ${body.size.toLocaleString()} bytes · ${body.eof ? "at file end" : "more available"}`);
  } catch (error) {
    if (requestIsCurrent(selectionGeneration, requestGeneration, source, id)) setStatus(error.message, true);
  } finally {
    if (requestIsCurrent(selectionGeneration, requestGeneration, source, id)) {
      state.loading = false;
      elements.loadMore.disabled = !state.selected || state.eof;
      elements.fromStart.disabled = !state.selected;
    }
  }
}

function renderSessions() {
  const source = elements.source.value;
  const query = elements.sessionSearch.value.toLowerCase();
  const matches = state.sessions.filter(session => (source === "all" || session.source === source) && `${session.id} ${session.modifiedAt}`.toLowerCase().includes(query));
  elements.sessions.replaceChildren();
  for (const session of matches) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "session-button";
    if (state.selected?.source === session.source && state.selected?.id === session.id) button.classList.add("active");
    const name = document.createElement("span");
    name.textContent = session.label;
    const metadata = document.createElement("small");
    metadata.textContent = `${session.source === "short" ? "Short agent" : "Supervisor"} · ${new Date(session.modifiedAt).toLocaleString()} · ${session.bytes.toLocaleString()} B`;
    button.append(name, metadata);
    button.addEventListener("click", () => selectSession(session));
    elements.sessions.append(button);
  }
  if (!matches.length) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = "No matching journals.";
    elements.sessions.append(empty);
  }
}

async function selectSession(session) {
  state.selectionGeneration += 1;
  state.selected = session;
  elements.sessionTitle.textContent = session.label;
  renderSessions();
  await loadEvents({ resetDisplay: true });
}

async function connect() {
  state.token = elements.token.value;
  if (!state.token) return setStatus("Enter an access token.", true);
  try {
    const body = await api("/api/sessions");
    state.sessions = body.sessions;
    renderSessions();
    setStatus(`${body.sessions.length} journals available.`);
    if (!state.selected && body.sessions.length) await selectSession(body.sessions[0]);
  } catch (error) {
    state.sessions = [];
    renderSessions();
    setStatus(error.message, true);
  }
}

elements.connect.addEventListener("click", connect);
elements.token.addEventListener("keydown", event => { if (event.key === "Enter") connect(); });
elements.source.addEventListener("change", renderSessions);
elements.sessionSearch.addEventListener("input", renderSessions);
elements.eventSearch.addEventListener("input", applyFilters);
elements.roleFilter.addEventListener("change", applyFilters);
elements.typeFilter.addEventListener("change", applyFilters);
elements.loadMore.addEventListener("click", () => loadEvents());
elements.fromStart.addEventListener("click", () => loadEvents({ resetDisplay: true, fromStart: true }));

state.timer = window.setInterval(() => {
  if (state.selected && (state.eof || state.partialBytes > 0) && elements.follow.checked) loadEvents();
}, 1000);
