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

window.addEventListener("message", async event => {
  const request = event.data;
  if (event.source !== window.parent || !request || request.type !== "firstmate-mermaid" || typeof request.id !== "string" || typeof request.source !== "string") return;
  try {
    await mermaid.parse(request.source, { suppressErrors: false });
    const { svg } = await mermaid.render(request.id, request.source);
    window.parent.postMessage({ type: "firstmate-mermaid", id: request.id, svg }, "*");
  } catch {
    window.parent.postMessage({ type: "firstmate-mermaid", id: request.id, error: true }, "*");
  }
});

window.parent.postMessage({ type: "firstmate-mermaid", ready: true }, "*");
