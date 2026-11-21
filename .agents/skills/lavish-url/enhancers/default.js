// fm-lavish-url-match: always
//
// Universal semantic detection for any captured page: headings, forms and
// their fields, buttons, links, and anything carrying an ARIA label. It is the
// lowest-priority layer, so a matching project enhancer that understands the
// page better describes the same element first.
(function (lu) {
  "use strict";
  if (!lu) return;

  function labelFromIds(el, attr) {
    var ids = (el.getAttribute(attr) || "").split(/\s+/).filter(Boolean);
    return ids.map(function (id) {
      var ref = document.getElementById(id);
      return ref ? ref.textContent : "";
    }).join(" ");
  }

  function ariaLabel(el) {
    return lu.clean(el.getAttribute("aria-label") || labelFromIds(el, "aria-labelledby"));
  }

  function fieldLabel(el) {
    if (el.labels && el.labels.length) return lu.clean(el.labels[0].textContent);
    return ariaLabel(el) || lu.clean(el.getAttribute("placeholder") || el.getAttribute("name") || el.id || "");
  }

  var HEADING = /^H[1-6]$/;
  var FIELD = /^(INPUT|SELECT|TEXTAREA)$/;
  var BUTTON_INPUT = /^(submit|button|reset|image)$/i;

  function describe(el) {
    var tag = el.tagName;
    var role = (el.getAttribute("role") || "").toLowerCase();
    if (HEADING.test(tag) || role === "heading") {
      var level = HEADING.test(tag) ? tag.slice(1) : el.getAttribute("aria-level") || "";
      return { kind: "heading" + (level ? " h" + level : ""), label: lu.clean(el.textContent) || ariaLabel(el), data: { level: level } };
    }
    if (tag === "BUTTON" || role === "button" || (tag === "INPUT" && BUTTON_INPUT.test(el.type))) {
      return { kind: "button", label: lu.clean(el.textContent || el.value) || ariaLabel(el) || lu.clean(el.getAttribute("title")), data: { type: el.getAttribute("type") || "" } };
    }
    if (FIELD.test(tag)) {
      return { kind: "form field", label: fieldLabel(el) || tag.toLowerCase(), data: { name: el.getAttribute("name") || "", type: el.getAttribute("type") || tag.toLowerCase() } };
    }
    if (tag === "FORM" || role === "form" || role === "search") {
      return { kind: "form", label: ariaLabel(el) || lu.clean(el.getAttribute("name") || el.id || el.getAttribute("data-fm-action") || "form"), data: { action: el.getAttribute("data-fm-action") || "" } };
    }
    if ((tag === "A" && el.hasAttribute("href")) || role === "link") {
      return { kind: "link", label: lu.clean(el.textContent) || ariaLabel(el) || lu.clean(el.getAttribute("title")) || lu.clean(el.getAttribute("href")), data: { href: el.getAttribute("href") || "" } };
    }
    var aria = ariaLabel(el);
    if (aria) {
      return { kind: role || "labelled " + tag.toLowerCase(), label: aria, data: { role: role } };
    }
    if (tag === "IMG" && el.getAttribute("alt")) {
      return { kind: "image", label: lu.clean(el.getAttribute("alt")), data: { src: el.getAttribute("src") || "" } };
    }
    return null;
  }

  lu.register("default", { priority: 0, describe: describe });
})(window.fmLavishUrl);
