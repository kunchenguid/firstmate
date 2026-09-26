const $ = id => document.getElementById(id);
let csrf = "", replyCursor = "", replies = new Map(), notes = [], readiness = null;
let polling = false;
const DRAFT_KEY = "firstmate-console-draft";
const RETRY_KEY = "firstmate-console-retry";

function node(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
}
function replace(id, children) { $(id).replaceChildren(...children); }
function empty(text) { return node("p", "empty", text); }
function stamp(value) {
  if (!value) return "Unknown time";
  const time = new Date(value);
  return Number.isNaN(time.getTime()) ? "Unknown time" : time.toLocaleString();
}
function stateText(note) {
  if (note.replied) return "Replied";
  if (note.acknowledged) return "Acknowledged";
  if (note.announced === true) return "Announced · awaiting acknowledgement";
  if (note.announced === false) return "Saved · announcement pending";
  return "Saved · announcement unknown";
}
function list(id, countId, items, render, emptyLabel) {
  $(countId).textContent = String(items.length);
  replace(id, items.length ? items.map(render) : [empty(emptyLabel)]);
}
function fleetItem(item, label, detail) {
  const wrap = node("article", "item");
  const top = node("div", "item-top");
  top.append(node("div", "item-title", label), node("span", "state", item.state || item.owner || "Open"));
  wrap.append(top, node("div", "item-meta", [item.id, item.repo].filter(Boolean).join(" · ")));
  if (detail) wrap.append(node("p", "item-detail", detail));
  if (item.url) { const link = node("a", "item-detail", "Open change ↗"); link.href = item.url; link.rel = "noopener noreferrer"; link.target = "_blank"; wrap.append(link); }
  return wrap;
}
function renderFleet(result) {
  const view = result.snapshot;
  $("observation").textContent = view ? `Observed ${stamp(result.observed_at)}${result.collecting ? " · refreshing" : ""}` : "No observation yet";
  const alert = $("fleet-alert");
  const age = result.observed_at ? Date.now() - new Date(result.observed_at).getTime() : Infinity;
  alert.hidden = !result.error && age <= 30000;
  alert.textContent = result.error || `Last observation is ${Math.max(0, Math.floor(age / 1000))} seconds old. This is a cached view.`;
  if (!view) return;
  list("in-flight", "flight-count", view.in_flight, x => fleetItem(x, x.name || x.id, x.doing), "No work shown in this bounded view.");
  list("decisions", "decision-count", view.decisions, x => fleetItem(x, x.summary || x.id, "The decision remains open until Firstmate records its answer."), "No decisions shown.");
  list("gates", "gate-count", view.gates, x => fleetItem(x, x.title || x.id, x.reason), "No gates shown.");
  list("landed", "landed-count", view.landed, x => fleetItem(x, x.what || x.id, ""), "No recent results shown.");
  list("secondmates", "mate-count", view.secondmates, x => fleetItem(x, x.id, [x.doing, x.freshness, x.reason].filter(Boolean).join(" · ")), "No other homes shown.");
  $("omissions").hidden = !view.omitted.length;
  replace("omission-list", view.omitted.map(text => node("li", "", text)));
}
function renderReady(ready) {
  readiness = ready;
  let text;
  if (ready.can_receive === true) text = "Primary appears able to receive work";
  else if (ready.can_receive === false) text = "Primary cannot receive work now · orders remain pending";
  else text = "Primary readiness unknown · orders may remain pending";
  $("readiness").textContent = text;
  $("order-readiness").textContent = `${text}. Observed ${stamp(ready.observed_at)}. Lock: ${ready.lock || "unknown"}; wake consumer: ${ready.wake_consumer || "unknown"}; posture: ${ready.posture || "unknown"}.`;
}
async function viewArtifact(id, line, target) {
  target.hidden = false;
  target.textContent = "Loading source…";
  try {
    const view = await api(`/artifact/${encodeURIComponent(id)}${line ? `?line=${line}` : ""}`);
    const where = view.line ? `${view.file}:${view.line}` : view.file;
    target.textContent = `${where}\n\n${view.content}${view.truncated ? "\n…(truncated)" : ""}`;
  } catch (error) {
    target.textContent = `Could not load source: ${error.message}`;
  }
}
function excerptBlock(excerpt) {
  const wrap = node("div", "excerpt");
  const head = node("div", "excerpt-head");
  head.append(node("span", "excerpt-label", "Related from memory"), node("span", "excerpt-source", `${excerpt.file}:${excerpt.line}`));
  const view = node("pre", "excerpt-source-view");
  view.hidden = true;
  const button = node("button", "excerpt-view", "View source");
  button.type = "button";
  button.addEventListener("click", () => {
    if (!view.hidden) { view.hidden = true; return; }
    viewArtifact(excerpt.artifact, excerpt.line, view);
  });
  wrap.append(head, node("p", "excerpt-body", excerpt.excerpt), button, view);
  return wrap;
}
function message(title, body, when, foot, answer = false, excerpt = null) {
  const wrap = node("article", answer ? "message answer" : "message");
  wrap.dataset.at = when || "";
  const head = node("div", "message-head");
  head.append(node("strong", "", title), node("span", "", stamp(when)));
  wrap.append(head, node("p", "message-body", body), node("div", "message-foot", foot));
  if (excerpt) wrap.append(excerptBlock(excerpt));
  return wrap;
}
function renderCuration() {
  const total = replies.size;
  const status = $("curation-status");
  if (!total) { status.hidden = true; return; }
  const uncurated = [...replies.values()].filter(reply => !reply.curated).length;
  status.hidden = false;
  status.textContent = uncurated
    ? `${uncurated} of ${total} durable answers are not yet folded into curated memory.`
    : `All ${total} durable answers are folded into curated memory.`;
}
function renderConversation(omissions = []) {
  const output = [];
  const ordered = [...notes].sort((a, b) => (a.at || "").localeCompare(b.at || ""));
  for (const note of ordered) output.push(message("Order", note.body, note.at, `${stateText(note)} · ${note.id}`));
  for (const reply of replies.values()) output.push(message("Firstmate answer", reply.body, reply.at, `Reply to ${reply.id} · cursor ${reply.cursor}`, true, reply.excerpt));
  output.sort((a, b) => a.dataset.at.localeCompare(b.dataset.at));
  replace("conversation", output.length ? output : [empty("No durable orders or answers shown yet.")]);
  $("receipt-omissions").hidden = !omissions.length;
  replace("receipt-omission-list", omissions.map(text => node("li", "", text)));
  renderCuration();
}
async function api(path, options) {
  const response = await fetch(path, {cache: "no-store", ...options});
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "Request failed");
  return data;
}
async function refresh() {
  if (polling || document.hidden) return;
  polling = true;
  let waitingOnFirstObservation = false;
  try {
    const [fleet, ready] = await Promise.all([api("/api/fleet"), api("/api/ready")]);
    waitingOnFirstObservation = fleet.collecting && !fleet.snapshot;
    renderFleet(fleet);
    renderReady(ready);
    const omissions = new Set();
    for (let page = 0; page < 100; page++) {
      const result = await api(`/api/receipts?after=${encodeURIComponent(replyCursor)}`);
      notes = [...result.pending, ...result.handled];
      result.replies.forEach(reply => replies.set(reply.cursor, reply));
      result.omitted.forEach(text => omissions.add(text));
      $("receipt-observation").textContent = `Observed ${stamp(result.observed_at)}`;
      const next = result.reply_cursor;
      if (next && next !== replyCursor) replyCursor = next;
      if (!result.omitted.some(text => text.startsWith("replies omitted by bound")) || !result.replies.length) break;
      if (page === 99) omissions.add("Reply history is longer than this browser load. Refresh to inspect the latest bounded view.");
    }
    renderConversation([...omissions]);
  } catch (error) {
    $("fleet-alert").hidden = false;
    $("fleet-alert").textContent = error.message;
    $("order-readiness").textContent = "Readiness unknown while the console cannot read the owner projection.";
  } finally {
    polling = false;
    if (waitingOnFirstObservation) setTimeout(refresh, 1000);
  }
}
function selectLane(lane) {
  for (const id of ["fleet", "ask", "work"]) $(id).hidden = id !== lane;
  document.querySelectorAll(".lane").forEach(button => {
    const selected = button.dataset.lane === lane;
    button.classList.toggle("selected", selected);
    button.setAttribute("aria-pressed", String(selected));
  });
}
async function submitOrder(event) {
  event.preventDefault();
  const text = $("draft").value;
  if (!text.trim()) return;
  let pending;
  try { pending = JSON.parse(localStorage.getItem(RETRY_KEY) || "null"); } catch { pending = null; }
  if (!pending || pending.text !== text) pending = {request_id: crypto.randomUUID(), text};
  localStorage.setItem(RETRY_KEY, JSON.stringify(pending));
  $("send-order").disabled = true;
  const resultBox = $("order-result");
  resultBox.hidden = false;
  resultBox.textContent = "Saving order…";
  try {
    const result = await api("/api/order", {method: "POST", headers: {"Content-Type": "application/json", "X-Console-CSRF": csrf}, body: JSON.stringify(pending)});
    resultBox.textContent = `${result.outcome === "replay" ? "Original order found" : "Order saved"} · ${result.id}. ${result.pending ? "Pending: receipt does not prove delivery to a primary." : "Announced: awaiting primary acknowledgement."}`;
    if (result.announced || result.acknowledged) { localStorage.removeItem(RETRY_KEY); $("draft").value = ""; localStorage.removeItem(DRAFT_KEY); }
    await refresh();
  } catch (error) { resultBox.textContent = `${error.message}. Your draft and request ID are retained for retry.`; }
  finally { $("send-order").disabled = false; }
}
async function start() {
  try { csrf = (await api("/api/session")).csrf; }
  catch (error) { $("fleet-alert").hidden = false; $("fleet-alert").textContent = error.message; return; }
  let retry;
  try { retry = JSON.parse(localStorage.getItem(RETRY_KEY) || "null"); } catch { retry = null; }
  $("draft").value = retry?.text || localStorage.getItem(DRAFT_KEY) || "";
  if (retry) { $("order-result").hidden = false; $("order-result").textContent = "A previous order has an uncertain receipt. Submit the same draft to retry its original request ID."; }
  $("draft").addEventListener("input", () => localStorage.setItem(DRAFT_KEY, $("draft").value));
  $("order-form").addEventListener("submit", submitOrder);
  document.querySelectorAll(".lane").forEach(button => button.addEventListener("click", () => selectLane(button.dataset.lane)));
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
  await refresh();
  setInterval(refresh, 15000);
}
start();
