// Shared marks and helpers: time words, stage circles, model avatars, home colours, lane states in plain words, filters.
import { html, useState, useEffect, useRef } from './vendor/preact-htm-3.1.1.js'
export { html, useState, useEffect, useRef }

export const now = () => Date.now() / 1000
export function dur(s) {
  s = Math.max(0, Math.round(s))
  if (s < 60) return 'now'
  if (s < 3600) return `${Math.floor(s / 60)}m`
  const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60)
  if (s < 86400) return h < 10 && m ? `${h}h ${m}m` : `${h}h`
  const d = Math.floor(s / 86400), hh = Math.floor(s % 86400 / 3600)
  return d < 7 && hh ? `${d}d ${hh}h` : `${d}d`
}
export const hm = t => {
  const d = new Date(t * 1000), tm = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })
  return d.toDateString() === new Date().toDateString() ? tm : `${d.toLocaleDateString([], { weekday: 'short' })} ${tm}`
}
// A phone's columns move sideways only: scrollIntoView would also scroll the page down to a tall column's top.
export const toCol = (el, k, behavior = 'auto') => el?.scrollTo({ left: k * el.clientWidth, behavior })
export const prNum = u => (u || '').match(/\/(?:pull|merge_requests|\+)\/(\d+)(?:[/?#]|$)/)?.[1]

export const STAGES = ['queued', 'building', 'review', 'test', 'ci', 'merge', 'landed']
export const ACTIVE = STAGES.slice(1, 6)
export const SNAME = { queued: 'Queued', building: 'Building', review: 'Review', test: 'Test', ci: 'PR + CI', merge: 'To merge', landed: 'Landed today' }

// Stuck is blocked or on a decision; a lane the captain put on hold waits on purpose and is not stuck.
export const stuck = c => c.wait === 'blocked' || c.wait === 'decision'
export const state = c => c.wait === 'blocked' ? ['Blocked', 'var(--red)'] : c.wait === 'decision' ? [c.home === 'main' ? 'Main decides' : 'Lead decides', 'var(--orange)']
  : c.wait === 'waiting' ? ['Waiting', 'var(--yellow)'] : c.wait === 'parked' ? ['On hold', 'var(--grey)'] : null
export const plain = t => (t || '').replace(/\[(?:key|at)=[^\]]*\]|\b(?:evidence|ref)[:=]\S+/g, '').trim()
export const reason = c => c.wait ? plain(c.why) : ''
export const total = (d, n, stage = 'active', home) =>
  (stage === 'landed' || stage === 'all' || d.homes.some(h => (!home || h.id === home) && (stage === 'queued' ? h.ready == null : !h.known || stage === 'open' && h.ready == null))) ? `≥${n}` : n

// Eight fixed home colours, in registry order.
export const hc = (d, id) => `var(--h-${(d.homes.findIndex(h => h.id === id) % 8 + 8) % 8 + 1})`
export const hname = (d, id) => d.homes.find(h => h.id === id)?.name || id

// Stuck first, then waiting, then by time in stage; on hold last; landed newest first.
const rank = c => stuck(c) ? 0 : c.wait === 'waiting' ? 1 : c.wait === 'parked' ? 3 : 2
// An ask's type, the same rule as fm-dashboard.sh: an explicit type field wins; else pick on a pick/choose/which verb, the word options, two option markers ("1)" or "A Foo, C Bar"), or three or more choices ending "or ...?"; approval on approv*/merg*; else yes/no.
export const ASK_TAG = { yn: 'yes/no', pick: 'pick', approval: 'approval' }
export const askType = (text, explicit) => Object.hasOwn(ASK_TAG, explicit) ? explicit
  : /\b(?:pick|choose|which)\b|\boptions?\b/i.test(text) || (text.match(/(?:^|\s)\(?[1-9a-h]\)/gi) || []).length >= 2
    || (text.match(/(?:^|[:,;]\s+)[A-H]\s+[A-Z]/g) || []).length >= 2 || /(?:[^,?]*,){2}\s*or\s[^,?]*\?\s*$/i.test(text) ? 'pick'
  : /\b(?:approv|merg)\w*/i.test(text) ? 'approval' : 'yn'
// Newest first unless asked otherwise; asks with no usable time go last, in their own order.
export const askOrder = (asks, newest = true) => {
  const dated = asks.filter(a => a.age != null).sort((a, b) => newest ? a.age - b.age : b.age - a.age)
  return [...dated, ...asks.filter(a => a.age == null)]
}
export const sorted = cs => [...cs].sort((a, b) => a.stage === 'landed' && b.stage === 'landed' ? b.since - a.since : rank(a) - rank(b) || (a.since || 9e9) - (b.since || 9e9))
// A waiting lane's age is its time in that wait, any other lane's its time in stage.
export const age = c => c.wait_since && c.wait ? now() - c.wait_since : c.since ? now() - c.since : null

export const I = (d, size = 16) => html`<svg width=${size} height=${size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`
export const IC = {
  inbox: html`<path d="M2.5 9.5h3l1 1.8h3l1-1.8h3M2.5 9.5l1.4-5.1a1 1 0 0 1 1-.7h6.2a1 1 0 0 1 1 .7l1.4 5.1v3a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1z"/>`,
  board: html`<rect x="2.5" y="2.5" width="11" height="11" rx="2"/><path d="M6.2 2.5v11M9.8 2.5v11"/>`,
  search: html`<circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5l3 3"/>`,
  filter: html`<path d="M2.5 4.5h11M4.5 8h7M6.5 11.5h3"/>`,
  display: html`<path d="M2.5 5h6M11.5 5h2M2.5 11h2M7.5 11h6"/><circle cx="10" cy="5" r="1.5"/><circle cx="6" cy="11" r="1.5"/>`,
  theme: html`<path d="M13 9.6A5.5 5.5 0 1 1 6.4 3a4.4 4.4 0 0 0 6.6 6.6z"/>`,
  sun: html`<circle cx="8" cy="8" r="2.75"/><path d="M8 1.75v1.5M8 12.75v1.5M1.75 8h1.5M12.75 8h1.5M3.6 3.6l1 1M11.4 11.4l1 1M3.6 12.4l1-1M11.4 4.6l1-1"/>`,
  pr: html`<circle cx="4.5" cy="3.5" r="1.5"/><circle cx="4.5" cy="12.5" r="1.5"/><circle cx="11.5" cy="12.5" r="1.5"/><path d="M4.5 5v6M11.5 11V6.5a2 2 0 0 0-2-2H8M9.5 3L8 4.5 9.5 6"/>`,
  up: html`<path d="M4 10l4-4 4 4"/>`, down: html`<path d="M4 6l4 4 4-4"/>`, x: html`<path d="M4 4l8 8M12 4l-8 8"/>`,
  check: html`<path d="M3.5 8.3l2.8 2.7 6-6"/>`,
}
export const Caret = () => html`<svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true"><path d="M2 3.5h6L5 7z" fill="currentColor"/></svg>`

// Linear's status circles: dashed before work starts, a pie that fills as the lane moves, a filled check once landed.
const FILL = { building: .25, review: .5, test: .75, ci: .5, merge: .85 }
export function StageIcon({ s, size = 14 }) {
  const c = `var(--st-${s})`
  if (s === 'queued') return html`<svg width=${size} height=${size} viewBox="0 0 14 14" aria-hidden="true"><circle cx="7" cy="7" r="5.6" fill="none" stroke=${c} stroke-width="1.5" stroke-dasharray="1.6 1.6"/></svg>`
  if (s === 'landed') return html`<svg width=${size} height=${size} viewBox="0 0 14 14" aria-hidden="true"><circle cx="7" cy="7" r="6.3" fill=${c}/><path d="M4.4 7.2l1.8 1.8 3.5-3.6" fill="none" stroke="#fff" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>`
  const a = FILL[s] * 2 * Math.PI
  return html`<svg width=${size} height=${size} viewBox="0 0 14 14" aria-hidden="true"><circle cx="7" cy="7" r="5.6" fill="none" stroke=${c} stroke-width="1.5"/>
    <path d=${`M7 7V3.4A3.6 3.6 0 ${FILL[s] > .5 ? 1 : 0} 1 ${(7 + 3.6 * Math.sin(a)).toFixed(2)} ${(7 - 3.6 * Math.cos(a)).toFixed(2)}Z`} fill=${c}/></svg>`
}

// A model is the lane's assignee: a small round avatar with a muted fill and its own glyph; a lane nobody holds yet is a dashed circle.
export const MODELS = {
  opus: ['Opus', 'M8 2.5v11M2.5 8h11M4.1 4.1l7.8 7.8M11.9 4.1l-7.8 7.8'],
  sol: ['Sol', 'M8 5.6a2.4 2.4 0 1 1 0 4.8a2.4 2.4 0 1 1 0-4.8M8 2v1.3M8 12.7V14M2 8h1.3M12.7 8H14M3.8 3.8l.9.9M11.3 11.3l.9.9M12.2 3.8l-.9.9M4.7 11.3l-.9.9'],
  muse: ['Muse Spark', 'M8 2.2C8.4 5.9 10.1 7.6 13.8 8C10.1 8.4 8.4 10.1 8 13.8C7.6 10.1 5.9 8.4 2.2 8C5.9 7.6 7.6 5.9 8 2.2Z'],
  qwen: ['Qwen', 'M8 2.4l4.8 2.8v5.6L8 13.6l-4.8-2.8V5.2zM8 5.8v4.4'],
}
export const mname = (m, d) => !m ? 'Not started' : MODELS[m]?.[0] || d?.cards.find(c => c.model === m)?.model_name || m.replace(/^tool-/, '')
export function Av({ m, size = 16 }) {
  if (!m) return html`<svg width=${size} height=${size} viewBox="0 0 16 16" role="img" aria-label="Not started"><circle cx="8" cy="8" r="6.8" fill="none" stroke="var(--ink-4)" stroke-width="1.2" stroke-dasharray="2 1.8"/></svg>`
  const k = MODELS[m] ? m : null, c = `var(--m-${k || 'other'})`
  return html`<svg width=${size} height=${size} viewBox="0 0 16 16" role="img" aria-label=${mname(m)} style=${{ color: c, flex: 'none' }}>
    <circle cx="8" cy="8" r="7.6" fill="currentColor" fill-opacity=".2" stroke="currentColor" stroke-opacity=".35" stroke-width=".8"/>
    ${k ? html`<path d=${MODELS[k][1]} transform="translate(2.4 2.4) scale(.7)" fill=${k === 'muse' ? 'currentColor' : 'none'} stroke=${k === 'muse' ? 'none' : 'currentColor'} stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/>`
      : html`<text x="8" y="11" text-anchor="middle" font-size="8" font-weight="600" fill="currentColor">${m[0].toUpperCase()}</text>`}</svg>`
}

// The filters every view shares, kept in the URL: home, model, state and stage.
export const sid = c => c.wait || 'moving'
export const STATES = [['blocked', 'Blocked'], ['decision', 'Main or lead decides'], ['waiting', 'Waiting'], ['parked', 'On hold'], ['moving', 'Moving']]
export const filterCards = (d, r) => d.cards.filter(c => (!r.home.length || r.home.includes(c.home)) && (!r.model.length || r.model.includes(c.model || 'none'))
  && (!r.state.length || r.state.includes(sid(c))) && (!r.stage.length || r.stage.includes(c.stage)))
