import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import MarkdownIt from 'markdown-it';
import { ANSWER_SCHEMA_VERSION } from './protocol.mjs';

export const SUBMIT_MARKER = `LAVISH-SUBMIT v${ANSWER_SCHEMA_VERSION}`;

const markdown = new MarkdownIt({
  html: false,
  linkify: true,
  typographer: false,
});

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function scriptJson(value) {
  return JSON.stringify(value)
    .replaceAll('<', '\\u003c')
    .replaceAll('>', '\\u003e')
    .replaceAll('&', '\\u0026')
    .replaceAll('\u2028', '\\u2028')
    .replaceAll('\u2029', '\\u2029');
}

async function loadVisuals(decision) {
  const visuals = new Map();
  for (const visual of decision.visuals) {
    const bytes = await readFile(join(decision.visualsDirectory, visual.file));
    visuals.set(visual.file, {
      ...visual,
      dataUrl: `data:${visual.media_type};base64,${bytes.toString('base64')}`,
    });
  }
  return visuals;
}

function visualFigure(visual) {
  return `<figure class="evidence" data-visual-file="${escapeHtml(visual.file)}">
    <img src="${visual.dataUrl}" alt="Evidence: ${escapeHtml(visual.file)}">
    <figcaption>${escapeHtml(visual.file)}</figcaption>
  </figure>`;
}

function visualGallery(files, visuals, label) {
  if (files.length === 0) return '';
  return `<section class="visual-block" aria-label="${escapeHtml(label)}">
    <div class="visual-grid">
      ${files.map((filename) => visualFigure(visuals.get(filename))).join('\n')}
    </div>
  </section>`;
}

function questionMarkup(question, index, visuals) {
  const optionMarkup = question.options.map((option, optionIndex) => {
    const inputId = `question-${index}-option-${optionIndex}`;
    return `<article class="option" data-option-value="${escapeHtml(option.value)}">
      <label class="option-choice" for="${inputId}">
        <input
          id="${inputId}"
          type="radio"
          name="${escapeHtml(question.key)}"
          value="${escapeHtml(option.value)}"
          data-question-key="${escapeHtml(question.key)}"
          required
        >
        <span class="radio-dot" aria-hidden="true"></span>
        <span>
          <strong>${escapeHtml(option.label)}</strong>
          <small>${escapeHtml(option.value)}</small>
        </span>
      </label>
      <label class="annotation-label" for="${inputId}-comment">
        Comment on this option
      </label>
      <textarea
        id="${inputId}-comment"
        rows="2"
        data-option-comment
        data-question-key="${escapeHtml(question.key)}"
        data-option-value="${escapeHtml(option.value)}"
        placeholder="Why this option works, does not work, or needs a change"
      ></textarea>
    </article>`;
  }).join('\n');
  const questionVisuals = question.visuals ?? [];
  return `<section
    class="question card"
    data-question-key="${escapeHtml(question.key)}"
    aria-labelledby="question-${index}-title"
  >
    <header class="question-header">
      <span class="question-number">${index + 1}</span>
      <div>
        <p class="eyebrow">${escapeHtml(question.key)}</p>
        <h2 id="question-${index}-title">${escapeHtml(question.prompt)}</h2>
      </div>
    </header>
    ${visualGallery(questionVisuals, visuals, `Evidence for ${question.prompt}`)}
    <div class="options">${optionMarkup}</div>
    <label class="annotation-label" for="question-${index}-note">
      Note on this whole question
    </label>
    <textarea
      id="question-${index}-note"
      rows="3"
      data-question-note
      data-question-key="${escapeHtml(question.key)}"
      placeholder="Add context that applies to every option or to the decision itself"
    ></textarea>
  </section>`;
}

function boardStyles(tokens) {
  return `${tokens}
* { box-sizing: border-box; }
html { min-height: 100%; background: var(--bg-canvas); }
body {
  margin: 0;
  min-height: 100vh;
  background:
    radial-gradient(circle at 10% 0%, rgba(0, 122, 255, 0.13), transparent 34rem),
    radial-gradient(circle at 96% 8%, rgba(8, 94, 62, 0.16), transparent 30rem),
    var(--bg-canvas);
  color: var(--text-primary);
  font-family: var(--font-sans);
  font-size: var(--body-lg-size);
  line-height: var(--body-lg-lh);
}
button, input, textarea { font: inherit; }
button, input[type='radio'] { cursor: pointer; }
main { width: min(980px, calc(100% - 32px)); margin: 0 auto; padding: 56px 0 96px; }
.masthead { display: grid; gap: 16px; margin-bottom: 32px; }
.brand { display: flex; align-items: center; gap: 10px; color: var(--text-secondary); }
.brand-mark {
  display: grid;
  width: 32px;
  height: 32px;
  place-items: center;
  border-radius: var(--radius-sm);
  background: var(--ruby-green);
  color: var(--white);
  font-weight: var(--fw-bold);
}
.brand strong { color: var(--text-primary); font-weight: var(--fw-semibold); }
h1 { margin: 0; font-size: clamp(34px, 7vw, var(--h2-size)); line-height: 1.05; letter-spacing: var(--tracking-tight); }
h2 { margin: 2px 0 0; font-size: clamp(20px, 3vw, var(--h7-size)); line-height: 1.25; }
.subtitle { margin: 0; color: var(--text-secondary); }
.context, .card, .review-card {
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  background: color-mix(in srgb, var(--bg-surface) 95%, transparent);
  box-shadow: var(--shadow-card);
}
.context { margin-bottom: 20px; padding: clamp(20px, 4vw, 32px); }
.context > :first-child { margin-top: 0; }
.context > :last-child { margin-bottom: 0; }
.context h1 { font-size: var(--h5-size); }
.context h2 { margin-top: 28px; font-size: var(--sub3-size); }
.context h3 { margin-top: 24px; }
.context p, .context li { color: var(--text-secondary); }
.context strong { color: var(--text-primary); }
.context a { color: var(--text-link); }
.context code { border-radius: var(--radius-xs); background: var(--bg-subtle); padding: 2px 6px; font-family: var(--font-mono); }
.context pre { overflow: auto; border-radius: var(--radius-md); background: var(--bg-sunken); padding: 16px; }
.context blockquote { margin-left: 0; border-left: 3px solid var(--ruby-green-ink); padding-left: 16px; color: var(--text-secondary); }
.eyebrow { margin: 0; color: var(--ruby-green-ink); font-size: var(--xs-size); font-weight: var(--fw-bold); letter-spacing: 0.09em; text-transform: uppercase; }
.questions { display: grid; gap: 20px; }
.question { padding: clamp(20px, 4vw, 30px); }
.question-header { display: grid; grid-template-columns: 36px 1fr; gap: 14px; align-items: start; margin-bottom: 22px; }
.question-number { display: grid; width: 34px; height: 34px; place-items: center; border-radius: var(--radius-full); background: var(--bg-selected); color: var(--blue-500); font-weight: var(--fw-bold); }
.options { display: grid; gap: 12px; }
.option { border: 1px solid var(--border-hairline); border-radius: var(--radius-md); background: var(--bg-sunken); padding: 14px; transition: border-color var(--dur-fast) var(--ease-standard), background var(--dur-fast) var(--ease-standard); }
.option:has(input:checked) { border-color: var(--blue-500); background: var(--bg-selected); box-shadow: 0 0 0 1px var(--blue-500); }
.option-choice { display: grid; grid-template-columns: 20px 1fr; gap: 12px; align-items: center; }
.option-choice input { position: absolute; opacity: 0; pointer-events: none; }
.radio-dot { width: 18px; height: 18px; border: 1px solid var(--border-default); border-radius: var(--radius-full); background: var(--bg-surface); box-shadow: inset 0 0 0 4px var(--bg-surface); }
.option-choice input:checked + .radio-dot { border-color: var(--blue-500); background: var(--blue-500); }
.option-choice input:focus-visible + .radio-dot { outline: 3px solid color-mix(in srgb, var(--blue-500) 35%, transparent); outline-offset: 2px; }
.option-choice strong { display: block; font-weight: var(--fw-semibold); }
.option-choice small { color: var(--text-tertiary); font-family: var(--font-mono); }
.annotation-label { display: block; margin: 14px 0 6px; color: var(--text-secondary); font-size: var(--sm-size); font-weight: var(--fw-medium); }
textarea { width: 100%; resize: vertical; border: 1px solid var(--border-default); border-radius: var(--radius-md); background: var(--bg-surface); color: var(--text-primary); padding: 11px 12px; }
textarea::placeholder { color: var(--text-placeholder); }
textarea:focus { outline: 2px solid var(--border-focus); outline-offset: 1px; border-color: transparent; }
.visual-block { margin: 0 0 22px; }
.visual-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(230px, 1fr)); gap: 12px; }
.evidence { margin: 0; overflow: hidden; border: 1px solid var(--border-hairline); border-radius: var(--radius-md); background: var(--bg-sunken); }
.evidence img { display: block; width: 100%; max-height: 520px; object-fit: contain; background: #090B0F; }
.evidence figcaption { padding: 8px 11px; color: var(--text-secondary); font-family: var(--font-mono); font-size: var(--xs-size); }
.overall { margin-top: 20px; padding: clamp(20px, 4vw, 30px); }
.actions { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 10px; margin-top: 24px; }
.button { min-height: 44px; border: 1px solid var(--border-default); border-radius: var(--radius-md); padding: 10px 18px; background: var(--bg-subtle); color: var(--text-primary); font-weight: var(--fw-semibold); }
.button:hover { background: var(--color-surface-active); }
.button.primary { border-color: var(--action-primary-ring); background: var(--action-primary); color: var(--white); box-shadow: var(--shadow-btn-primary); }
.button.primary:hover { background: var(--action-primary-hover); }
.button:disabled { cursor: default; opacity: 0.6; }
.form-error { margin: 12px 0 0; border-radius: var(--radius-md); background: color-mix(in srgb, var(--red-500) 14%, transparent); color: #FF9B94; padding: 10px 12px; }
.review-card { padding: clamp(20px, 4vw, 32px); }
.review-list { display: grid; gap: 14px; margin: 24px 0; }
.review-item { border-bottom: 1px solid var(--border-hairline); padding-bottom: 14px; }
.review-item:last-child { border-bottom: 0; }
.review-item h3 { margin: 0; font-size: var(--sub2-size); }
.review-item p { margin: 5px 0 0; color: var(--text-secondary); }
.review-item .selection { color: var(--text-primary); font-weight: var(--fw-semibold); }
.confirmation { border: 1px solid color-mix(in srgb, var(--green-500) 55%, var(--border-hairline)); border-radius: var(--radius-md); background: color-mix(in srgb, var(--ruby-green) 22%, var(--bg-surface)); padding: 14px; color: #8FE0BF; }
[hidden] { display: none !important; }
@media (max-width: 600px) {
  main { width: min(100% - 20px, 980px); padding-top: 28px; }
  .question, .context, .overall, .review-card { border-radius: var(--radius-md); }
  .actions .button { flex: 1; }
}`;
}

function boardScript(decision) {
  const clientManifest = {
    decision_id: decision.id,
    request_sha256: decision.manifest.request_sha256,
    questions: decision.manifest.questions.map((question) => ({
      key: question.key,
      prompt: question.prompt,
      options: question.options,
    })),
  };
  return `(() => {
  'use strict';
  const MANIFEST = ${scriptJson(clientManifest)};
  const SUBMIT_MARKER = ${scriptJson(SUBMIT_MARKER)};
  const form = document.querySelector('#decision-form');
  const review = document.querySelector('#review-step');
  const reviewList = document.querySelector('#review-list');
  const formError = document.querySelector('#form-error');
  const overallNote = document.querySelector('#overall-note');
  window.__lavishPayload = null;

  function buildPayload() {
    return {
      schema_version: ${ANSWER_SCHEMA_VERSION},
      decision_id: MANIFEST.decision_id,
      request_sha256: MANIFEST.request_sha256,
      answers: MANIFEST.questions.map((question) => {
        const selected = form.querySelector(
          'input[data-question-key="' + question.key + '"]:checked',
        );
        const questionNote = form.querySelector(
          'textarea[data-question-note][data-question-key="' + question.key + '"]',
        );
        const optionComments = Object.create(null);
        for (const input of form.querySelectorAll(
          'textarea[data-option-comment][data-question-key="' + question.key + '"]',
        )) {
          if (input.value !== '') optionComments[input.dataset.optionValue] = input.value;
        }
        return {
          key: question.key,
          value: selected?.value,
          question_note: questionNote.value,
          option_comments: optionComments,
        };
      }),
      note: overallNote.value,
    };
  }

  function addReviewLine(parent, text, className) {
    const line = document.createElement('p');
    line.textContent = text;
    if (className) line.className = className;
    parent.append(line);
  }

  function renderReview(payload) {
    reviewList.replaceChildren();
    for (const answer of payload.answers) {
      const question = MANIFEST.questions.find((candidate) => candidate.key === answer.key);
      const option = question.options.find((candidate) => candidate.value === answer.value);
      const item = document.createElement('article');
      item.className = 'review-item';
      const heading = document.createElement('h3');
      heading.textContent = question.prompt;
      item.append(heading);
      addReviewLine(item, option.label + ' [' + option.value + ']', 'selection');
      if (answer.question_note) addReviewLine(item, 'Question note: ' + answer.question_note);
      for (const [value, comment] of Object.entries(answer.option_comments)) {
        addReviewLine(item, 'Comment on ' + value + ': ' + comment);
      }
      reviewList.append(item);
    }
    if (payload.note) {
      const item = document.createElement('article');
      item.className = 'review-item';
      const heading = document.createElement('h3');
      heading.textContent = 'Overall note';
      item.append(heading);
      addReviewLine(item, payload.note);
      reviewList.append(item);
    }
  }

  document.querySelector('#review-button').addEventListener('click', () => {
    const missing = MANIFEST.questions.find((question) => !form.querySelector(
      'input[data-question-key="' + question.key + '"]:checked',
    ));
    if (missing) {
      formError.textContent = 'Choose one option for: ' + missing.prompt;
      formError.hidden = false;
      form.querySelector('[data-question-key="' + missing.key + '"]').scrollIntoView({
        behavior: 'smooth',
        block: 'center',
      });
      return;
    }
    formError.hidden = true;
    renderReview(buildPayload());
    form.hidden = true;
    review.hidden = false;
    window.scrollTo({ top: 0, behavior: 'smooth' });
  });

  document.querySelector('#back-button').addEventListener('click', () => {
    review.hidden = true;
    form.hidden = false;
    window.scrollTo({ top: document.body.scrollHeight, behavior: 'smooth' });
  });

  document.querySelector('#submit-button').addEventListener('click', (event) => {
    const payload = buildPayload();
    window.__lavishPayload = payload;
    document.title = SUBMIT_MARKER;
    event.currentTarget.disabled = true;
    document.querySelector('#confirmation').hidden = false;
  });
})();`;
}

export async function renderBoard(decision) {
  const [tokens, visuals] = await Promise.all([
    readFile(fileURLToPath(new URL('./relvino-tokens.css', import.meta.url)), 'utf8'),
    loadVisuals(decision),
  ]);
  const assignedVisuals = new Set(
    decision.manifest.questions.flatMap((question) => question.visuals ?? []),
  );
  const contextVisuals = [...visuals.keys()].filter((filename) => !assignedVisuals.has(filename));
  const questions = decision.manifest.questions
    .map((question, index) => questionMarkup(question, index, visuals))
    .join('\n');
  const title = escapeHtml(decision.manifest.title);
  return `<!doctype html>
<html lang="en" data-theme="dark">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; font-src data:">
  <title>Lavish - ${title}</title>
  <style>${boardStyles(tokens)}</style>
</head>
<body>
  <main>
    <header class="masthead">
      <div class="brand"><span class="brand-mark">R</span><strong>Relvino</strong><span>Lavish decision</span></div>
      <h1>${title}</h1>
      <p class="subtitle">Review the full context, annotate any option or question, then submit one complete batch.</p>
    </header>
    <article class="context" data-request-context>${markdown.render(decision.requestText)}</article>
    ${visualGallery(contextVisuals, visuals, 'Decision evidence')}
    <form id="decision-form" novalidate>
      <div class="questions">${questions}</div>
      <section class="overall card">
        <label class="annotation-label" for="overall-note">Overall note</label>
        <textarea id="overall-note" rows="3" placeholder="Anything firstmate should know about this complete batch"></textarea>
      </section>
      <p id="form-error" class="form-error" role="alert" hidden></p>
      <div class="actions"><button id="review-button" class="button primary" type="button">Review answers</button></div>
    </form>
    <section id="review-step" class="review-card" aria-labelledby="review-title" hidden>
      <p class="eyebrow">Final review</p>
      <h2 id="review-title">Submit this complete answer batch?</h2>
      <div id="review-list" class="review-list"></div>
      <p id="confirmation" class="confirmation" role="status" hidden>Answer captured. Firstmate will validate and confirm receipt.</p>
      <div class="actions">
        <button id="back-button" class="button" type="button">Back</button>
        <button id="submit-button" class="button primary" type="button">Submit to firstmate</button>
      </div>
    </section>
  </main>
  <script>${boardScript(decision)}</script>
</body>
</html>\n`;
}
