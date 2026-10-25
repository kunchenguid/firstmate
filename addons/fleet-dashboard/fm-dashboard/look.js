// The approved look's shared pieces: a project's own icon in a small white tile, the P0-P3 chip and one list row
// (the reference's "Time by project": tile, chip and title, the value on the right, a thin bar with its note beneath).
import { html } from './ui.js'

// Each project's own icon, copied from its repo into icons/ (a project that ships none shows its monogram).
const ICONS = { byokit: 'byokit.svg', crewhouse: 'crewhouse.png', desklink: ['desklink.svg', '6% 50%'], 'done-done': 'done-done.svg', 'first-draft': 'first-draft.svg',
  firstmate: 'firstmate.svg', 'firstmate-fork': 'firstmate.svg', 'firstmate-addons': 'firstmate-addons.svg', 'herdr-runtime': 'herdr-runtime.svg',
  'learn-from-mistakes': 'learn-from-mistakes.svg', 'muxr-cloud': 'muxr-cloud.svg', muxr: 'pockit.png', pockit: 'pockit.png', takeone: 'takeone.png', ownvoice: 'ownvoice.png', 'sign-off': 'sign-off.svg' }
// A home shows the project most of its tickets belong to; Main is Firstmate's own home.
const homeOf = new WeakMap()
function homeProject(d, h) {
  if (h === 'main') return 'firstmate'
  if (!homeOf.has(d)) { const n = {}; for (const t of d.tickets || []) if (t.project) (n[t.home] ||= {})[t.project] = (n[t.home][t.project] || 0) + 1
    homeOf.set(d, Object.fromEntries(Object.entries(n).map(([k, v]) => [k, Object.entries(v).sort((a, b) => b[1] - a[1])[0][0]]))) }
  return homeOf.get(d)[h]
}
export const mono = name => { if (!name || name === 'none') return '–'; const ps = String(name).split(/[-\s_]+/).filter(Boolean); return (ps.length > 1 ? ps[0][0] + ps.at(-1)[0] : String(name || '–').slice(0, 2)).toUpperCase() }
export function Tile({ d, name, small }) {
  const ic = ICONS[name] || ICONS[homeProject(d, name)], [f, pos] = Array.isArray(ic) ? ic : [ic]
  return html`<span class=${(small ? 'mono' : 'tile') + (ic ? ' img' : '')} aria-hidden="true">${ic ? html`<img src=${'icons/' + f} alt="" style=${pos ? { objectPosition: pos } : null}/>` : mono(name)}</span>`
}
// the one label every view carries, so each screen names the dashboard it belongs to
export const LABEL = (extra = '') => html`<span class="dash"><i>F</i>Fleet dashboard${extra}</span>`
export const PRIO = ['Urgent', 'High', 'Medium', 'Low']
export const LIC = { list: html`<path d="M6 4.5h7.5M6 8h7.5M6 11.5h7.5M2.5 4.5h.5M2.5 8h.5M2.5 11.5h.5"/>`, stamp: html`<path d="M6.5 8.5V6a1.5 1.5 0 1 1 3 0v2.5M3 8.5h10v2.5H3zM4 13.5h8"/>`,
  back: html`<path d="M10 3.5L5.5 8l4.5 4.5"/>`, next: html`<path d="M6 3.5l4.5 4.5L6 12.5"/>`, q: html`<circle cx="8" cy="8" r="5.5"/><path d="M6.5 6.4a1.6 1.6 0 1 1 2.2 1.5c-.5.2-.7.6-.7 1.1M8 11v.1"/>`,
  glass: html`<path d="M4.5 2.5h7M4.5 13.5h7M5 2.5c0 3 3 3.5 3 5.5s-3 2.5-3 5.5M11 2.5c0 3-3 3.5-3 5.5s3 2.5 3 5.5"/>`,
  bolt: html`<path d="M9 1.8L3.5 9H8l-1 5.2L12.5 7H8z"/>`, user: html`<circle cx="8" cy="5.5" r="2.5"/><path d="M3 13.5c.6-2.5 2.6-3.8 5-3.8s4.4 1.3 5 3.8"/>`,
  send: html`<path d="M2.5 8l11-5-4 11-2-4.5z"/>`, check: html`<path d="M3.5 8.3l2.8 2.7 6-6"/>` }
// Inter as bundled has no slashed zero, so the chip draws its own and keeps the digit for copy and screen readers.
const ZERO = html`<svg class="z" viewBox="0 0 7 10" aria-hidden="true"><ellipse cx="3.5" cy="5" rx="2.55" ry="4.05" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M1.7 7.4L5.3 2.6" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>`
export const Chip = ({ p }) => p == null ? html`<span class="pc pn" title="No priority set">–</span>`
  : html`<span class=${'pc p' + p} title=${`P${p}, ${PRIO[p]}`}>P${p === 0 ? html`${ZERO}<span class="sr">0</span>` : p}</span>`
export const Row = ({ onClick, tile, title, chip, value, pct, note, two, cur }) => html`<button class="trow" onClick=${onClick} aria-current=${cur ? 'true' : null}>
  ${tile}<span class=${'rx' + (two ? ' two' : '')}><span class="t">${chip}<h3>${title}</h3>${value != null ? html`<span class="v num">${value}</span>` : ''}</span>
  ${pct != null ? html`<span class="b"><span class="bar"><i style=${{ width: `${Math.max(0, Math.min(100, pct))}%` }}></i></span><small class="num">${note}</small></span>` : ''}</span></button>`
