mermaid.initialize({
  startOnLoad: false,
  securityLevel: "strict",
  suppressErrorRendering: true,
  theme: "dark",
  htmlLabels: false,
  maxTextSize: 50000,
  maxEdges: 500,
  flowchart: { htmlLabels: false, useMaxWidth: true },
});

function stripMermaidStyles(svgText) {
  const parsed = new DOMParser().parseFromString(svgText, "image/svg+xml");
  const root = parsed.documentElement;
  if (root.localName !== "svg" || parsed.querySelector("parsererror")) throw new Error("Mermaid returned invalid SVG");
  root.querySelectorAll("style").forEach(style => style.remove());
  for (const element of [root, ...root.querySelectorAll("*")]) {
    element.removeAttribute("style");
    element.removeAttribute("font-style");
    element.removeAttribute("font-weight");
  }
  return new XMLSerializer().serializeToString(root);
}

window.addEventListener("message", async event => {
  const request = event.data;
  if (event.source !== window.parent || !request || request.type !== "firstmate-mermaid" || typeof request.id !== "string" || typeof request.source !== "string") return;
  try {
    await mermaid.parse(request.source, { suppressErrors: false });
    const { svg } = await mermaid.render(request.id, request.source);
    window.parent.postMessage({ type: "firstmate-mermaid", id: request.id, svg: stripMermaidStyles(svg) }, "*");
  } catch {
    window.parent.postMessage({ type: "firstmate-mermaid", id: request.id, error: true }, "*");
  }
});

window.parent.postMessage({ type: "firstmate-mermaid", ready: true }, "*");
