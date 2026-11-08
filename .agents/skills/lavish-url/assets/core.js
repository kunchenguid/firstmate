// lavish-url review runtime: the universal layer bin/fm-lavish-url.sh injects
// into every captured snapshot ahead of the matching enhancers.
//
// It owns three things and nothing else:
//   1. the enhancer registry (window.fmLavishUrl.register / describe);
//   2. target tracking - the element the reviewer last pointed at or focused,
//      pinned on pointerdown and previewed on hover, outlined on the page;
//   3. the prompt chips [Fix Layout], [Update Text], [Mobile Bug], each of
//      which queues exactly one Lavish prompt describing the current target.
//
// Captured page scripts are stripped before injection, so this runtime and the
// enhancers are the only scripts in the snapshot besides Lavish's own.
// Everything read from the page is untrusted text: it is only ever placed in
// textContent or prompt data, never in innerHTML or code.
(function () {
  "use strict";
  if (window.fmLavishUrl) return;

  var contextNode = document.getElementById("fm-lavish-url-context");
  var context = {};
  try {
    context = JSON.parse((contextNode && contextNode.textContent) || "{}") || {};
  } catch (err) {
    context = {};
  }

  var enhancers = [];
  var PANEL_ID = "fm-lavish-url-panel";
  var MAX_TEXT = 160;
  var MAX_DEPTH = 12;

  function clean(text, limit) {
    var value = String(text == null ? "" : text).replace(/\s+/g, " ").trim();
    var max = limit || MAX_TEXT;
    return value.length > max ? value.slice(0, max - 1) + "…" : value;
  }

  // Our own panel and outline, and Lavish's own UI (its annotation card lives
  // in a shadow root whose host carries data-lavish-ui), are never targets.
  // Captured pages cannot fake that marker: the sanitizer strips every
  // data-lavish-* attribute from captured markup.
  function inPanel(el) {
    return !!(el && el.closest && el.closest("#" + PANEL_ID + ", #fm-lavish-url-outline, [data-lavish-ui]"));
  }

  function cssEscape(value) {
    if (window.CSS && typeof window.CSS.escape === "function") return window.CSS.escape(value);
    return String(value).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
  }

  // A short structural selector: the nearest id anchors it, otherwise
  // tag:nth-of-type steps up to the body. It identifies the element in the
  // snapshot for the agent; it is not a stable production selector.
  function selectorFor(el) {
    if (!el || el.nodeType !== 1) return "";
    var parts = [];
    var node = el;
    while (node && node.nodeType === 1 && node !== document.documentElement) {
      if (node.id && !/^fm-lavish-url/.test(node.id)) {
        parts.unshift("#" + cssEscape(node.id));
        break;
      }
      var tag = node.tagName.toLowerCase();
      var parent = node.parentElement;
      if (parent) {
        var same = Array.prototype.filter.call(parent.children, function (child) {
          return child.tagName === node.tagName;
        });
        if (same.length > 1) tag += ":nth-of-type(" + (same.indexOf(node) + 1) + ")";
      }
      parts.unshift(tag);
      if (node === document.body) break;
      node = parent;
    }
    return parts.join(" > ");
  }

  // Enhancers register a describe(el) function returning null or
  // { kind, label, data }. A higher priority wins when two enhancers describe
  // the same element; the project enhancers outrank the generic default.
  function register(name, spec) {
    if (!spec || typeof spec.describe !== "function") return;
    enhancers.push({ name: String(name), priority: Number(spec.priority) || 0, spec: spec });
    enhancers.sort(function (a, b) { return b.priority - a.priority; });
    if (typeof spec.mark === "function") {
      try { spec.mark(document); } catch (err) { /* an enhancer bug must not break review */ }
    }
  }

  function describeOne(el) {
    for (var i = 0; i < enhancers.length; i += 1) {
      var found = null;
      try { found = enhancers[i].spec.describe(el, api); } catch (err) { found = null; }
      if (found && found.label) {
        return {
          enhancer: enhancers[i].name,
          kind: clean(found.kind || "element", 40),
          label: clean(found.label),
          data: found.data && typeof found.data === "object" ? found.data : {},
        };
      }
    }
    return null;
  }

  // The nearest described element is the target; described ancestors become
  // the context chain ("heading ... in drink card ... in menu category ...").
  function describe(el) {
    var target = null;
    var chain = [];
    var node = el;
    var depth = 0;
    while (node && node.nodeType === 1 && node !== document.documentElement && depth < MAX_DEPTH) {
      var found = describeOne(node);
      if (found) {
        if (!target) {
          target = found;
          target.element = node;
        } else if (chain.length < 4 && found.label !== target.label) {
          chain.push({ enhancer: found.enhancer, kind: found.kind, label: found.label, data: found.data });
        }
      }
      node = node.parentElement;
      depth += 1;
    }
    if (!target && el && el.nodeType === 1) {
      target = { enhancer: "core", kind: el.tagName.toLowerCase(), label: clean(el.textContent) || el.tagName.toLowerCase(), data: {}, element: el };
    }
    if (target) target.context = chain;
    return target;
  }

  var state = { pinned: null, hovered: null };
  var panel = null;
  var outline = null;
  var targetLine = null;
  var statusLine = null;
  var noteBox = null;

  function currentTarget() {
    return state.pinned || state.hovered;
  }

  function placeOutline() {
    var target = currentTarget();
    if (!outline) return;
    if (!target || !target.element || !target.element.getBoundingClientRect) {
      outline.style.display = "none";
      return;
    }
    var rect = target.element.getBoundingClientRect();
    outline.style.display = "block";
    outline.style.top = rect.top + window.scrollY - 2 + "px";
    outline.style.left = rect.left + window.scrollX - 2 + "px";
    outline.style.width = rect.width + 4 + "px";
    outline.style.height = rect.height + 4 + "px";
    outline.setAttribute("data-pinned", state.pinned ? "yes" : "no");
  }

  function renderTarget() {
    if (!targetLine) return;
    var target = currentTarget();
    if (!target) {
      targetLine.textContent = "Target: whole page (point at an element to target it)";
    } else {
      var text = (state.pinned ? "Pinned: " : "Hover: ") + target.kind + " “" + target.label + "”";
      if (target.context && target.context.length) {
        text += " in " + target.context.map(function (c) { return c.kind + " “" + c.label + "”"; }).join(" in ");
      }
      targetLine.textContent = text;
    }
    placeOutline();
  }

  var CHIPS = [
    { id: "fix-layout", label: "Fix Layout", verb: "Fix the layout of" },
    { id: "update-text", label: "Update Text", verb: "Update the text of" },
    { id: "mobile-bug", label: "Mobile Bug", verb: "Fix the mobile bug on" },
  ];

  function queueChip(chip) {
    var target = currentTarget();
    var note = noteBox ? clean(noteBox.value, 1000) : "";
    var where = target
      ? target.kind + " “" + target.label + "”"
      : "the whole page";
    if (target && target.context && target.context.length) {
      where += " (in " + target.context.map(function (c) { return c.kind + " “" + c.label + "”"; }).join(", in ") + ")";
    }
    var page = context.url || "";
    var prompt = chip.verb + " " + where + " on " + page + (context.viewport === "mobile" ? " (captured at mobile width)" : "") + "." + (note ? " Reviewer note: " + note : "");
    var options = {
      tag: chip.id,
      text: chip.label + ": " + where,
      data: {
        chip: chip.id,
        url: page,
        viewport: context.viewport || "desktop",
        target: target ? { enhancer: target.enhancer, kind: target.kind, label: target.label, data: target.data } : null,
        context: target ? target.context : [],
        note: note,
      },
    };
    if (target && target.element) {
      options.selector = selectorFor(target.element);
      options.element = target.element;
    }
    if (!window.lavish || typeof window.lavish.queuePrompt !== "function") {
      statusLine.textContent = "Open this snapshot through Lavish to send feedback.";
      return;
    }
    window.lavish.queuePrompt(prompt, options);
    statusLine.textContent = "Queued " + chip.label + " for " + where + ". Send it from the Lavish bar.";
    if (noteBox) noteBox.value = "";
  }

  function buildPanel() {
    panel = document.createElement("aside");
    panel.id = PANEL_ID;
    panel.setAttribute("aria-label", "Lavish URL review");
    var details = document.createElement("details");
    details.open = true;
    var summary = document.createElement("summary");
    summary.textContent = "Review · " + (context.host || "page") + (context.viewport === "mobile" ? " · mobile" : "");
    details.appendChild(summary);

    targetLine = document.createElement("p");
    targetLine.className = "fm-lu-target";
    details.appendChild(targetLine);

    var chips = document.createElement("div");
    chips.className = "fm-lu-chips";
    CHIPS.forEach(function (chip) {
      var button = document.createElement("button");
      button.type = "button";
      button.className = "fm-lu-chip";
      button.setAttribute("data-chip", chip.id);
      button.textContent = "[" + chip.label + "]";
      button.addEventListener("click", function (event) {
        event.preventDefault();
        event.stopPropagation();
        queueChip(chip);
      });
      chips.appendChild(button);
    });
    details.appendChild(chips);

    noteBox = document.createElement("textarea");
    noteBox.className = "fm-lu-note";
    noteBox.rows = 2;
    noteBox.placeholder = "Optional note sent with the next chip";
    noteBox.setAttribute("aria-label", "Optional note sent with the next chip");
    details.appendChild(noteBox);

    var row = document.createElement("div");
    row.className = "fm-lu-row";
    var clear = document.createElement("button");
    clear.type = "button";
    clear.className = "fm-lu-clear";
    clear.textContent = "Unpin";
    clear.addEventListener("click", function (event) {
      event.preventDefault();
      event.stopPropagation();
      state.pinned = null;
      renderTarget();
    });
    row.appendChild(clear);
    statusLine = document.createElement("span");
    statusLine.className = "fm-lu-status";
    statusLine.setAttribute("role", "status");
    statusLine.setAttribute("aria-live", "polite");
    row.appendChild(statusLine);
    details.appendChild(row);

    if (context.viewport === "mobile") {
      var hint = document.createElement("p");
      hint.className = "fm-lu-hint";
      hint.textContent = "Captured under mobile emulation (" + (context.viewport_size || "390x844") + "). Width-based styles follow this window, so narrow it to review the mobile breakpoints.";
      details.appendChild(hint);
    }

    panel.appendChild(details);
    outline = document.createElement("div");
    outline.id = "fm-lavish-url-outline";
    outline.setAttribute("aria-hidden", "true");
    document.body.appendChild(outline);
    document.body.appendChild(panel);
    renderTarget();
  }

  function onPointerDown(event) {
    if (inPanel(event.target)) return;
    state.pinned = describe(event.target);
    renderTarget();
  }

  function onHover(event) {
    if (state.pinned || inPanel(event.target)) return;
    state.hovered = describe(event.target);
    renderTarget();
  }

  function onFocus(event) {
    if (inPanel(event.target)) return;
    state.pinned = describe(event.target);
    renderTarget();
  }

  // The snapshot is a review surface, not the live site: following a link or
  // submitting a form would navigate the review frame away. Default actions are
  // cancelled; Lavish's own annotation handling still sees the event.
  function onClick(event) {
    if (inPanel(event.target)) return;
    var link = event.target.closest && event.target.closest("a[href], area[href]");
    if (link) event.preventDefault();
  }

  function onSubmit(event) {
    if (inPanel(event.target)) return;
    event.preventDefault();
  }

  var api = {
    context: context,
    register: register,
    describe: function (el) {
      var found = describe(el);
      if (found) delete found.element;
      return found;
    },
    clean: clean,
    selectorFor: selectorFor,
    chips: CHIPS.map(function (chip) { return chip.label; }),
  };
  window.fmLavishUrl = api;

  function start() {
    if (document.getElementById(PANEL_ID)) return;
    buildPanel();
    window.addEventListener("pointerdown", onPointerDown, true);
    document.addEventListener("mouseover", onHover, true);
    document.addEventListener("focusin", onFocus, true);
    document.addEventListener("click", onClick, true);
    document.addEventListener("submit", onSubmit, true);
    window.addEventListener("scroll", placeOutline, true);
    window.addEventListener("resize", placeOutline);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
