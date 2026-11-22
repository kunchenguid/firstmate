// fm-lavish-url-match: html data-oe-model
// fm-lavish-url-match: html data-oe-id
// fm-lavish-url-match: html data-main-object
// fm-lavish-url-match: html data-view-xmlid
// fm-lavish-url-match: html content="Odoo
// fm-lavish-url-match: html /web/assets/
//
// Odoo pages: names the record and field behind data-oe-model / data-oe-id /
// data-oe-field, the QWeb view behind ir.ui.view regions and data-oe-xpath, and
// the page's main object and template from the <html> element, so feedback
// points at the Odoo record or template to change rather than at markup.
(function (lu) {
  "use strict";
  if (!lu) return;

  var root = document.documentElement;
  var page = {
    main_object: root.getAttribute("data-main-object") || "",
    view_xmlid: root.getAttribute("data-view-xmlid") || "",
    website_id: root.getAttribute("data-website-id") || "",
  };

  function attr(el, name) {
    return el.getAttribute(name) || "";
  }

  function describe(el) {
    var model = attr(el, "data-oe-model");
    var id = attr(el, "data-oe-id");
    var field = attr(el, "data-oe-field");
    var xpath = attr(el, "data-oe-xpath");
    if (model === "ir.ui.view") {
      return {
        kind: "QWeb template",
        label: "view " + (id || "?") + (xpath ? " at " + xpath : "") + (page.view_xmlid ? " (" + page.view_xmlid + ")" : ""),
        data: { oe_model: model, oe_id: id, oe_field: field, oe_xpath: xpath, view_xmlid: page.view_xmlid },
      };
    }
    if (model) {
      return {
        kind: "Odoo record",
        label: model + (id ? "#" + id : "") + (field ? " field " + field : ""),
        data: { oe_model: model, oe_id: id, oe_field: field, oe_type: attr(el, "data-oe-type"), main_object: page.main_object },
      };
    }
    var expression = attr(el, "data-oe-expression");
    if (expression || attr(el, "data-oe-type")) {
      return {
        kind: "Odoo field",
        label: (attr(el, "data-oe-type") || "value") + (expression ? " " + lu.clean(expression, 80) : ""),
        data: { oe_type: attr(el, "data-oe-type"), oe_expression: expression, main_object: page.main_object },
      };
    }
    if (el === document.body && (page.main_object || page.view_xmlid)) {
      return {
        kind: "Odoo page",
        label: page.view_xmlid || page.main_object,
        data: page,
      };
    }
    return null;
  }

  lu.register("odoo", { priority: 20, describe: describe });
})(window.fmLavishUrl);
