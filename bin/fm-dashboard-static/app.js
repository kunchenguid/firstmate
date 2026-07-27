/* Live fleet dashboard UI - wave 1 shell.
 * Polls GET /api/v1/snapshot every 5s. Patches the DOM; does not rebuild the page.
 * No CDN. Offline on the tailnet.
 *
 * Wave 3 lavish-style feedback (tick / dismiss / snooze / free-text annotation)
 * anchors on stable data-key attributes present on EVERY section and card/row.
 * Wave 1 is read-only; keys are architectural only.
 *
 * Key convention:
 *   section:<slug> | decision:<hold-id> | task:<id> | event:<id>
 *   | pr:<id> | train:<id> | meter:<id> | production:<id> | empty:<section>
 */
(function () {
  "use strict";

  var POLL_MS = 5000;
  var state = {
    lastOkAt: null,
    lastGenerated: null,
    failStreak: 0,
    cardNodes: Object.create(null), // key -> element for patch reuse
  };

  var el = {
    beatDot: document.getElementById("beat-dot"),
    beatText: document.getElementById("beat-text"),
    homeLine: document.getElementById("home-line"),
    sinceMeta: document.getElementById("since-meta"),
    sinceBody: document.getElementById("since-body"),
    callMeta: document.getElementById("call-meta"),
    callBody: document.getElementById("call-body"),
    readyMeta: document.getElementById("ready-meta"),
    readyBody: document.getElementById("ready-body"),
    fleetMeta: document.getElementById("fleet-meta"),
    fleetBody: document.getElementById("fleet-body"),
    trainsMeta: document.getElementById("trains-meta"),
    trainsBody: document.getElementById("trains-body"),
    metersMeta: document.getElementById("meters-meta"),
    metersBody: document.getElementById("meters-body"),
    prodMeta: document.getElementById("prod-meta"),
    prodBody: document.getElementById("prod-body"),
  };

  /** Assign stable data-key (and kind) for wave 3 annotation anchoring. */
  function setKey(node, key, kind) {
    if (!node || !key) return node;
    node.setAttribute("data-key", key);
    node.dataset.key = key;
    if (kind) {
      node.setAttribute("data-key-kind", kind);
      node.dataset.keyKind = kind;
    }
    // Wave 3 actions attach here without rework.
    node.setAttribute("data-annotatable", "1");
    return node;
  }

  function emptyState(sectionSlug, label, detail) {
    var d = document.createElement("div");
    d.className = "empty";
    setKey(d, "empty:" + sectionSlug, "empty");
    var tag = document.createElement("span");
    tag.className = "tag";
    tag.textContent = label;
    d.appendChild(tag);
    d.appendChild(document.createTextNode(detail));
    return d;
  }

  function setBeat(level, text) {
    el.beatDot.className = "dot " + level;
    el.beatText.textContent = text;
  }

  function formatLocal(iso) {
    if (!iso) return "";
    var d = new Date(iso);
    if (isNaN(d.getTime())) return iso;
    try {
      return d.toLocaleString(undefined, {
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hour12: false,
      }) + " " + (d.toLocaleDateString(undefined, { month: "short", day: "numeric" }));
    } catch (e) {
      return iso;
    }
  }

  function ageSeconds(iso) {
    if (!iso) return null;
    var t = Date.parse(iso);
    if (isNaN(t)) return null;
    return Math.max(0, Math.round((Date.now() - t) / 1000));
  }

  function sourceMap(sources) {
    var m = Object.create(null);
    if (!Array.isArray(sources)) return m;
    for (var i = 0; i < sources.length; i++) {
      var s = sources[i];
      if (s && s.id) m[s.id] = s;
    }
    return m;
  }

  function updateBeatFromSnap(snap, pollOk) {
    if (!pollOk) {
      setBeat("red", "server unreachable · last ok " + (state.lastOkAt ? formatLocal(state.lastOkAt) : "never"));
      return;
    }
    var sources = sourceMap(snap.sources);
    var fleet = sources["fleet-snapshot"] || sources["fleet-compose-fallback"];
    var gen = snap.generated || (snap.fleet && snap.fleet.generated) || null;
    var age = ageSeconds(gen);
    var parts = [];
    if (age !== null) parts.push("snapshot " + age + "s");
    else if (gen) parts.push("snapshot @ " + gen);
    else parts.push("snapshot age unknown");
    if (gen) parts.push(formatLocal(gen));

    var level = "ok";
    if (!fleet || fleet.ok === false) level = "amber";
    if (age !== null && age > 15) level = level === "ok" ? "amber" : level;
    if (state.failStreak > 0) level = "red";

    var cls = level === "ok" ? "" : level;
    setBeat(cls, parts.join(" · "));
  }

  /** Ensure card for key exists under parent; reuses node when possible. */
  function acquireCard(parent, key, kind, className) {
    var card = state.cardNodes[key];
    if (!card) {
      card = document.createElement("div");
      card.className = className || "card";
      setKey(card, key, kind);
      state.cardNodes[key] = card;
    } else {
      setKey(card, key, kind);
      if (className) card.className = className;
    }
    if (card.parentNode !== parent) parent.appendChild(card);
    return card;
  }

  function pruneCards(liveKeys) {
    Object.keys(state.cardNodes).forEach(function (key) {
      if (!liveKeys[key]) {
        var node = state.cardNodes[key];
        if (node && node.parentNode) node.parentNode.removeChild(node);
        delete state.cardNodes[key];
      }
    });
  }

  function entityKey(prefix, id) {
    return prefix + ":" + String(id || "unknown");
  }

  function renderSince(snap) {
    var events = snap.events;
    el.sinceMeta.textContent = "";
    el.sinceBody.textContent = "";
    if (events == null) {
      el.sinceBody.appendChild(
        emptyState("since-you-looked", "wired in wave 2", "Delta strip needs event cursor + side sources.")
      );
      return;
    }
    if (!Array.isArray(events) || events.length === 0) {
      el.sinceBody.appendChild(
        emptyState("since-you-looked", "clear", "Nothing new since you last looked.")
      );
      return;
    }
    var wrap = document.createElement("div");
    wrap.className = "delta";
    setKey(wrap, "surface:since-list", "surface");
    var max = Math.min(events.length, 7);
    for (var i = 0; i < max; i++) {
      var ev = events[i] || {};
      var ek =
        ev.key ||
        entityKey("event", ev.id || ev.ts || ev.at || i);
      var row = document.createElement("div");
      row.className = "row";
      setKey(row, ek, "event");
      var t = document.createElement("span");
      t.className = "t";
      t.textContent = ev.t || ev.at || "";
      var msg = document.createElement("span");
      if (ev.level === "good") msg.className = "good";
      if (ev.level === "warn") msg.className = "warn";
      msg.textContent = ev.text || ev.message || "";
      row.appendChild(t);
      row.appendChild(msg);
      wrap.appendChild(row);
    }
    el.sinceBody.appendChild(wrap);
  }

  function decisionChip(d) {
    var kind = (d.hold_kind || "decision").toString();
    var span = document.createElement("span");
    span.className = "chip brass";
    span.textContent = kind;
    return span;
  }

  function renderDecisions(snap) {
    var list = Array.isArray(snap.decisions) ? snap.decisions : [];
    el.callBody.textContent = "";
    var shown = list.length;
    el.callMeta.textContent = shown ? shown + " open" : "none open";
    var live = Object.create(null);
    if (!shown) {
      el.callBody.appendChild(
        emptyState("your-call", "clear", "No captain-actionable decisions in the current snapshot.")
      );
      return;
    }

    for (var i = 0; i < list.length; i++) {
      var d = list[i];
      if (!d) continue;
      var rawKey = d.key || d.id;
      if (!rawKey) continue;
      var key = String(rawKey).indexOf("decision:") === 0 ? String(rawKey) : entityKey("decision", rawKey);
      // Raw backlog hold id (never the decision: prefixed board key) for
      // hold-id based write-back in wave 3.
      var holdId = d.hold_id || String(rawKey).replace(/^decision:/, "");
      live[key] = true;
      var card = acquireCard(el.callBody, key, "decision", "card");
      card.setAttribute("data-decision-key", holdId);
      card.dataset.decisionKey = holdId;

      card.textContent = "";
      card.appendChild(decisionChip(d));
      var k = document.createElement("div");
      k.className = "k";
      k.textContent = d.title || rawKey;
      card.appendChild(k);
      var v = document.createElement("div");
      v.className = "v";
      var body = d.body || d.hold_reason || "";
      if (d.recommendation) {
        body = (body ? body + " " : "") + "Rec: " + d.recommendation;
      }
      v.textContent = body || "Awaiting your call.";
      card.appendChild(v);
      var act = document.createElement("div");
      act.className = "act";
      // Wave 3 wires write-back. Buttons carry the same stable key.
      ["Answer", "Dismiss", "Snooze"].forEach(function (label) {
        var b = document.createElement("button");
        b.type = "button";
        b.className = label === "Answer" ? "btn primary" : label === "Snooze" ? "btn ghost" : "btn";
        b.textContent = label;
        b.disabled = true;
        b.title = "Write-back lands in wave 3";
        b.dataset.key = key;
        b.dataset.decisionKey = holdId;
        b.dataset.action = label.toLowerCase();
        act.appendChild(b);
      });
      card.appendChild(act);
      var origin = document.createElement("div");
      origin.className = "v";
      origin.style.marginTop = "6px";
      origin.style.fontFamily = "var(--mono)";
      origin.style.fontSize = "11px";
      origin.textContent = "key: " + key;
      card.appendChild(origin);
    }
    // Only prune decision cards that disappeared (keep other kinds).
    Object.keys(state.cardNodes).forEach(function (k) {
      if (k.indexOf("decision:") === 0 && !live[k]) {
        var node = state.cardNodes[k];
        if (node && node.parentNode) node.parentNode.removeChild(node);
        delete state.cardNodes[k];
      }
    });
  }

  function renderReady(snap) {
    el.readyBody.textContent = "";
    var prs = snap.open_prs;
    if (!Array.isArray(prs)) {
      el.readyMeta.textContent = "";
      el.readyBody.appendChild(
        emptyState("ready-for-you", "wired in wave 2", "Open PR stack comes from gh-axi per project.")
      );
      return;
    }
    el.readyMeta.textContent = prs.length + " open";
    if (!prs.length) {
      el.readyBody.appendChild(
        emptyState("ready-for-you", "clear", "Nothing waiting in the open PR list.")
      );
      return;
    }
    var cards = document.createElement("div");
    cards.className = "cards";
    setKey(cards, "surface:ready-list", "surface");
    prs.forEach(function (pr, idx) {
      var id = pr.key || pr.number || pr.id || pr.url || idx;
      var key = String(id).indexOf("pr:") === 0 ? String(id) : entityKey("pr", id);
      var c = document.createElement("div");
      c.className = "card";
      setKey(c, key, "pr");
      var k = document.createElement("div");
      k.className = "k";
      k.textContent = pr.title || pr.url || "PR";
      c.appendChild(k);
      var v = document.createElement("div");
      v.className = "v";
      if (pr.url) {
        var a = document.createElement("a");
        a.href = pr.url;
        a.textContent = pr.url;
        a.rel = "noopener";
        a.style.color = "var(--teal)";
        v.appendChild(a);
      }
      c.appendChild(v);
      cards.appendChild(c);
    });
    el.readyBody.appendChild(cards);
  }

  function stateChip(st) {
    var span = document.createElement("span");
    var s = (st || "unknown").toLowerCase();
    var cls = "info";
    if (s === "working" || s === "running") cls = "ok";
    else if (s === "failed" || s === "blocked") cls = "bad";
    else if (s === "paused" || s === "needs-decision") cls = "warn";
    span.className = "chip " + cls;
    span.textContent = st || "unknown";
    return span;
  }

  function renderFleet(snap) {
    var fleet = snap.fleet || {};
    var tasks = Array.isArray(fleet.tasks) ? fleet.tasks : [];
    el.fleetMeta.textContent = tasks.length ? tasks.length + " live" : "idle";
    el.fleetBody.textContent = "";
    var live = Object.create(null);
    if (!tasks.length) {
      el.fleetBody.appendChild(
        emptyState("fleet-now", "clear", "No live task metadata under state/.")
      );
      return;
    }
    tasks.forEach(function (t) {
      var id = t.id || "?";
      var key = t.key && String(t.key).indexOf("task:") === 0
        ? String(t.key)
        : entityKey("task", id);
      live[key] = true;
      var card = acquireCard(el.fleetBody, key, "task", "card");
      card.dataset.taskId = id;
      card.setAttribute("data-task-id", id);

      card.textContent = "";
      var cs = (t.current_state && t.current_state.state) || "unknown";
      card.appendChild(stateChip(cs));
      var k = document.createElement("div");
      k.className = "k";
      k.textContent = id;
      card.appendChild(k);
      var v = document.createElement("div");
      v.className = "v";
      var detail =
        (t.hints && t.hints.last_event_text) ||
        (t.current_state && (t.current_state.detail || t.current_state.raw)) ||
        "";
      var kind = t.kind ? t.kind + " · " : "";
      v.textContent = kind + (detail || "no recent event");
      card.appendChild(v);
      if (t.pr && t.pr.url) {
        var link = document.createElement("div");
        link.className = "v";
        var a = document.createElement("a");
        a.href = t.pr.url;
        a.textContent = t.pr.url;
        a.rel = "noopener";
        a.style.color = "var(--teal)";
        link.appendChild(a);
        card.appendChild(link);
      }
    });
    Object.keys(state.cardNodes).forEach(function (k) {
      if (k.indexOf("task:") === 0 && !live[k]) {
        var node = state.cardNodes[k];
        if (node && node.parentNode) node.parentNode.removeChild(node);
        delete state.cardNodes[k];
      }
    });
  }

  function renderTrains(snap) {
    el.trainsBody.textContent = "";
    if (snap.trains == null) {
      el.trainsMeta.textContent = "";
      el.trainsBody.appendChild(
        emptyState("trains", "wired in wave 2", "Trains file + UI land with D6.")
      );
      return;
    }
    el.trainsMeta.textContent = "loaded";
    // Wave 2+ populates train rows; each must use train:<id> data-key.
    var list = Array.isArray(snap.trains)
      ? snap.trains
      : snap.trains.trains || [];
    if (Array.isArray(list)) {
      list.forEach(function (tr, idx) {
        var id = tr.id || tr.key || idx;
        var key = String(id).indexOf("train:") === 0 ? String(id) : entityKey("train", id);
        var row = document.createElement("div");
        row.className = "row";
        setKey(row, key, "train");
        var left = document.createElement("span");
        left.innerHTML = "<b></b>";
        left.querySelector("b").textContent = tr.title || tr.id || key;
        row.appendChild(left);
        el.trainsBody.appendChild(row);
      });
    }
  }

  function renderMeters(snap) {
    el.metersBody.textContent = "";
    if (snap.quota == null) {
      el.metersMeta.textContent = "";
      el.metersBody.appendChild(
        emptyState("meters", "wired in wave 2", "Quota meters come from quota-axi (D3).")
      );
      return;
    }
    el.metersMeta.textContent = "live";
    // When quota object has providers, each meter gets meter:<id>.
    var providers = snap.quota.providers || snap.quota.meters || null;
    if (Array.isArray(providers)) {
      providers.forEach(function (m, idx) {
        var id = m.id || m.name || idx;
        var key = String(id).indexOf("meter:") === 0 ? String(id) : entityKey("meter", id);
        var meter = document.createElement("div");
        meter.className = "meter";
        setKey(meter, key, "meter");
        var lbl = document.createElement("div");
        lbl.className = "lbl";
        lbl.textContent = m.label || m.name || id;
        meter.appendChild(lbl);
        el.metersBody.appendChild(meter);
      });
    } else if (typeof snap.quota === "object") {
      Object.keys(snap.quota).forEach(function (name) {
        if (name === "providers" || name === "meters") return;
        var key = entityKey("meter", name);
        var meter = document.createElement("div");
        meter.className = "meter";
        setKey(meter, key, "meter");
        var lbl = document.createElement("div");
        lbl.className = "lbl";
        lbl.textContent = name;
        meter.appendChild(lbl);
        el.metersBody.appendChild(meter);
      });
    }
  }

  function renderProduction(snap) {
    el.prodBody.textContent = "";
    if (snap.production == null) {
      el.prodMeta.textContent = "";
      el.prodBody.appendChild(
        emptyState("production", "wired in wave 2", "Production probe + marker land with D7.")
      );
      return;
    }
    el.prodMeta.textContent = "live";
    setKey(el.prodBody, "production:status", "production");
  }

  function applySnapshot(snap) {
    el.homeLine.textContent =
      (snap.fm_home || "") +
      (snap.server && snap.server.uptime_s != null
        ? " · up " + snap.server.uptime_s + "s"
        : "");
    updateBeatFromSnap(snap, true);
    renderSince(snap);
    renderDecisions(snap);
    renderReady(snap);
    renderFleet(snap);
    renderTrains(snap);
    renderMeters(snap);
    renderProduction(snap);
  }

  function poll() {
    var ctrl = typeof AbortController !== "undefined" ? new AbortController() : null;
    var timer = setTimeout(function () {
      if (ctrl) ctrl.abort();
    }, 12000);
    var opts = { credentials: "same-origin", cache: "no-store" };
    if (ctrl) opts.signal = ctrl.signal;
    fetch("/api/v1/snapshot", opts)
      .then(function (res) {
        if (res.status === 401) {
          window.location.href = "/unlock";
          return null;
        }
        if (!res.ok) throw new Error("http " + res.status);
        return res.json();
      })
      .then(function (snap) {
        clearTimeout(timer);
        if (!snap) return;
        state.failStreak = 0;
        state.lastOkAt = new Date().toISOString();
        state.lastGenerated = snap.generated || null;
        applySnapshot(snap);
      })
      .catch(function () {
        clearTimeout(timer);
        state.failStreak += 1;
        updateBeatFromSnap(null, false);
      });
  }

  poll();
  setInterval(poll, POLL_MS);
})();
