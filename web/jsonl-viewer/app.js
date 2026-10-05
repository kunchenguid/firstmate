const state = {
  token: "",
  sessions: [],
  tasks: [],
  selected: null,
  selectedTaskId: null,
  selectedTaskDocumentType: null,
  entries: [],
  eventSegments: [],
  entryNodes: new Map(),
  entrySequence: 0,
  cursor: "tail",
  identity: "",
  eof: false,
  partialBytes: 0,
  reportContent: null,
  loading: false,
  selectionGeneration: 0,
  requestGeneration: 0,
  taskRequestGeneration: 0,
  taskLoading: false,
  taskLoaded: false,
  taskSnapshotGeneration: null,
  taskLoadError: "",
  taskSelectionGeneration: 0,
  taskDocumentLoading: null,
  taskDocumentContent: null,
  timer: null,
  authenticated: false,
  sidebarCollapsed: false,
  requestedPath: `${window.location.pathname}${window.location.search}`,
};

const TOKEN_STORAGE_KEY = "firstmate.jsonlViewer.accessToken.v1";

const elements = {
  loginPage: document.getElementById("login-page"),
  loginStatus: document.getElementById("login-status"),
  appShell: document.getElementById("app-shell"),
  viewerLayout: document.getElementById("viewer-layout"),
  sidebar: document.getElementById("sidebar"),
  sidebarToggle: document.getElementById("sidebar-toggle"),
  sidebarEyebrow: document.getElementById("sidebar-eyebrow"),
  sidebarTitle: document.getElementById("sidebar-title"),
  pageKind: document.getElementById("page-kind"),
  dashboardEmpty: document.getElementById("dashboard-empty"),
  dashboardEmptyTitle: document.getElementById("dashboard-empty-title"),
  dashboardEmptyCopy: document.getElementById("dashboard-empty-copy"),
  token: document.getElementById("token"),
  rememberToken: document.getElementById("remember-token"),
  tokenNote: document.getElementById("token-note"),
  connect: document.getElementById("connect"),
  forget: document.getElementById("forget"),
  source: document.getElementById("source"),
  sessionSearch: document.getElementById("session-search"),
  sessions: document.getElementById("sessions"),
  sessionTitle: document.getElementById("session-title"),
  status: document.getElementById("status"),
  eventSearch: document.getElementById("event-search"),
  roleFilter: document.getElementById("role-filter"),
  typeFilter: document.getElementById("type-filter"),
  journalFilters: document.getElementById("journal-filters"),
  journalActions: document.getElementById("journal-actions"),
  fromStart: document.getElementById("from-start"),
  loadMore: document.getElementById("load-more"),
  follow: document.getElementById("follow"),
  notice: document.getElementById("notice"),
  events: document.getElementById("events"),
  report: document.getElementById("report"),
  reportRendered: document.getElementById("report-rendered"),
  artifactViewer: document.getElementById("artifact-viewer"),
  taskDashboard: document.getElementById("task-dashboard"),
  taskStatus: document.getElementById("task-status"),
  retryTasks: document.getElementById("retry-tasks"),
  taskFollow: document.getElementById("task-follow"),
  taskCounts: document.getElementById("task-counts"),
  taskDetail: document.getElementById("task-detail"),
  taskDetailState: document.getElementById("task-detail-state"),
  taskDetailTitle: document.getElementById("task-detail-title"),
  taskDetailMeta: document.getElementById("task-detail-meta"),
  taskDetailWait: document.getElementById("task-detail-wait"),
  taskDetailWarning: document.getElementById("task-detail-warning"),
  taskDocumentType: document.getElementById("task-document-type"),
  taskDocumentBrief: document.getElementById("task-document-brief"),
  taskDocumentReport: document.getElementById("task-document-report"),
  taskDocumentEmpty: document.getElementById("task-document-empty"),
  taskDocumentRendered: document.getElementById("task-document-rendered"),
  taskDocumentSource: document.getElementById("task-document-source"),
  closeTask: document.getElementById("close-task"),
  openTaskReport: document.getElementById("open-task-report"),
};

const DISPLAY_TIME_ZONE = "Asia/Shanghai";
const SUPERVISOR_HIDDEN_EVENT_TYPE = "openai-codex-compat-native-response";
const displayTimeFormatter = new Intl.DateTimeFormat("zh-CN", {
  timeZone: DISPLAY_TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hour12: false,
});

function displayTime(value) {
  if (!value) return "";
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? "" : `${displayTimeFormatter.format(date)} UTC+8`;
}

function setStatus(message, error = false) {
  elements.status.textContent = message;
  elements.status.classList.toggle("error", error);
  elements.loginStatus.textContent = message;
  elements.loginStatus.classList.toggle("error", error);
}

async function api(path) {
  const response = await fetch(path, { headers: { Authorization: `Bearer ${state.token}` }, cache: "no-store" });
  const body = await response.json().catch(() => ({ error: `HTTP ${response.status}` }));
  if (!response.ok) {
    if (response.status === 401) invalidateCredential("Access token was rejected or expired. Enter a valid token to continue.");
    const error = new Error(body.error || `HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return body;
}

function storedToken(operation, value) {
  try {
    if (operation === "get") return window.localStorage.getItem(TOKEN_STORAGE_KEY);
    if (operation === "set") window.localStorage.setItem(TOKEN_STORAGE_KEY, value);
    if (operation === "remove") window.localStorage.removeItem(TOKEN_STORAGE_KEY);
    return null;
  } catch {
    elements.tokenNote.textContent = "Browser storage is unavailable. You can still connect, but the token will be kept only for this page.";
    return null;
  }
}

function invalidateCredential(message = "Enter an access token to begin.") {
  state.token = "";
  state.sessions = [];
  state.tasks = [];
  taskStatusFilter = null;
  state.selected = null;
  state.selectedTaskId = null;
  state.selectedTaskDocumentType = null;
  state.selectionGeneration += 1;
  state.taskSelectionGeneration += 1;
  state.taskRequestGeneration += 1;
  state.taskLoading = false;
  state.taskLoaded = false;
  state.taskSnapshotGeneration = null;
  state.taskLoadError = "";
  state.taskDocumentLoading = null;
  state.authenticated = false;
  elements.token.value = "";
  elements.rememberToken.checked = false;
  elements.forget.disabled = true;
  storedToken("remove");
  renderSessions();
  renderTaskDashboard();
  setStatus(message, true);
  elements.taskStatus.textContent = message;
  showLogin(message);
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

function safeLinkTarget(target) {
  try {
    const parsed = new URL(target);
    return ["http:", "https:", "mailto:"].includes(parsed.protocol) ? parsed.href : null;
  } catch {
    return null;
  }
}

function appendInline(container, source) {
  const pattern = /(!?)\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)|`([^`]+)`/g;
  let offset = 0;
  for (const match of source.matchAll(pattern)) {
    container.append(document.createTextNode(source.slice(offset, match.index)));
    if (match[4] !== undefined) {
      const code = document.createElement("code");
      code.textContent = match[4];
      container.append(code);
    } else if (match[1] === "!") {
      const omitted = document.createElement("span");
      omitted.className = "omitted-image";
      omitted.textContent = `[Image omitted: ${match[2] || "no alt text"}]`;
      container.append(omitted);
    } else {
      const target = safeLinkTarget(match[3]);
      if (target) {
        const link = document.createElement("a");
        link.href = target;
        link.rel = "noreferrer noopener";
        link.target = "_blank";
        link.textContent = match[2] || match[3];
        container.append(link);
      } else {
        const blocked = document.createElement("span");
        blocked.className = "blocked-link";
        blocked.textContent = `${match[2] || match[3]} (blocked link)`;
        container.append(blocked);
      }
    }
    offset = match.index + match[0].length;
  }
  container.append(document.createTextNode(source.slice(offset)));
}

function tableCells(line) {
  const trimmed = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  return trimmed.split("|").map(cell => cell.trim());
}

function isTableSeparator(line) {
  return /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line);
}

function startsMarkdownBlock(lines, index) {
  const line = lines[index] ?? "";
  return /^\s*$/.test(line)
    || /^ {0,3}```/.test(line)
    || /^ {0,3}#{1,6}\s+/.test(line)
    || /^ {0,3}>/.test(line)
    || /^\s*(?:[-+*]|\d+[.)])\s+/.test(line)
    || (line.includes("|") && isTableSeparator(lines[index + 1] ?? ""));
}

function renderMarkdown(container, source) {
  container.replaceChildren();
  const lines = source.replace(/\r\n?/g, "\n").split("\n");
  let index = 0;
  while (index < lines.length) {
    const line = lines[index];
    if (!line.trim()) { index += 1; continue; }
    const fence = line.match(/^ {0,3}```\s*([^\s`]*)\s*$/);
    if (fence) {
      const parts = [];
      index += 1;
      while (index < lines.length && !/^ {0,3}```\s*$/.test(lines[index])) parts.push(lines[index++]);
      if (index < lines.length) index += 1;
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      if (fence[1]) code.dataset.language = fence[1];
      code.textContent = parts.join("\n");
      pre.append(code);
      container.append(pre);
      continue;
    }
    const heading = line.match(/^ {0,3}(#{1,6})\s+(.+)$/);
    if (heading) {
      const element = document.createElement(`h${heading[1].length}`);
      appendInline(element, heading[2]);
      container.append(element);
      index += 1;
      continue;
    }
    if (/^ {0,3}>/.test(line)) {
      const quote = document.createElement("blockquote");
      const parts = [];
      while (index < lines.length && /^ {0,3}>/.test(lines[index])) parts.push(lines[index++].replace(/^ {0,3}> ?/, ""));
      const paragraph = document.createElement("p");
      appendInline(paragraph, parts.join("\n"));
      quote.append(paragraph);
      container.append(quote);
      continue;
    }
    const listMatch = line.match(/^\s*([-+*]|\d+[.)])\s+(.+)$/);
    if (listMatch) {
      const ordered = /^\d/.test(listMatch[1]);
      const list = document.createElement(ordered ? "ol" : "ul");
      while (index < lines.length) {
        const item = lines[index].match(/^\s*([-+*]|\d+[.)])\s+(.+)$/);
        if (!item || /^\d/.test(item[1]) !== ordered) break;
        const entry = document.createElement("li");
        appendInline(entry, item[2]);
        list.append(entry);
        index += 1;
      }
      container.append(list);
      continue;
    }
    if (line.includes("|") && isTableSeparator(lines[index + 1] ?? "")) {
      const table = document.createElement("table");
      const head = document.createElement("thead");
      const headRow = document.createElement("tr");
      for (const cell of tableCells(line)) {
        const header = document.createElement("th");
        appendInline(header, cell);
        headRow.append(header);
      }
      head.append(headRow);
      table.append(head);
      index += 2;
      const body = document.createElement("tbody");
      while (index < lines.length && lines[index].includes("|") && lines[index].trim()) {
        const row = document.createElement("tr");
        for (const cell of tableCells(lines[index++])) {
          const data = document.createElement("td");
          appendInline(data, cell);
          row.append(data);
        }
        body.append(row);
      }
      table.append(body);
      container.append(table);
      continue;
    }
    const paragraphLines = [line.trim()];
    index += 1;
    while (index < lines.length && !startsMarkdownBlock(lines, index)) paragraphLines.push(lines[index++].trim());
    const paragraph = document.createElement("p");
    appendInline(paragraph, paragraphLines.join(" "));
    container.append(paragraph);
  }
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
  fragment.querySelector("time").textContent = timestampOf(value) ? displayTime(timestampOf(value)) : `byte ${entry.offset}`;
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

function cardMatchesFilters(card) {
  const query = elements.eventSearch.value.toLowerCase();
  return (!query || card.dataset.search.includes(query))
    && (elements.roleFilter.value === "all" || card.dataset.role === elements.roleFilter.value)
    && (elements.typeFilter.value === "all" || card.dataset.type === elements.typeFilter.value);
}

function applyFilters() {
  for (const card of elements.events.querySelectorAll(".event-card")) {
    card.hidden = !cardMatchesFilters(card);
  }
}

function boundaryNode(message) {
  const boundary = document.createElement("div");
  boundary.className = "boundary";
  boundary.textContent = message;
  return boundary;
}

function entryTimestamp(entry) {
  const value = timestampOf(entry.value);
  if (value === null || value === undefined || value === "") return null;
  const parsed = typeof value === "number" ? value : Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function renderEntriesNewestFirst(anchor = null, anchorTop = undefined) {
  if (!anchor) {
    anchor = [...elements.events.children].find(node => node.getBoundingClientRect().bottom > 0) || null;
    anchorTop = anchor?.getBoundingClientRect().top;
  }
  const fragment = document.createDocumentFragment();
  for (const segment of [...state.eventSegments].reverse()) {
    const ordered = segment.entries.map((entry, index) => ({ entry, index, timestamp: entryTimestamp(entry) }))
      .sort((left, right) => {
        if (left.timestamp !== null && right.timestamp !== null) return right.timestamp - left.timestamp || left.index - right.index;
        if (left.timestamp !== null) return -1;
        if (right.timestamp !== null) return 1;
        return (right.entry.offset ?? 0) - (left.entry.offset ?? 0) || left.index - right.index;
      });
    for (const { entry } of ordered) {
      let card = state.entryNodes.get(entry.displayKey);
      if (!card) {
        card = renderEntry(entry);
        state.entryNodes.set(entry.displayKey, card);
      }
      card.hidden = !cardMatchesFilters(card);
      fragment.append(card);
    }
    if (segment.boundary) fragment.append(segment.boundary);
  }
  elements.events.replaceChildren(fragment);
  if (anchor?.isConnected && anchorTop !== undefined) {
    const delta = anchor.getBoundingClientRect().top - anchorTop;
    if (Math.abs(delta) > 0.5) window.scrollBy(0, delta);
  }
}

function appendEntries(entries, boundaryMessage = "") {
  const anchor = [...elements.events.children].find(node => node.getBoundingClientRect().bottom > 0) || null;
  const anchorTop = anchor?.getBoundingClientRect().top;
  const prepared = entries
    .filter(entry => !(state.selected?.source === "supervisor" && entry.value?.customType === SUPERVISOR_HIDDEN_EVENT_TYPE))
    .map(entry => ({ ...entry, displayKey: String(++state.entrySequence) }));
  state.entries.push(...prepared);
  if (!state.eventSegments.length || boundaryMessage) {
    state.eventSegments.push({ entries: [], boundary: boundaryMessage ? boundaryNode(boundaryMessage) : null });
  }
  state.eventSegments.at(-1).entries.push(...prepared);
  refreshFilterOptions();
  renderEntriesNewestFirst(anchor, anchorTop);
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
  if (!state.selected || state.selected.source === "report" || (state.loading && !resetDisplay)) return;
  const { source, id } = state.selected;
  const selectionGeneration = state.selectionGeneration;
  const requestGeneration = ++state.requestGeneration;
  state.loading = true;
  elements.loadMore.disabled = true;
  try {
    if (resetDisplay) {
      state.entries = [];
      state.eventSegments = [];
      state.entryNodes.clear();
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
    const boundaryMessage = body.reset ? `The journal was ${body.reset}. Replacement records are shown above; previously displayed records remain below.` : "";
    if (body.omittedPrefixBytes) showNotice(`Showing the live tail. ${body.omittedPrefixBytes.toLocaleString()} earlier bytes are not loaded; use “Load from start” for the complete file.`);
    if (body.partialBytes) showNotice(`Waiting for a newline: the final ${body.partialBytes.toLocaleString()} bytes are incomplete and have not been presented as an event.`);
    else if (!body.omittedPrefixBytes) showNotice();
    appendEntries(body.events, boundaryMessage);
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

async function loadReport({ resetDisplay = false } = {}) {
  if (!state.selected || state.selected.source !== "report" || (state.loading && !resetDisplay)) return;
  const { source, id } = state.selected;
  const selectionGeneration = state.selectionGeneration;
  const requestGeneration = ++state.requestGeneration;
  state.loading = true;
  try {
    const body = await api(`/api/report?${new URLSearchParams({ id })}`);
    if (!requestIsCurrent(selectionGeneration, requestGeneration, source, id)) return;
    if (resetDisplay || body.content !== state.reportContent) {
      renderMarkdown(elements.reportRendered, body.content);
      elements.report.querySelector(".report-source pre").textContent = body.content;
      state.reportContent = body.content;
    }
    setStatus(`${body.size.toLocaleString()} bytes · updated ${displayTime(body.modifiedAt)}`);
  } catch (error) {
    if (requestIsCurrent(selectionGeneration, requestGeneration, source, id)) setStatus(error.message, true);
  } finally {
    if (requestIsCurrent(selectionGeneration, requestGeneration, source, id)) state.loading = false;
  }
}

function selectDisplay(reportSelected) {
  elements.events.hidden = reportSelected;
  elements.report.hidden = !reportSelected;
  elements.journalFilters.hidden = reportSelected;
  elements.journalActions.hidden = reportSelected;
  elements.fromStart.disabled = reportSelected;
  elements.loadMore.disabled = reportSelected;
}

function showLogin(message = "") {
  elements.loginPage.hidden = false;
  elements.appShell.hidden = true;
  if (message) {
    elements.loginStatus.textContent = message;
    elements.loginStatus.classList.toggle("error", true);
  }
  document.title = "Login · Firstmate Viewer";
  if (window.location.pathname !== "/login") {
    state.requestedPath = `${window.location.pathname}${window.location.search}`;
    window.history.replaceState({}, "", `/login?${new URLSearchParams({ return: state.requestedPath })}`);
  }
}

function setAuthenticatedShell() {
  elements.loginPage.hidden = true;
  elements.appShell.hidden = false;
  state.authenticated = true;
}

function setActiveNavigation(route) {
  for (const link of document.querySelectorAll("nav [data-route]")) link.classList.toggle("active", link.dataset.route === route);
}

function routePathForSession(session) {
  if (session.source === "report") return `/report/${encodeURIComponent(session.id)}`;
  return `/journal/${session.source}/${encodeURIComponent(session.id)}`;
}

function updateHistory(path, replace = false) {
  if (`${window.location.pathname}${window.location.search}` === path) return;
  window.history[replace ? "replaceState" : "pushState"]({}, "", path);
}

function clearArtifactSelection(source) {
  if (state.selected?.source === source) state.selectionGeneration += 1;
  state.selected = null;
  state.loading = false;
  state.reportContent = null;
  elements.sessionTitle.textContent = source === "report" ? "Choose a report" : source === "supervisor" ? "Choose a supervisor session" : "Choose a journal";
  elements.reportRendered.replaceChildren();
  elements.report.querySelector(".report-source pre").textContent = "";
  elements.events.replaceChildren();
  setStatus(source === "report" ? "Select a task report from the library." : "Select a work journal from the session list.");
}

function configurePage(source) {
  elements.source.value = source;
  const dashboard = source === "tasks";
  const report = source === "report";
  elements.taskDashboard.hidden = !dashboard;
  elements.artifactViewer.hidden = dashboard;
  elements.pageKind.textContent = report ? "REPORT" : source === "supervisor" ? "SUPERVISOR WORK JOURNAL" : "WORK JOURNAL";
  elements.sidebarEyebrow.textContent = dashboard ? "TASKS" : report ? "REPORTS" : "JOURNALS";
  elements.sidebarTitle.textContent = dashboard ? "Task list" : report ? "Report library" : "Supervisor sessions";
  elements.sessionSearch.placeholder = dashboard ? "Search tasks" : report ? "Search reports" : "Search sessions";
  if (!dashboard && state.selected?.source !== source) {
    clearArtifactSelection(source);
  }
  setActiveNavigation(dashboard ? "dashboard" : report ? "reports" : source === "short" ? "short" : "journal");
  selectDisplay(report);
  renderSessions();
}

async function applyLocation() {
  if (!state.authenticated) return;
  const parts = window.location.pathname.split("/").filter(Boolean).map(decodeURIComponent);
  if (!parts.length || parts[0] === "login") {
    updateHistory("/dashboard", true);
    configurePage("tasks");
    document.title = "Dashboard · Firstmate Viewer";
    return;
  }
  if (parts[0] === "dashboard") {
    configurePage("tasks");
    document.title = "Dashboard · Firstmate Viewer";
    const taskId = new URLSearchParams(window.location.search).get("task");
    const documentType = new URLSearchParams(window.location.search).get("document");
    if (taskId && state.tasks.some(task => task.id === taskId)) await selectTask(taskId, { updateRoute: false, documentType });
    else {
      state.selectedTaskId = taskId || null;
      state.selectedTaskDocumentType = documentType || null;
      state.taskSelectionGeneration += 1;
      renderSessions();
    }
    return;
  }
  if (parts[0] === "reports" || parts[0] === "report") {
    configurePage("report");
    document.title = "Reports · Firstmate Viewer";
    const reportId = parts[0] === "report" ? parts[1] : null;
    if (reportId) {
      const report = state.sessions.find(item => item.source === "report" && item.id === reportId);
      if (report) await selectSession(report, { updateRoute: false });
      else setStatus(`Report ${reportId} is unavailable.`, true);
    } else clearArtifactSelection("report");
    return;
  }
  if (parts[0] === "journal" && ["supervisor", "short"].includes(parts[1])) {
    configurePage(parts[1]);
    document.title = `${parts[1] === "supervisor" ? "Supervisor Work Journal" : "Work Journal"} · Firstmate Viewer`;
    const sessionId = parts[2];
    if (sessionId) {
      const session = state.sessions.find(item => item.source === parts[1] && item.id === sessionId);
      if (session) await selectSession(session, { updateRoute: false });
      else setStatus(`Journal ${sessionId} is unavailable.`, true);
    } else clearArtifactSelection(parts[1]);
    return;
  }
  updateHistory("/dashboard", true);
  configurePage("tasks");
}

const taskStatusOrder = ["Processing", "Queued", "Waiting", "Blocked", "Parked", "Needs reconciliation", "Completed", "Archived", "Cancelled"];
let taskStatusFilter = null;

function taskGroups() {
  const statuses = new Set(state.tasks.map(task => task.status));
  const hasReconciliation = statuses.delete("Needs reconciliation");
  if (hasReconciliation) statuses.add("Completed");
  return [...statuses].sort((left, right) => (taskStatusOrder.indexOf(left) + 1 || Infinity)
    - (taskStatusOrder.indexOf(right) + 1 || Infinity) || left.localeCompare(right))
    .map(status => ({
      key: status,
      label: status,
      matches: task => status === "Completed"
        ? task.status === "Completed" || task.status === "Needs reconciliation"
        : task.status === status,
    }));
}

function taskMatches(task, query) {
  return `${task.id} ${task.title} ${task.status} ${task.kind || ""} ${task.project || ""} ${task.wait || ""} ${task.warning || ""}`.toLowerCase().includes(query);
}

function taskEmptyMessage(query, loadedMessage) {
  if (!state.taskLoaded) {
    if (state.taskLoading) return "Loading task status…";
    if (state.taskLoadError) return `Task loading failed: ${state.taskLoadError}`;
    return "Connect to load task status.";
  }
  return query ? "No matching tasks." : loadedMessage;
}

function taskCard(task) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "task-card";
  button.dataset.category = task.category;
  if (state.selectedTaskId === task.id) button.classList.add("active");
  const badge = document.createElement("span");
  badge.className = "task-state";
  badge.textContent = task.status;
  const title = document.createElement("strong");
  title.textContent = task.title;
  const id = document.createElement("small");
  id.textContent = task.id;
  const metadata = document.createElement("small");
  const documentTypes = task.documentTypes || (task.documentType ? [task.documentType] : []);
  const documentLabel = documentTypes.includes("brief") && documentTypes.includes("report") ? "Brief + report"
    : documentTypes.includes("report") ? "Task report"
    : documentTypes.includes("brief") ? "Task brief"
    : "No document";
  metadata.textContent = [task.project, task.kind, documentLabel].filter(Boolean).join(" · ");
  button.append(badge, title, id, metadata);
  if (task.warning) {
    const warning = document.createElement("small");
    warning.className = "task-warning";
    warning.textContent = task.warning;
    button.append(warning);
  }
  button.addEventListener("click", () => selectTask(task.id));
  return button;
}

function renderTaskDashboard() {
  elements.taskCounts.replaceChildren();
  const query = elements.sessionSearch.value.toLowerCase();
  const visibleTasks = state.tasks.filter(task => taskMatches(task, query));
  for (const group of taskGroups()) {
    const count = visibleTasks.filter(group.matches).length;
    const counter = document.createElement("button");
    counter.type = "button";
    counter.className = "task-count";
    counter.classList.toggle("active", taskStatusFilter === group.key);
    counter.setAttribute("aria-pressed", String(taskStatusFilter === group.key));
    const name = document.createElement("span");
    name.textContent = group.label;
    const value = document.createElement("strong");
    value.textContent = state.taskLoaded ? String(count) : "—";
    counter.append(name, value);
    counter.addEventListener("click", () => {
      taskStatusFilter = taskStatusFilter === group.key ? null : group.key;
      state.selectedTaskId = null;
      state.selectedTaskDocumentType = null;
      state.taskSelectionGeneration += 1;
      renderSessions();
    });
    elements.taskCounts.append(counter);
  }
  const all = document.createElement("button");
  all.type = "button";
  all.className = "quiet task-count-reset";
  all.textContent = "View all tasks";
  all.hidden = !taskStatusFilter;
  all.addEventListener("click", () => {
    taskStatusFilter = null;
    renderSessions();
  });
  elements.taskCounts.append(all);
  renderTaskDetail();
}

function renderTaskDetail() {
  const task = state.tasks.find(item => item.id === state.selectedTaskId);
  elements.taskDetail.hidden = !task;
  elements.dashboardEmpty.hidden = Boolean(task);
  if (!task) {
    elements.dashboardEmptyTitle.textContent = state.selectedTaskId ? "Task unavailable" : "Select a task";
    elements.dashboardEmptyCopy.textContent = state.selectedTaskId
      ? `Task ${state.selectedTaskId} is not available in the current inventory.`
      : "Choose a task from the sidebar to inspect its exact identity, state, brief, and report.";
    return;
  }
  elements.taskDetailState.textContent = task.status;
  elements.taskDetailTitle.textContent = task.title;
  elements.taskDetailMeta.textContent = [task.id, task.project, task.kind].filter(Boolean).join(" · ");
  elements.taskDetailWait.hidden = !task.wait;
  elements.taskDetailWait.textContent = task.wait || "";
  elements.taskDetailWarning.hidden = !task.warning;
  elements.taskDetailWarning.textContent = task.warning || "";
  const documentTypes = task.documentTypes || (task.documentType ? [task.documentType] : []);
  for (const [source, button, label] of [
    ["brief", elements.taskDocumentBrief, "Brief"],
    ["report", elements.taskDocumentReport, "Report"],
  ]) {
    const available = documentTypes.includes(source);
    button.disabled = !available;
    button.textContent = available ? label : `${label} unavailable`;
    button.setAttribute("aria-selected", String(state.selectedTaskDocumentType === source));
  }
  elements.openTaskReport.hidden = !documentTypes.includes("report");
}

function clearTaskDocument(message) {
  state.taskDocumentContent = null;
  elements.taskDocumentType.hidden = true;
  elements.taskDocumentType.textContent = "";
  elements.taskDocumentRendered.replaceChildren();
  elements.taskDocumentSource.hidden = true;
  elements.taskDocumentSource.querySelector("pre").textContent = "";
  elements.taskDocumentEmpty.hidden = false;
  elements.taskDocumentEmpty.textContent = message;
}

function taskDocumentRequestIsCurrent(taskId, documentType, selectionGeneration) {
  const currentTask = state.tasks.find(item => item.id === taskId);
  const currentTypes = currentTask?.documentTypes || (currentTask?.documentType ? [currentTask.documentType] : []);
  return selectionGeneration === state.taskSelectionGeneration
    && state.selectedTaskId === taskId
    && state.selectedTaskDocumentType === documentType
    && currentTypes.includes(documentType)
    && elements.source.value === "tasks";
}

async function loadTaskDocument({ resetDisplay = false, preserveViewport = null } = {}) {
  const task = state.tasks.find(item => item.id === state.selectedTaskId);
  if (!task) return;
  if (!task.hasDocument) {
    clearTaskDocument("No canonical task document is available for this task.");
    return;
  }
  const documentTypes = task.documentTypes || (task.documentType ? [task.documentType] : []);
  const documentType = documentTypes.includes(state.selectedTaskDocumentType) ? state.selectedTaskDocumentType : documentTypes.includes("report") ? "report" : documentTypes[0];
  state.selectedTaskDocumentType = documentType;
  renderTaskDetail();
  const taskId = task.id;
  const selectionGeneration = state.taskSelectionGeneration;
  if (state.taskDocumentLoading?.taskId === taskId && state.taskDocumentLoading?.documentType === documentType && state.taskDocumentLoading?.selectionGeneration === selectionGeneration) return;
  const request = { taskId, documentType, selectionGeneration };
  state.taskDocumentLoading = request;
  if (resetDisplay) clearTaskDocument("Loading task document…");
  try {
    const body = await api(`/api/task-document?${new URLSearchParams({ id: taskId, type: documentType })}`);
    if (!taskDocumentRequestIsCurrent(taskId, documentType, selectionGeneration)) return;
    if (resetDisplay || body.content !== state.taskDocumentContent) {
      const preservedScrollY = preserveViewport?.() ? window.scrollY : null;
      renderMarkdown(elements.taskDocumentRendered, body.content);
      elements.taskDocumentSource.querySelector("pre").textContent = body.content;
      state.taskDocumentContent = body.content;
      if (preservedScrollY !== null) window.requestAnimationFrame(() => window.scrollTo({ top: preservedScrollY }));
    }
    elements.taskDocumentType.textContent = body.source === "report" ? "Task report" : "Task brief";
    elements.taskDocumentType.hidden = false;
    elements.taskDocumentEmpty.hidden = true;
    elements.taskDocumentSource.hidden = false;
  } catch (error) {
    if (!taskDocumentRequestIsCurrent(taskId, documentType, selectionGeneration)) return;
    if (error.status === 401) invalidateCredential("Saved access token was rejected. Enter a valid token to continue.");
    else clearTaskDocument(error.message);
  } finally {
    if (state.taskDocumentLoading === request) state.taskDocumentLoading = null;
  }
}

async function selectTask(id, { updateRoute = true, documentType = null } = {}) {
  state.taskSelectionGeneration += 1;
  const selectionGeneration = state.taskSelectionGeneration;
  let revealCancelled = false;
  const cancelReveal = () => { revealCancelled = true; };
  state.selectedTaskId = id;
  const task = state.tasks.find(item => item.id === id);
  const documentTypes = task?.documentTypes || (task?.documentType ? [task.documentType] : []);
  state.selectedTaskDocumentType = documentTypes.includes(documentType) ? documentType : documentTypes.includes("report") ? "report" : documentTypes[0] || null;
  if (updateRoute) updateHistory(`/dashboard?${new URLSearchParams({ task: id, ...(state.selectedTaskDocumentType ? { document: state.selectedTaskDocumentType } : {}) })}`);
  else if (documentType && documentType !== state.selectedTaskDocumentType) updateHistory(`/dashboard?${new URLSearchParams({ task: id, ...(state.selectedTaskDocumentType ? { document: state.selectedTaskDocumentType } : {}) })}`, true);
  renderSessions();
  elements.taskDetail.scrollIntoView({ block: "start" });
  for (const event of ["keydown", "pointerdown", "touchstart", "wheel"]) window.addEventListener(event, cancelReveal, { passive: true });
  try {
    await loadTaskDocument({ resetDisplay: true, preserveViewport: () => revealCancelled });
    if (state.taskSelectionGeneration === selectionGeneration && state.selectedTaskId === id) {
      if (!revealCancelled) elements.taskDetail.scrollIntoView({ block: "start" });
    }
  } finally {
    for (const event of ["keydown", "pointerdown", "touchstart", "wheel"]) window.removeEventListener(event, cancelReveal);
  }
}

async function selectTaskDocument(type) {
  const task = state.tasks.find(item => item.id === state.selectedTaskId);
  const documentTypes = task?.documentTypes || (task?.documentType ? [task.documentType] : []);
  if (!documentTypes.includes(type) || state.selectedTaskDocumentType === type) return;
  state.taskSelectionGeneration += 1;
  state.selectedTaskDocumentType = type;
  updateHistory(`/dashboard?${new URLSearchParams({ task: task.id, document: type })}`);
  renderTaskDetail();
  await loadTaskDocument({ resetDisplay: true });
}

async function loadTasks() {
  if (!state.token || state.taskLoading) return;
  const requestGeneration = ++state.taskRequestGeneration;
  state.taskLoading = true;
  state.taskLoadError = "";
  elements.taskStatus.textContent = state.taskLoaded ? "Refreshing task status…" : "Loading task status…";
  elements.retryTasks.hidden = true;
  if (!state.taskLoaded) renderSessions();
  try {
    const generationQuery = state.taskSnapshotGeneration
      ? `?${new URLSearchParams({ generation: state.taskSnapshotGeneration })}`
      : "";
    const body = await api(`/api/tasks${generationQuery}`);
    if (requestGeneration !== state.taskRequestGeneration) return;
    const snapshotGeneration = typeof body.generatedAt === "string" ? body.generatedAt : null;
    const snapshotChanged = !state.taskLoaded || body.unchanged !== true;
    state.taskLoaded = true;
    if (snapshotChanged) {
      state.tasks = body.tasks;
      state.taskSnapshotGeneration = snapshotGeneration;
      if (state.selectedTaskId && !state.tasks.some(task => task.id === state.selectedTaskId)) {
        state.taskSelectionGeneration += 1;
        clearTaskDocument("");
      }
      renderSessions();
    }
    const cacheLabel = body.cacheHit ? ` · cached snapshot ${Math.round(body.cacheAgeMs / 1000)}s old` : "";
    const refreshLabel = body.refreshing ? " · refreshing in background" : "";
    const refreshError = body.refreshError ? ` · ${body.refreshError}` : "";
    elements.taskStatus.textContent = `${state.tasks.length} tasks · refreshed ${displayTime(body.generatedAt)}${cacheLabel}${refreshLabel}${refreshError}${body.warning ? ` · ${body.warning}` : ""}`;
  } catch (error) {
    if (requestGeneration !== state.taskRequestGeneration) return;
    if (error.status === 401) invalidateCredential("Saved access token was rejected. Enter a valid token to continue.");
    else {
      state.taskLoadError = error.message;
      elements.taskStatus.textContent = error.message;
      elements.retryTasks.hidden = false;
    }
  } finally {
    if (requestGeneration === state.taskRequestGeneration) {
      state.taskLoading = false;
      if (state.taskLoadError) renderSessions();
    }
  }
}

function showSelectedView() {
  const source = elements.source.value;
  state.taskSelectionGeneration += 1;
  if (source === "tasks") updateHistory("/dashboard");
  else if (source === "report") updateHistory("/reports");
  else updateHistory(`/journal/${source === "all" ? "supervisor" : source}`);
  configurePage(source === "all" ? "supervisor" : source);
}

function renderSessions() {
  const source = elements.source.value;
  const query = elements.sessionSearch.value.toLowerCase();
  if (source === "tasks") {
    const group = taskGroups().find(candidate => candidate.key === taskStatusFilter);
    const matches = state.tasks.filter(task => (!group || group.matches(task)) && taskMatches(task, query));
    elements.sessions.replaceChildren();
    for (const task of matches) elements.sessions.append(taskCard(task));
    if (!matches.length) {
      const empty = document.createElement("p");
      empty.className = "empty";
      empty.textContent = taskEmptyMessage(query, "No matching tasks.");
      elements.sessions.append(empty);
    }
    renderTaskDashboard();
    return;
  }
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
    const sourceLabel = session.source === "short" ? "Short agent" : session.source === "supervisor" ? "Supervisor" : "Task report";
    metadata.textContent = `${sourceLabel} · ${displayTime(session.modifiedAt)} · ${session.bytes.toLocaleString()} B`;
    button.append(name, metadata);
    button.addEventListener("click", () => selectSession(session));
    elements.sessions.append(button);
  }
  if (!matches.length) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = "No matching journals or reports.";
    elements.sessions.append(empty);
  }
}

async function selectSession(session, { updateRoute = true } = {}) {
  state.selectionGeneration += 1;
  state.selected = session;
  if (updateRoute) updateHistory(routePathForSession(session));
  state.loading = false;
  elements.sessionTitle.textContent = session.label;
  renderSessions();
  const reportSelected = session.source === "report";
  selectDisplay(reportSelected);
  if (reportSelected) {
    state.reportContent = null;
    elements.reportRendered.replaceChildren();
    elements.report.querySelector(".report-source pre").textContent = "";
    showNotice();
    await loadReport({ resetDisplay: true });
  } else {
    await loadEvents({ resetDisplay: true });
  }
}

async function connect({ restored = false } = {}) {
  state.token = elements.token.value;
  if (!state.token) return setStatus("Enter an access token.", true);
  try {
    const body = await api("/api/sessions");
    state.sessions = [...body.sessions, ...body.reports].sort((left, right) => right.modifiedAt.localeCompare(left.modifiedAt));
    if (elements.rememberToken.checked) storedToken("set", state.token);
    else storedToken("remove");
    elements.forget.disabled = false;
    setAuthenticatedShell();
    setStatus(`${body.sessions.length} journals and ${body.reports.length} reports available.`);
    await loadTasks();
    if (window.location.pathname === "/login") {
      const returnPath = new URLSearchParams(window.location.search).get("return");
      updateHistory(/^\/(?!\/)/.test(returnPath || "") ? returnPath : state.requestedPath !== "/" ? state.requestedPath : "/dashboard", true);
    }
    await applyLocation();
  } catch (error) {
    if (error.status === 401) invalidateCredential(restored ? "Saved access token was rejected. Enter a valid token to continue." : "Access token was rejected.");
    else {
      state.sessions = [];
      renderSessions();
      setStatus(error.message, true);
    }
  }
}

function forgetToken() {
  invalidateCredential("Access token forgotten. Enter a token to reconnect.");
}

elements.connect.addEventListener("click", () => connect());
elements.forget.addEventListener("click", forgetToken);
elements.rememberToken.addEventListener("change", () => {
  if (!elements.rememberToken.checked) storedToken("remove");
});
elements.closeTask.addEventListener("click", () => {
  state.selectedTaskId = null;
  state.selectedTaskDocumentType = null;
  state.taskSelectionGeneration += 1;
  updateHistory("/dashboard");
  renderTaskDashboard();
});
elements.taskDocumentBrief.addEventListener("click", () => selectTaskDocument("brief"));
elements.taskDocumentReport.addEventListener("click", () => selectTaskDocument("report"));
elements.openTaskReport.addEventListener("click", () => {
  const task = state.tasks.find(item => item.id === state.selectedTaskId);
  const documentTypes = task?.documentTypes || (task?.documentType ? [task.documentType] : []);
  if (!documentTypes.includes("report")) return;
  configurePage("report");
  selectSession({ source: "report", id: task.id, label: task.id });
});
elements.token.addEventListener("keydown", event => { if (event.key === "Enter") connect(); });
elements.source.addEventListener("change", showSelectedView);
elements.retryTasks.addEventListener("click", loadTasks);
elements.sidebarToggle.addEventListener("click", () => {
  state.sidebarCollapsed = !state.sidebarCollapsed;
  elements.viewerLayout.classList.toggle("sidebar-collapsed", state.sidebarCollapsed);
  elements.sidebarToggle.setAttribute("aria-expanded", String(!state.sidebarCollapsed));
  elements.sidebarToggle.setAttribute("aria-label", state.sidebarCollapsed ? "Open task list" : "Collapse task list");
});
for (const link of document.querySelectorAll("[data-route]")) link.addEventListener("click", event => {
  event.preventDefault();
  updateHistory(link.getAttribute("href"));
  applyLocation();
});
window.addEventListener("popstate", () => applyLocation());
elements.sessionSearch.addEventListener("input", renderSessions);
elements.eventSearch.addEventListener("input", applyFilters);
elements.roleFilter.addEventListener("change", applyFilters);
elements.typeFilter.addEventListener("change", applyFilters);
elements.loadMore.addEventListener("click", () => loadEvents());
elements.fromStart.addEventListener("click", () => loadEvents({ resetDisplay: true, fromStart: true }));

state.timer = window.setInterval(() => {
  if (!state.token) return;
  if (elements.source.value === "tasks") {
    if (!elements.taskFollow.checked) return;
    loadTasks();
    if (state.selectedTaskId) loadTaskDocument();
    return;
  }
  if (!state.selected || !elements.follow.checked) return;
  if (state.selected.source === "report") loadReport();
  else if (state.eof || state.partialBytes > 0) loadEvents();
}, 1000);

const savedToken = storedToken("get");
if (savedToken) {
  elements.token.value = savedToken;
  elements.rememberToken.checked = true;
  connect({ restored: true });
} else showLogin();
