// The decision page. It talks only to its own origin, so it works unchanged
// under whatever address it is served from - nothing here knows the hostname.
//
// Chrome strings are English because this file is shared material; the question
// and its options are whatever the task supplied, in whatever language it used.
(function () {
  'use strict';

  var tg = window.Telegram && window.Telegram.WebApp;
  var elQuestion = document.getElementById('question');
  var elOptions = document.getElementById('options');
  var elStatus = document.getElementById('status');

  function say(text, kind) {
    elStatus.textContent = text;
    elStatus.className = kind || '';
  }

  function param(name) {
    var match = new RegExp('[?&]' + name + '=([^&]*)').exec(location.search);
    return match ? decodeURIComponent(match[1]) : '';
  }

  // Opened outside Telegram there is no initData, and without it the service
  // rejects everything. Say so plainly instead of leaving a blank page, which
  // is indistinguishable from a broken deployment.
  if (!tg || !tg.initData) {
    elQuestion.textContent = 'Open this from Telegram.';
    say('This page only works inside the Telegram app, where it is signed.');
    return;
  }

  tg.ready();
  tg.expand();

  var headers = { 'X-Telegram-Init-Data': tg.initData };
  var questionId = param('f');

  function fail(response) {
    return response.json()
      .catch(function () { return {}; })
      .then(function (body) {
        throw new Error(body.error || ('HTTP ' + response.status));
      });
  }

  fetch('question?f=' + encodeURIComponent(questionId), { headers: headers })
    .then(function (r) { return r.ok ? r.json() : fail(r); })
    .then(function (body) { render(body.question); })
    .catch(function (err) {
      elQuestion.textContent = 'Not available.';
      say(String(err.message || err), 'error');
    });

  function render(question) {
    elQuestion.textContent = question.text;
    say('');
    question.options.forEach(function (label, index) {
      var button = document.createElement('button');
      button.textContent = label;
      button.addEventListener('click', function () { choose(index, label); });
      elOptions.appendChild(button);
    });
  }

  function choose(index, label) {
    var buttons = elOptions.querySelectorAll('button');
    // Disable every option on the first tap. The prototype's original failure
    // was an answer that looked like nothing happened, so the captain tapped
    // again - and a second tap must not be able to send a second decision.
    Array.prototype.forEach.call(buttons, function (b) { b.disabled = true; });
    say('Sending...');

    fetch('answer', {
      method: 'POST',
      headers: Object.assign({ 'Content-Type': 'application/json' }, headers),
      body: JSON.stringify({ f: questionId, choice: index })
    })
      .then(function (r) { return r.ok ? r.json() : fail(r); })
      .then(function () {
        say('✓ "' + label + '" received.', 'ok');
        if (tg.HapticFeedback) { tg.HapticFeedback.notificationOccurred('success'); }
        setTimeout(function () { tg.close(); }, 1200);
      })
      .catch(function (err) {
        say('Not received: ' + String(err.message || err), 'error');
        Array.prototype.forEach.call(buttons, function (b) { b.disabled = false; });
      });
  }
}());
