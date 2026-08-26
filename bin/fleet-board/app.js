"use strict";

const {
  actionStorageKey,
  actionTextError,
  applyActionObservation,
  beginAction,
  cardFingerprint,
  clearHandledActionOperations,
  dialogDraftFingerprint,
  draftIsAvailable,
  normalizeActionText,
  reconcileBoardState,
  recordAcceptedAction,
  restoreActionOperations,
  serializeActionOperations,
  shouldAnnounceLoadFailure,
  submittedRequestIds,
  syncStoredActionOperations,
  updateLiveStatus,
  updateValue,
} = globalThis.FleetBoardState;

function restoredActionOperations(storageKey, maxActionBytes) {
  try {
    return restoreActionOperations(localStorage.getItem(storageKey), maxActionBytes);
  } catch {
    return new Map();
  }
}

const state = {
  board: null,
  csrf: "",
  selectedKey: null,
  dialogOpenerKey: null,
  pending: new Map(),
  drafts: new Map(),
  operationStorageKey: null,
  maxActionBytes: null,
  renderedBoard: "",
  loading: false,
  loadFailures: { initialFailureAnnounced: false },
};

function persistActionOperations() {
  if (!state.operationStorageKey) return false;
  try {
    const serialized = serializeActionOperations(state.drafts, state.maxActionBytes);
    if (JSON.parse(serialized).operations.length) {
      localStorage.setItem(state.operationStorageKey, serialized);
    } else {
      localStorage.removeItem(state.operationStorageKey);
    }
    return true;
  } catch {
    return false;
  }
}

function configureActionStorage(scope, maxActionBytes) {
  const storageKey = actionStorageKey(scope);
  if (!Number.isSafeInteger(maxActionBytes) || maxActionBytes <= 0) {
    throw new Error("Fleet board action limit is invalid");
  }
  if (storageKey === state.operationStorageKey && maxActionBytes === state.maxActionBytes) return;
  state.operationStorageKey = storageKey;
  state.maxActionBytes = maxActionBytes;
  state.drafts = restoredActionOperations(storageKey, maxActionBytes);
}

const elements = {
  board: document.querySelector("#board"),
  empty: document.querySelector("#empty-state"),
  search: document.querySelector("#search"),
  homeFilter: document.querySelector("#home-filter"),
  riskFilter: document.querySelector("#risk-filter"),
  refresh: document.querySelector("#refresh"),
  freshnessDot: document.querySelector("#freshness-dot"),
  freshnessLabel: document.querySelector("#freshness-label"),
  freshnessAnnouncement: document.querySelector("#freshness-announcement"),
  warnings: document.querySelector("#warnings"),
  needsYouCount: document.querySelector("#needs-you-count"),
  openCount: document.querySelector("#open-count"),
  riskCount: document.querySelector("#risk-count"),
  needsYouSignal: document.querySelector("#needs-you-signal"),
  dialog: document.querySelector("#task-dialog"),
  dialogTitle: document.querySelector("#dialog-title"),
  dialogHome: document.querySelector("#dialog-home"),
  dialogBody: document.querySelector("#dialog-body"),
  dialogActions: document.querySelector("#dialog-actions"),
  dialogClose: document.querySelector("#dialog-close"),
  laneTemplate: document.querySelector("#lane-template"),
  cardTemplate: document.querySelector("#card-template"),
};

function node(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined && text !== null) element.textContent = text;
  return element;
}

function focusedKey(container) {
  const active = document.activeElement;
  return active && container.contains(active) ? active.dataset.focusKey || null : null;
}

function focusByKey(key, fallback = null) {
  if (!key) return;
  const target = [...document.querySelectorAll("[data-focus-key]")]
    .find((element) => element.dataset.focusKey === key);
  (target || fallback)?.focus();
}

function riskLabel(risk) {
  return risk.level === "unknown" ? "Unassessed" : `${risk.level} risk`;
}

function homeLabel(home) {
  return home.namespace === "secondmate" ? `${home.label} · secondmate` : home.label;
}

function relativeTime(value) {
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) return "just now";
  const seconds = Math.max(0, Math.round((Date.now() - timestamp) / 1000));
  if (seconds < 10) return "just now";
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(timestamp);
}

function cardPresentation(card) {
  const { observed_at: _observedAt, ...presented } = card;
  return presented;
}

function dialogFingerprint(card) {
  return JSON.stringify({
    card: cardPresentation(card),
    pending: state.pending.has(card.key),
    draft: dialogDraftFingerprint(state.drafts.get(card.key)),
  });
}

function visibleCards() {
  if (!state.board) return [];
  const query = elements.search.value.trim().toLocaleLowerCase();
  const home = elements.homeFilter.value;
  const risk = elements.riskFilter.value;
  return state.board.cards.filter((card) => {
    if (home !== "all" && card.home.key !== home) return false;
    if (risk !== "all" && card.risk.level !== risk) return false;
    if (!query) return true;
    const haystack = [
      card.title,
      card.id,
      card.repo,
      card.kind,
      card.context,
      card.status.label,
      card.status.detail,
      card.status.wait_reason,
      card.home.label,
      card.risk.rationale,
      ...(card.decisions || []).flatMap((decision) => [decision.summary, decision.reason]),
    ]
      .filter(Boolean)
      .join(" ")
      .toLocaleLowerCase();
    return haystack.includes(query);
  });
}

function updateHomeFilter() {
  const selected = elements.homeFilter.value;
  const fragment = document.createDocumentFragment();
  const all = node("option", "", "All homes");
  all.value = "all";
  fragment.append(all);
  for (const home of state.board.homes) {
    const option = node("option", "", `${homeLabel(home)}${home.remote ? " · remote" : ""}`);
    option.value = home.key;
    fragment.append(option);
  }
  elements.homeFilter.replaceChildren(fragment);
  elements.homeFilter.value = [...elements.homeFilter.options].some((option) => option.value === selected)
    ? selected
    : "all";
}

function cardNode(card) {
  const fragment = elements.cardTemplate.content.cloneNode(true);
  const article = fragment.querySelector(".task-card");
  const open = fragment.querySelector(".card-open");
  const risk = fragment.querySelector(".risk-badge");
  const home = fragment.querySelector(".home-badge");
  const pending = state.pending.get(card.key);
  article.dataset.key = card.key;
  risk.dataset.risk = card.risk.level;
  risk.textContent = riskLabel(card.risk);
  home.textContent = homeLabel(card.home);
  fragment.querySelector(".card-title").textContent = card.title;
  fragment.querySelector(".card-status").textContent = pending
    ? "Sent to Firstmate"
    : card.decisions?.length > 1
      ? `${card.decisions.length} decisions need you`
      : card.status.wait_reason || card.status.label;
  fragment.querySelector(".card-context").textContent = card.context || "";
  fragment.querySelector(".card-evidence").textContent = card.evidence.length
    ? `${card.evidence.length} evidence ${card.evidence.length === 1 ? "item" : "items"}`
    : "No linked evidence yet";
  fragment.querySelector(".card-id").textContent = card.id || "Unstructured record";
  open.setAttribute("aria-label", `Open details for ${card.title}`);
  open.dataset.focusKey = `card:${card.key}`;
  open.addEventListener("click", () => {
    state.dialogOpenerKey = card.key;
    openCard(card.key);
  });
  return fragment;
}

function renderBoard() {
  if (!state.board) return;
  const cards = visibleCards();
  const fingerprint = JSON.stringify({
    cards: cards.map(cardPresentation),
    pending: [...state.pending.keys()].sort(),
    query: elements.search.value,
    home: elements.homeFilter.value,
    risk: elements.riskFilter.value,
  });
  if (fingerprint === state.renderedBoard) return;
  const focusKey = focusedKey(elements.board);
  const fragment = document.createDocumentFragment();
  for (const lane of state.board.lanes) {
    const laneFragment = elements.laneTemplate.content.cloneNode(true);
    const section = laneFragment.querySelector(".lane");
    const laneCards = laneFragment.querySelector(".lane-cards");
    const matches = cards.filter((card) => card.lane === lane.id);
    section.dataset.lane = lane.id;
    section.setAttribute("aria-label", `${lane.label}, ${matches.length} tasks`);
    laneFragment.querySelector(".lane-title").textContent = lane.label;
    laneFragment.querySelector(".lane-description").textContent = lane.description;
    laneFragment.querySelector(".lane-count").textContent = String(matches.length);
    if (!matches.length) {
      laneCards.append(node("p", "lane-empty", "No tasks in this lane"));
    } else {
      for (const card of matches) laneCards.append(cardNode(card));
    }
    fragment.append(laneFragment);
  }
  elements.board.replaceChildren(fragment);
  state.renderedBoard = fingerprint;
  elements.empty.hidden = cards.length > 0;
  focusByKey(focusKey, elements.board);
}

function renderWarnings() {
  const messages = [...state.board.warnings];
  if (state.board.health?.stale && state.board.health.error) {
    messages.unshift(`Showing the last good snapshot: ${state.board.health.error}`);
  }
  if (!updateValue(elements.warnings.dataset, "fingerprint", JSON.stringify(messages))) return;
  elements.warnings.hidden = messages.length === 0;
  elements.warnings.replaceChildren(...messages.map((message) => node("p", "", message)));
}

function renderSummary() {
  const summary = state.board.summary;
  elements.needsYouCount.textContent = String(summary.needs_you);
  elements.openCount.textContent = String(summary.open);
  elements.riskCount.textContent = String(summary.high_risk_open);
  elements.needsYouSignal.dataset.active = String(summary.needs_you > 0);
}

function detailCell(label, value) {
  const cell = node("div", "detail-cell");
  cell.append(node("span", "detail-label", label));
  cell.append(node("p", "detail-value", value || "Not recorded"));
  return cell;
}

function evidenceSection(card) {
  const section = node("section", "detail-section");
  section.append(node("span", "detail-label", "Evidence"));
  if (!card.evidence.length) {
    section.append(node("p", "detail-value", "No evidence has been linked yet."));
    return section;
  }
  const list = node("ul", "evidence-list");
  for (const item of card.evidence) {
    const row = node("li");
    row.append(node("span", "", item.label));
    if (item.url && /^https?:\/\//.test(item.url)) {
      const link = node("a", "", item.value);
      link.href = item.url;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.dataset.focusKey = `dialog:evidence:${item.kind}:${item.value}`;
      row.append(link);
    } else {
      row.append(node("code", "", item.value));
    }
    list.append(row);
  }
  section.append(list);
  return section;
}

function decisionsSection(card) {
  if (!card.decisions?.length) return null;
  const section = node("section", "detail-section");
  section.append(node("span", "detail-label", "Captain decisions"));
  const list = node("ol", "decision-list");
  for (const decision of card.decisions) {
    const row = node("li");
    row.append(node("strong", "", decision.summary));
    if (decision.reason && decision.reason !== decision.summary) {
      row.append(node("p", "", decision.reason));
    }
    row.append(node("code", "", decision.key));
    list.append(row);
  }
  section.append(list);
  return section;
}

function openCard(key) {
  const card = state.board?.cards.find((item) => item.key === key);
  if (!card) {
    state.selectedKey = null;
    if (elements.dialog.open) elements.dialog.close();
    return;
  }
  const wasOpen = elements.dialog.open;
  const renderFingerprint = dialogFingerprint(card);
  if (wasOpen && elements.dialog.dataset.renderFingerprint === renderFingerprint) {
    state.selectedKey = key;
    return;
  }
  const focusKey = focusedKey(elements.dialog);
  state.selectedKey = key;
  elements.dialogHome.textContent = `${homeLabel(card.home)} · ${card.lane.replaceAll("_", " ")}`;
  elements.dialogTitle.textContent = card.title;

  const lead = node("section", "detail-lead");
  lead.dataset.captain = String(card.status.waiting_for_captain);
  lead.append(node("strong", "", state.pending.has(card.key) ? "Instruction sent to Firstmate" : card.status.label));
  lead.append(
    node(
      "p",
      "",
      state.pending.has(card.key)
        ? "The card stays in its canonical lane until Firstmate processes the instruction."
        : card.status.wait_reason || card.status.detail || "No further status detail is recorded."
    )
  );
  const grid = node("div", "detail-grid");
  grid.append(detailCell("Risk", riskLabel(card.risk)));
  grid.append(detailCell("Risk rationale", card.risk.rationale || "Firstmate has not assessed this task yet."));
  grid.append(detailCell("Repository", card.repo));
  grid.append(detailCell("Work type", card.kind));
  grid.append(detailCell("Task", card.id));
  grid.append(detailCell("Status source", card.status.source));

  const context = node("section", "detail-section");
  context.append(node("span", "detail-label", "Context"));
  context.append(node("p", "detail-value", card.context || "No additional task context is recorded."));

  const decisions = decisionsSection(card);
  elements.dialogBody.replaceChildren(
    lead,
    grid,
    ...(decisions ? [decisions] : []),
    context,
    evidenceSection(card)
  );
  renderDialogActions(card);
  const draft = state.drafts.get(card.key);
  if (draft && !draft.submitted && draftIsAvailable(draft, card)) {
    renderComposer(card, draft, false);
  }
  elements.dialog.dataset.renderFingerprint = renderFingerprint;
  if (!wasOpen) {
    elements.dialog.showModal();
  } else {
    focusByKey(focusKey, elements.dialogClose);
  }
}

function renderDialogActions(card) {
  elements.dialogActions.hidden = false;
  elements.dialogActions.replaceChildren();
  if (!card.actions.request_details && !card.actions.answer) return;
  const pending = state.pending.has(card.key);
  if (card.actions.request_details) {
    const details = node("button", "action-button secondary", "Request more details");
    details.type = "button";
    details.dataset.focusKey = "dialog:request-details";
    details.disabled = pending;
    details.addEventListener("click", () => showComposer(card, "request_details"));
    elements.dialogActions.append(details);
  }
  if (card.actions.answer) {
    const answer = node("button", "action-button captain", "Answer Firstmate");
    answer.type = "button";
    answer.dataset.focusKey = "dialog:answer";
    answer.disabled = pending;
    answer.addEventListener("click", () => showComposer(card, "answer"));
    elements.dialogActions.append(answer);
  }
}

function showComposer(card, action) {
  let draft = state.drafts.get(card.key);
  if (!draft || draft.action !== action) {
    draft = {
      action,
      text: action === "request_details"
        ? "Please summarize the current status, remaining risk, evidence, and the exact decision you need from me."
        : "",
      decisionKey: action === "answer" ? card.decisions[0]?.key || null : null,
      requestId: null,
      attempted: false,
      inFlight: false,
      saved: false,
    };
    state.drafts.set(card.key, draft);
  }
  renderComposer(card, draft, true);
}

function renderComposer(card, draft, focus) {
  document.querySelector(".action-composer")?.remove();
  elements.dialogActions.hidden = true;
  const action = draft.action;
  const composer = node("form", "action-composer");
  const id = `action-${crypto.randomUUID()}`;
  const label = node("label", "", action === "answer" ? "Your answer" : "What should Firstmate clarify?");
  label.htmlFor = id;
  const textarea = node("textarea");
  textarea.id = id;
  textarea.name = "text";
  textarea.required = true;
  textarea.dataset.focusKey = "dialog:composer-text";
  textarea.placeholder = action === "answer"
    ? "Give Firstmate the decision and any constraints that matter."
    : "Please summarize the current status, remaining risk, evidence, and the exact decision you need from me.";
  textarea.value = draft.text;
  textarea.disabled = draft.attempted;
  textarea.addEventListener("input", () => {
    draft.text = textarea.value;
    if (!actionTextError(draft.text, state.maxActionBytes)) textarea.setCustomValidity("");
  });
  if (action === "answer") {
    const choices = node("fieldset", "decision-choices");
    choices.append(node("legend", "", "Decision to answer"));
    for (const [index, decision] of card.decisions.entries()) {
      const choice = node("label", "decision-choice");
      const input = node("input");
      input.type = "radio";
      input.name = "decision_key";
      input.value = decision.key;
      input.required = true;
      input.checked = decision.key === draft.decisionKey || (!draft.decisionKey && index === 0);
      input.disabled = draft.attempted;
      input.dataset.focusKey = `dialog:decision:${decision.key}`;
      input.addEventListener("change", () => {
        if (input.checked) draft.decisionKey = decision.key;
      });
      choice.append(input, node("span", "", decision.summary));
      choices.append(choice);
    }
    composer.append(choices);
  }
  const footer = node("div", "composer-footer");
  footer.append(node("p", "composer-note", "This queues a durable instruction. The status changes only after Firstmate handles it."));
  if (!draft.attempted) {
    const cancel = node("button", "action-button secondary", "Cancel");
    cancel.type = "button";
    cancel.dataset.focusKey = "dialog:composer-cancel";
    cancel.addEventListener("click", () => {
      state.drafts.delete(card.key);
      openCard(card.key);
    });
    footer.append(cancel);
  }
  const submitLabel = draft.inFlight
    ? "Sending…"
    : draft.saved
      ? "Retry Firstmate wake"
      : draft.attempted
        ? "Retry send"
        : action === "answer"
          ? "Send answer"
          : "Send request";
  const submit = node("button", `action-button ${action === "answer" ? "captain" : ""}`, submitLabel);
  submit.type = "submit";
  submit.disabled = draft.inFlight;
  submit.dataset.focusKey = "dialog:composer-submit";
  footer.append(submit);
  composer.append(label, textarea, footer);
  composer.addEventListener("submit", async (event) => {
    event.preventDefault();
    draft.text = normalizeActionText(textarea.value);
    textarea.value = draft.text;
    if (action === "answer") {
      const selectedDecision = new FormData(composer).get("decision_key");
      if (selectedDecision) draft.decisionKey = selectedDecision;
    }
    const validationError = actionTextError(draft.text, state.maxActionBytes);
    if (validationError) {
      textarea.setCustomValidity(validationError);
      textarea.reportValidity();
      return;
    }
    const submissionFingerprint = cardFingerprint(card);
    const operation = beginAction(state.drafts, card.key, () => crypto.randomUUID());
    if (!persistActionOperations()) {
      operation.requestId = null;
      operation.attempted = false;
      operation.inFlight = false;
      renderComposer(card, operation, false);
      showToast("Browser storage is unavailable, so the instruction was not sent.", "error");
      return;
    }
    renderComposer(card, operation, false);
    try {
      const result = await sendAction(
        card,
        operation.action,
        operation.text,
        operation.requestId,
        operation.decisionKey
      );
      state.board = applyActionObservation(state.board, result);
      if (result.observation === "stale-last-good") {
        renderWarnings();
        setFreshness("stale", `Last good snapshot ${relativeTime(state.board.generated)}`);
      }
      if (result.wake === "failed") {
        operation.inFlight = false;
        operation.saved = true;
        persistActionOperations();
        if (state.selectedKey === card.key && elements.dialog.open) openCard(card.key);
        showToast("Instruction saved, but Firstmate was not woken. Retry is safe.", "error");
        return;
      }
      const currentCard = state.board.cards.find((item) => item.key === card.key);
      recordAcceptedAction(
        state.drafts,
        state.pending,
        card.key,
        submissionFingerprint,
        currentCard,
        result.wake === "handled"
      );
      persistActionOperations();
      showToast(action === "answer" ? "Answer sent to Firstmate." : "Detail request sent to Firstmate.");
      renderBoard();
      if (state.selectedKey === card.key && elements.dialog.open) openCard(card.key);
    } catch (error) {
      operation.inFlight = false;
      persistActionOperations();
      if (state.drafts.get(card.key) === operation && state.selectedKey === card.key && elements.dialog.open) {
        openCard(card.key);
      }
      showToast(error.message || "The action could not be sent.", "error");
    }
  });
  elements.dialogBody.append(composer);
  elements.dialog.dataset.renderFingerprint = dialogFingerprint(card);
  if (focus) textarea.focus();
}

async function sendAction(card, action, text, requestId, decisionKey) {
  const response = await fetch("/api/v1/actions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Firstmate-CSRF": state.csrf,
    },
    body: JSON.stringify({
      action,
      task_id: card.id,
      home_namespace: card.home.namespace,
      home_id: card.home.id,
      text,
      request_id: requestId,
      ...(decisionKey ? { decision_key: decisionKey } : {}),
    }),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || `Firstmate returned ${response.status}`);
  return payload;
}

async function clearAcknowledgedActions() {
  const requestIds = submittedRequestIds(state.drafts);
  if (!requestIds.length) return false;
  try {
    const response = await fetch("/api/v1/action-status", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Firstmate-CSRF": state.csrf,
      },
      body: JSON.stringify({ request_ids: requestIds }),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || payload.schema !== "fm-fleet-board-action-status.v1") return false;
    return clearHandledActionOperations(state.pending, state.drafts, payload.statuses);
  } catch {
    return false;
  }
}

function showToast(message, kind = "success") {
  document.querySelector(".toast")?.remove();
  const toast = node("div", "toast", message);
  toast.dataset.kind = kind;
  toast.setAttribute("role", kind === "error" ? "alert" : "status");
  document.body.append(toast);
  window.setTimeout(() => toast.remove(), 4500);
}

function setFreshness(status, label) {
  if (updateLiveStatus(elements.freshnessDot.dataset, elements.freshnessLabel, status, label)) {
    updateValue(elements.freshnessAnnouncement, "textContent", label);
  }
}

async function loadBoard(force = false) {
  if (state.loading) return;
  const hadBoard = Boolean(state.board);
  state.loading = true;
  elements.refresh.disabled = true;
  if (force) setFreshness("loading", "Reading the fleet…");
  try {
    const response = await fetch(`/api/v1/board${force ? "?refresh=1" : ""}`, { cache: "no-store" });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(payload.error || `Firstmate returned ${response.status}`);
    configureActionStorage(payload.actions.operation_scope, payload.actions.max_text_bytes);
    state.board = payload;
    state.csrf = payload.actions.csrf_token;
    await clearAcknowledgedActions();
    const previousSelectedKey = state.selectedKey;
    const reconciled = reconcileBoardState(
      state.pending,
      state.drafts,
      state.selectedKey,
      payload.cards
    );
    persistActionOperations();
    state.selectedKey = reconciled.selectedKey;
    updateHomeFilter();
    renderSummary();
    renderWarnings();
    renderBoard();
    if (previousSelectedKey && !reconciled.selectedCard && elements.dialog.open) {
      elements.dialog.close();
    } else if (reconciled.selectedCard && elements.dialog.open) {
      openCard(reconciled.selectedCard.key);
    }
    if (payload.health.stale) {
      setFreshness("stale", `Last good snapshot ${relativeTime(payload.generated)}`);
    } else {
      setFreshness("fresh", `Updated ${relativeTime(payload.generated)}`);
    }
  } catch (error) {
    setFreshness("error", error.message || "Fleet unavailable");
    if (shouldAnnounceLoadFailure(state.loadFailures, force, hadBoard)) {
      showToast(error.message || "The fleet could not be loaded.", "error");
    }
  } finally {
    state.loading = false;
    elements.refresh.disabled = false;
  }
}

elements.search.addEventListener("input", renderBoard);
elements.homeFilter.addEventListener("change", renderBoard);
elements.riskFilter.addEventListener("change", renderBoard);
elements.refresh.addEventListener("click", () => loadBoard(true));
elements.dialogClose.addEventListener("click", () => elements.dialog.close());
elements.dialog.addEventListener("close", () => {
  const openerKey = state.dialogOpenerKey;
  state.selectedKey = null;
  state.dialogOpenerKey = null;
  queueMicrotask(() => focusByKey(`card:${openerKey}`));
});
elements.dialog.addEventListener("click", (event) => {
  if (event.target === elements.dialog) elements.dialog.close();
});
elements.needsYouSignal.addEventListener("click", () => {
  document.querySelector('[data-lane="needs_you"]')?.scrollIntoView({ behavior: "smooth", block: "nearest", inline: "center" });
});
window.addEventListener("storage", (event) => {
  if (!state.operationStorageKey || event.key !== state.operationStorageKey) return;
  if (event.storageArea && event.storageArea !== localStorage) return;
  state.drafts = syncStoredActionOperations(state.drafts, event.newValue, state.maxActionBytes);
  state.pending.clear();
  if (!state.board) return;
  const reconciled = reconcileBoardState(
    state.pending,
    state.drafts,
    state.selectedKey,
    state.board.cards
  );
  state.selectedKey = reconciled.selectedKey;
  renderBoard();
  if (reconciled.selectedCard && elements.dialog.open) openCard(reconciled.selectedCard.key);
});

loadBoard();
window.setInterval(() => {
  if (!document.hidden) loadBoard();
}, 10000);
