// fm-lavish-url-match: host teatop82ranch.com
//
// TeaTop 82 Ranch storefront (teatop82ranch.com): drink cards on the homepage
// catalog and the shop grid, menu categories from /shop/category links and the
// shop's category list, and the boba and topping chips on a drink page, so
// feedback names the drink, category, or topping the reviewer meant.
(function (lu) {
  "use strict";
  if (!lu) return;

  function text(el, selector) {
    var found = el.querySelector(selector);
    return found ? lu.clean(found.textContent) : "";
  }

  function categoryFromHref(href) {
    var match = /\/shop\/category\/([^/?#]+)/.exec(href || "");
    if (!match) return "";
    return decodeURIComponent(match[1]).replace(/-\d+$/, "").replace(/-/g, " ");
  }

  function describe(el) {
    if (el.classList.contains("tt-card")) {
      var name = text(el, ".tt-card-name");
      return { kind: "drink card", label: name || lu.clean(el.textContent), data: { name: name, price: text(el, ".tt-price"), surface: "homepage catalog" } };
    }
    if (el.classList.contains("oe_product")) {
      var title = text(el, ".o_wsale_products_item_title");
      var cart = el.querySelector(".oe_product_cart");
      return { kind: "drink card", label: title || (cart && cart.getAttribute("aria-label")) || lu.clean(el.textContent), data: { name: title, surface: "shop grid" } };
    }
    if (el.classList.contains("ttop_topping_chip")) {
      var topping = text(el, ".ttop_topping_btn");
      var button = el.querySelector(".ttop_topping_btn");
      var label = button ? lu.clean(Array.prototype.filter.call(button.childNodes, function (node) { return node.nodeType === 3; }).map(function (node) { return node.textContent; }).join(" ")) : "";
      return { kind: "boba chip", label: label || topping, data: { topping_id: el.getAttribute("data-id") || "", included: el.getAttribute("data-included") === "1", price: el.getAttribute("data-price") || "" } };
    }
    if (el.tagName === "A") {
      var category = categoryFromHref(el.getAttribute("href"));
      if (category) {
        return { kind: "menu category", label: lu.clean(el.textContent) || category, data: { category: category, href: el.getAttribute("href") } };
      }
    }
    if (el.id === "o_wsale_categories" || el.classList.contains("wsale_products_categories_list")) {
      return { kind: "menu categories", label: "shop category list", data: {} };
    }
    if (el.id === "boba-catalog") {
      return { kind: "menu section", label: text(el, "h2") || "boba catalog", data: {} };
    }
    return null;
  }

  lu.register("teatop", { priority: 30, describe: describe });
})(window.fmLavishUrl);
