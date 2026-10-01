const state = {
  token: "",
  sessions: [],
  tasks: [],
  selected: null,
  selectedTaskId: null,
  entries: [],
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
  taskSelectionGeneration: 0,
  taskDocumentLoading: null,
  taskDocumentContent: null,
  timer: null,
};

const TOKEN_STORAGE_KEY = "firstmate.jsonlViewer.accessToken.v1";

const elements = {
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
  taskFollow: document.getElementById("task-follow"),
  taskCounts: document.getElementById("task-counts"),
  taskGroups: document.getElementById("task-groups"),
  taskDetail: document.getElementById("task-detail"),
  taskDetailState: document.getElementById("task-detail-state"),
  taskDetailTitle: document.getElementById("task-detail-title"),
  taskDetailMeta: document.getElementById("task-detail-meta"),
  taskDetailWait: document.getElementById("task-detail-wait"),
  taskDocumentEmpty: document.getElementById("task-document-empty"),
  taskDocumentRendered: document.getElementById("task-document-rendered"),
  taskDocumentSource: document.getElementById("task-document-source"),
  closeTask: document.getElementById("close-task"),
};

function setStatus(message, error = false) {
  elements.status.textContent = message;
  elements.status.classList.toggle("error", error);
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
  state.selected = null;
  state.selectedTaskId = null;
  state.selectionGeneration += 1;
  state.taskSelectionGeneration += 1;
  state.taskRequestGeneration += 1;
  state.taskLoading = false;
  state.taskDocumentLoading = null;
  elements.token.value = "";
  elements.rememberToken.checked = false;
  elements.forget.disabled = true;
  storedToken("remove");
  renderSessions();
  renderTaskDashboard();
  setStatus(message, true);
  elements.taskStatus.textContent = message;
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
  if (!state.selected || state.selected.source === "report" || (state.loading && !resetDisplay)) return;
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
    setStatus(`${body.size.toLocaleString()} bytes · updated ${new Date(body.modifiedAt).toLocaleString()}`);
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

const taskGroups = [
  ["processing", "Processing"],
  ["held", "Waiting or blocked"],
  ["completed", "Completed"],
  ["history", "Archived or cancelled"],
];

function taskMatches(task, query) {
  return `${task.id} ${task.title} ${task.status} ${task.kind || ""} ${task.project || ""} ${task.wait || ""}`.toLowerCase().includes(query);
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
  metadata.textContent = [task.project, task.kind, task.hasDocument ? "Document available" : "No document"].filter(Boolean).join(" · ");
  button.append(badge, title, id, metadata);
  button.addEventListener("click", () => selectTask(task.id));
  return button;
}

function renderTaskDashboard() {
  const query = elements.sessionSearch.value.toLowerCase();
  const visible = state.tasks.filter(task => taskMatches(task, query));
  elements.taskCounts.replaceChildren();
  elements.taskGroups.replaceChildren();
  for (const [category, label] of taskGroups) {
    const count = state.tasks.filter(task => task.category === category).length;
    const counter = document.createElement("div");
    counter.className = "task-count";
    const name = document.createElement("span");
    name.textContent = label;
    const value = document.createElement("strong");
    value.textContent = String(count);
    counter.append(name, value);
    elements.taskCounts.append(counter);

    const group = document.createElement("section");
    group.className = "task-group";
    group.dataset.category = category;
    const heading = document.createElement("h3");
    heading.textContent = label;
    const list = document.createElement("div");
    list.className = "task-list";
    const matches = visible.filter(task => task.category === category);
    for (const task of matches) list.append(taskCard(task));
    if (!matches.length) {
      const empty = document.createElement("p");
      empty.className = "empty";
      empty.textContent = query ? "No matching tasks." : "No tasks in this category.";
      list.append(empty);
    }
    group.append(heading, list);
    elements.taskGroups.append(group);
  }
  renderTaskDetail();
}

function renderTaskDetail() {
  const task = state.tasks.find(item => item.id === state.selectedTaskId);
  elements.taskDetail.hidden = !task;
  if (!task) return;
  elements.taskDetailState.textContent = task.status;
  elements.taskDetailTitle.textContent = task.title;
  elements.taskDetailMeta.textContent = [task.id, task.project, task.kind].filter(Boolean).join(" · ");
  elements.taskDetailWait.hidden = !task.wait;
  elements.taskDetailWait.textContent = task.wait || "";
}

function clearTaskDocument(message) {
  state.taskDocumentContent = null;
  elements.taskDocumentRendered.replaceChildren();
  elements.taskDocumentSource.hidden = true;
  elements.taskDocumentSource.querySelector("pre").textContent = "";
  elements.taskDocumentEmpty.hidden = false;
  elements.taskDocumentEmpty.textContent = message;
}

async function loadTaskDocument({ resetDisplay = false } = {}) {
  const task = state.tasks.find(item => item.id === state.selectedTaskId);
  if (!task) return;
  if (!task.hasDocument) {
    clearTaskDocument("No Markdown report or document is available for this task.");
    return;
  }
  const taskId = task.id;
  const selectionGeneration = state.taskSelectionGeneration;
  if (state.taskDocumentLoading?.taskId === taskId && state.taskDocumentLoading?.selectionGeneration === selectionGeneration) return;
  const request = { taskId, selectionGeneration };
  state.taskDocumentLoading = request;
  if (resetDisplay) clearTaskDocument("Loading task document…");
  try {
    const body = await api(`/api/report?${new URLSearchParams({ id: taskId })}`);
    if (selectionGeneration !== state.taskSelectionGeneration || state.selectedTaskId !== taskId || elements.source.value !== "tasks") return;
    if (resetDisplay || body.content !== state.taskDocumentContent) {
      renderMarkdown(elements.taskDocumentRendered, body.content);
      elements.taskDocumentSource.querySelector("pre").textContent = body.content;
      state.taskDocumentContent = body.content;
    }
    elements.taskDocumentEmpty.hidden = true;
    elements.taskDocumentSource.hidden = false;
  } catch (error) {
    if (selectionGeneration !== state.taskSelectionGeneration || state.selectedTaskId !== taskId) return;
    if (error.status === 401) invalidateCredential("Saved access token was rejected. Enter a valid token to continue.");
    else clearTaskDocument(error.message);
  } finally {
    if (state.taskDocumentLoading === request) state.taskDocumentLoading = null;
  }
}

async function selectTask(id) {
  state.taskSelectionGeneration += 1;
  state.selectedTaskId = id;
  renderSessions();
  await loadTaskDocument({ resetDisplay: true });
}

async function loadTasks() {
  if (!state.token || state.taskLoading) return;
  const requestGeneration = ++state.taskRequestGeneration;
  state.taskLoading = true;
  try {
    const body = await api("/api/tasks");
    if (requestGeneration !== state.taskRequestGeneration) return;
    state.tasks = body.tasks;
    if (state.selectedTaskId && !state.tasks.some(task => task.id === state.selectedTaskId)) {
      state.selectedTaskId = null;
      state.taskSelectionGeneration += 1;
      clearTaskDocument("");
    }
    renderSessions();
    elements.taskStatus.textContent = `${body.tasks.length} tasks · refreshed ${new Date(body.generatedAt).toLocaleString()}${body.warning ? ` · ${body.warning}` : ""}`;
  } catch (error) {
    if (requestGeneration !== state.taskRequestGeneration) return;
    if (error.status === 401) invalidateCredential("Saved access token was rejected. Enter a valid token to continue.");
    else elements.taskStatus.textContent = error.message;
  } finally {
    if (requestGeneration === state.taskRequestGeneration) state.taskLoading = false;
  }
}

function showSelectedView() {
  const dashboard = elements.source.value === "tasks";
  elements.taskDashboard.hidden = !dashboard;
  elements.artifactViewer.hidden = dashboard;
  if (!dashboard) state.taskSelectionGeneration += 1;
  renderSessions();
}

function renderSessions() {
  const source = elements.source.value;
  const query = elements.sessionSearch.value.toLowerCase();
  if (source === "tasks") {
    const matches = state.tasks.filter(task => taskMatches(task, query));
    elements.sessions.replaceChildren();
    for (const task of matches) elements.sessions.append(taskCard(task));
    if (!matches.length) {
      const empty = document.createElement("p");
      empty.className = "empty";
      empty.textContent = "No matching tasks.";
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
    metadata.textContent = `${sourceLabel} · ${new Date(session.modifiedAt).toLocaleString()} · ${session.bytes.toLocaleString()} B`;
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

async function selectSession(session) {
  state.selectionGeneration += 1;
  state.selected = session;
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
    renderSessions();
    setStatus(`${body.sessions.length} journals and ${body.reports.length} reports available.`);
    await loadTasks();
    if (elements.source.value !== "tasks" && !state.selected && state.sessions.length) await selectSession(state.sessions[0]);
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
  state.taskSelectionGeneration += 1;
  renderTaskDashboard();
});
elements.token.addEventListener("keydown", event => { if (event.key === "Enter") connect(); });
elements.source.addEventListener("change", showSelectedView);
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

showSelectedView();
const savedToken = storedToken("get");
if (savedToken) {
  elements.token.value = savedToken;
  elements.rememberToken.checked = true;
  connect({ restored: true });
}
