(() => {
  "use strict";

  const decisionForms = document.querySelectorAll("form[data-fm-decision]");
  const COPY_BUTTON_LABEL = "Copy visible answer";

  function answerFrom(form) {
    return [...new FormData(form).entries()]
      .map(([key, value]) => `${key}=${String(value).trim() || "(none)"}`)
      .join("; ");
  }

  function stateFor(form) {
    return form.querySelector("[data-fm-decision-state]");
  }

  function setState(form, message, queued = false) {
    const output = stateFor(form);
    if (!output) return;
    output.textContent = message;
    output.classList.toggle("is-queued", queued);
    const copyButton = form.querySelector("[data-fm-copy-answer]");
    if (copyButton) copyButton.textContent = COPY_BUTTON_LABEL;
  }

  for (const form of decisionForms) {
    form.addEventListener("change", () => {
      const answer = answerFrom(form);
      setState(form, answer ? `Selected locally: ${answer}` : "No answer selected.");
    });

    form.addEventListener("submit", (event) => {
      event.preventDefault();
      if (!form.reportValidity()) return;

      const decisionId = form.dataset.fmDecision;
      const answer = answerFrom(form);
      const prompt = `Decision ${decisionId}: ${answer}`;
      const lavish = window.lavish;

      if (lavish && typeof lavish.queuePrompt === "function") {
        lavish.queuePrompt(prompt, {
          tag: "decision",
          text: prompt,
          element: form,
          queueKey: decisionId,
          data: { question: decisionId, answer },
        });
        setState(form, `Queued for review (not sent yet): ${prompt}`, true);
        return;
      }

      setState(form, `Prepared locally (not sent): ${prompt}`, true);
    });

    const copyButton = form.querySelector("[data-fm-copy-answer]");
    if (!copyButton) continue;
    copyButton.addEventListener("click", async () => {
      const output = stateFor(form);
      if (!output || !output.textContent.trim()) return;
      try {
        await navigator.clipboard.writeText(output.textContent);
        copyButton.textContent = "Copied";
      } catch {
        output.focus();
        setState(form, `${output.textContent}\nCopy was unavailable; select this visible answer manually.`, output.classList.contains("is-queued"));
      }
    });
  }
})();
