// Fleet dashboard app shell: live data, routes, the Linear sidebar and header (phone: title, tabs and dock),
// filters, the ask list, the command palette and keys.
import { render } from './vendor/preact-htm-3.1.1.js'
import { html, useState, useEffect, useRef, now, dur, hm, ACTIVE, STAGES, SNAME, STATES, stuck, state, sid, total, hc, hname, mname, sorted, filterCards, I, IC, StageIcon, Av, ASK_TAG, askType, askOrder } from './ui.js'
import { TABS, inTab, byStage, stagesOf, Board, MobileKanban, Detail } from './board.js'
import { Insights } from './insights.js'
import { Tickets, IC_TICKET, ticketsHead, KindSeg, TicketFilter, proj } from './tickets.js'
import { LABEL, Tile, LIC, Chip, Row } from './look.js'
const IC_CHART = html`<path d="M2.5 13.5h11M4.5 11V8.5M8 11V4.5M11.5 11V7"/>`
const IC_METRICS = html`<path d="M8 2.5a5.5 5.5 0 1 0 5.5 5.5H8z"/><path d="M10 1.8a4.6 4.6 0 0 1 4.2 4.2H10z"/>`

// the views, in nav order, for the phone's pill nav and the desktop sidebar; the epics view slots in as one more entry
const NAV = [['tickets', IC_TICKET, 'Tickets'], ['needs', IC.inbox, 'Needs you'], ['board', IC.board, 'Board'], ['overview', IC_METRICS, 'Metrics'], ['insights', IC_CHART, 'Insights']]

const POLL_MS = 10000, STALE_S = 15 * 60, WIDE = '(min-width: 760px)'

const root = document.documentElement
let saved = null
try { saved = localStorage.getItem('fm-theme') } catch {}
root.dataset.theme = saved || (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark')

// board.json, polled with its ETag so an unchanged fleet costs one empty answer. The first pull is a plain
// fetch, so it takes the copy index.html preloads alongside the scripts.
function useBoard() {
  const [st, set] = useState({ data: null, err: null }), [tick, refresh] = useState(0)
  useEffect(() => {
    let tag = null, alive = true
    async function pull() {
      try {
        const r = await fetch('board.json', tag ? { cache: 'no-cache', headers: { 'If-None-Match': tag } } : {})
        if (r.status === 304) return alive && set(s => ({ ...s, err: null }))
        if (!r.ok) throw new Error(`the dashboard server answered ${r.status}`)
        tag = r.headers.get('ETag')
        const data = await r.json()
        if (alive) set({ data, err: null })
      } catch (e) { if (alive) set(s => ({ ...s, err: e.message || String(e) })) }
    }
    pull()
    const t = setInterval(pull, POLL_MS)
    return () => { alive = false; clearInterval(t) }
  }, [tick])
  return [st, () => refresh(x => x + 1)]
}
// data.json carries what the Overview needs beyond the board: queue reasons, quota and flow history.
function useData(active) {
  const [st, set] = useState({ data: null, err: null })
  useEffect(() => {
    if (!active) return
    let alive = true
    async function pull() {
      try {
        const r = await fetch('data.json', { cache: 'no-store' })
        if (!r.ok) throw new Error(`the dashboard server answered ${r.status}`)
        const data = await r.json()
        if (alive) set({ data, err: null })
      } catch (e) { if (alive) set(s => ({ data: s.data, err: e.message || String(e) })) }
    }
    pull()
    const t = setInterval(pull, POLL_MS)
    return () => { alive = false; clearInterval(t) }
  }, [active])
  return st
}
function useWide() {
  const [w, set] = useState(matchMedia(WIDE).matches)
  useEffect(() => { const m = matchMedia(WIDE), f = () => set(m.matches); m.addEventListener('change', f); return () => m.removeEventListener('change', f) }, [])
  return w
}
function useTick(ms) { const [, set] = useState(0); useEffect(() => { const t = setInterval(() => set(x => x + 1), ms); return () => clearInterval(t) }, []) }

// The view, tab, rows, filters and open card live in the URL hash.
const VIEWS = ['board', 'tickets', 'overview', 'insights', 'needs']
function parseHash() {
  const [path, q] = location.hash.replace(/^#\/?/, '').split('?')
  const p = new URLSearchParams(q || ''), list = k => (p.get(k) || '').split(',').filter(Boolean)
  return { view: VIEWS.includes(path) ? path : 'tickets', tab: TABS.some(([t]) => t === p.get('tab')) ? p.get('tab') : 'active',
    rows: p.get('rows') === 'home' ? 'home' : '', home: list('home'), model: list('model'), state: list('state'), stage: list('stage').filter(s => STAGES.includes(s)),
    project: list('project'), release: list('release'), by: p.get('by') === 'release' ? 'release' : '', card: p.get('card'), ticket: p.get('ticket'), ask: p.get('ask'),
    kind: p.get('kind') === 'system' ? 'system' : '', show: ['todo', 'hold', 'done'].includes(p.get('show')) ? p.get('show') : '',
    order: p.get('order') === 'old' ? 'old' : '', atype: ['yn', 'pick', 'approval'].includes(p.get('atype')) ? p.get('atype') : '' }
}
// An old /overview link lands on the app and opens the native Overview, its address now hash-based.
function initialRoute() {
  const r = parseHash()
  if (location.pathname.replace(/\/+$/, '') === '/overview') { history.replaceState(null, '', '/#/overview'); return { ...r, view: 'overview' } }
  return r
}
function toHash(r) {
  const p = new URLSearchParams()
  if (r.tab !== 'active') p.set('tab', r.tab)
  if (r.rows) p.set('rows', r.rows)
  for (const k of ['home', 'model', 'state', 'stage', 'project', 'release']) if (r[k].length) p.set(k, r[k].join(','))
  if (r.by) p.set('by', r.by)
  if (r.kind) p.set('kind', r.kind); if (r.show) p.set('show', r.show)
  if (r.order) p.set('order', r.order); if (r.atype) p.set('atype', r.atype)
  if (r.card) p.set('card', r.card)
  if (r.ticket) p.set('ticket', r.ticket)
  if (r.ask) p.set('ask', r.ask)
  return `#/${r.view}${p.size ? '?' + p.toString().replace(/%2C/g, ',').replace(/%2F/g, '/') : ''}`
}
function useRoute() {
  const [r, set] = useState(initialRoute)
  useEffect(() => { const f = () => set(parseHash()); addEventListener('hashchange', f); return () => removeEventListener('hashchange', f) }, [])
  return [r, patch => set(cur => { const n = { ...cur, ...patch }; history[patch.view && patch.view !== cur.view ? 'pushState' : 'replaceState'](null, '', toHash(n)); return n })]
}

function Live({ d, st, refresh }) {
  useTick(15000)
  const a = now() - d.generated, bad = st.err || a > STALE_S
  return html`<button class=${'live' + (bad ? ' stale' : '')} onClick=${refresh} title=${st.err ? `Cannot refresh: ${st.err}` : 'Refresh now'}><i></i>${st.err ? 'Cannot refresh' : a < 60 ? 'Live' : `Updated ${dur(a)} ago`}</button>`
}

// The sidebar's foot, as the reference has it: who reads the board and when it was read (UTC); red when the board is
// stale or cannot refresh, and a tap refreshes it.
function Me({ d, st, refresh }) {
  useTick(15000)
  const bad = st.err || now() - d.generated > STALE_S, who = d.owner || 'You'
  return html`<button class=${'me' + (bad ? ' stale' : '')} onClick=${refresh} title=${st.err ? `Cannot refresh: ${st.err}` : 'Refresh now'}><i>${Array.from(who)[0]}</i>
    <span><b>${who}</b>${st.err ? 'Cannot refresh' : `Board read ${new Date(d.generated * 1000).toISOString().slice(11, 16)} UTC`}</span></button>`
}

// One popover for the three filters; on a phone it is a bottom sheet.
function Pop({ label, icon, badge, children }) {
  const [open, setOpen] = useState(false), ref = useRef()
  useEffect(() => { if (!open) return; const f = e => e.key === 'Escape' && setOpen(false); addEventListener('keydown', f); return () => removeEventListener('keydown', f) }, [open])
  return html`<div class="anchor" ref=${ref}><button class=${label ? 'btn' : 'ib'} aria-expanded=${open} aria-label=${label ? null : 'Filter'} onClick=${() => setOpen(!open)}>${I(icon, label ? 14 : 18)}${label}${badge ? html`<b>${badge}</b>` : ''}</button>
    ${open && html`<div class="scrim" onClick=${() => setOpen(false)}></div><div class="pop">${children}</div>`}</div>`
}
const Opt = ({ on, icon, name, n, set }) => html`<button class=${'opt' + (n ? '' : ' dim')} aria-pressed=${on} onClick=${set}><span class="ck">${on ? I(IC.check, 11) : ''}</span>${icon || ''}<span class="lt">${name}</span><small class="num">${n}</small></button>`
function Filters({ d, r, go, label }) {
  const open = d.cards.filter(c => c.stage !== 'landed'), tog = (k, id) => go({ [k]: r[k].includes(id) ? r[k].filter(x => x !== id) : [...r[k], id] })
  const models = [...new Set(d.cards.map(c => c.model || 'none'))]
  const on = r.home.length + r.model.length + r.state.length
  return html`<${Pop} label=${label} icon=${IC.filter} badge=${on || ''}>
    <div class="pop-h">Home</div>${d.homes.map(h => html`<${Opt} on=${r.home.includes(h.id)} icon=${html`<span class="sq" style=${{ '--c': hc(d, h.id) }}></span>`} name=${h.name} n=${total(d, open.filter(c => c.home === h.id).length, 'open', h.id)} set=${() => tog('home', h.id)}/>`)}
    <div class="pop-h">Model</div>${models.map(m => html`<${Opt} on=${r.model.includes(m)} icon=${html`<${Av} m=${m === 'none' ? null : m}/>`} name=${mname(m === 'none' ? null : m, d)} n=${total(d, open.filter(c => (c.model || 'none') === m).length, 'open')} set=${() => tog('model', m)}/>`)}
    <div class="pop-h">State</div>${STATES.map(([id, name]) => html`<${Opt} on=${r.state.includes(id)} name=${name} n=${total(d, open.filter(c => sid(c) === id).length, 'open')} set=${() => tog('state', id)}/>`)}</${Pop}>`
}
function Chips({ d, r, go }) {
  const xs = [...r.home.map(v => ['home', v, 'Home', hname(d, v)]), ...r.model.map(v => ['model', v, 'Model', mname(v === 'none' ? null : v, d)]),
    ...r.state.map(v => ['state', v, 'State', STATES.find(s => s[0] === v)?.[1] || v]), ...r.stage.map(v => ['stage', v, 'Stage', SNAME[v]])]
  return xs.length ? html`<div class="chips">${xs.map(([k, v, n, w]) => html`<span class="chip">${n} is <b>${w}</b><button aria-label=${`Remove ${w}`} onClick=${() => go({ [k]: r[k].filter(x => x !== v) })}>${I(IC.x, 12)}</button></span>`)}</div>` : ''
}

// Needs you is the ask list and nothing else: a hero with how many questions wait, then one row per question with its
// type, its age and an Open link to answer it where it was asked; the order and the type sit in the filter sheet.
const ASK_IC = { yn: IC.check, pick: LIC.list, approval: LIC.stamp }, ASK_WORD = { yn: 'Yes or no', pick: 'Pick one', approval: 'Approval' }
function NeedsFilter({ r, go, label }) {
  const [open, setOpen] = useState(false), opt = (k, v, n) => html`<button class="opt" aria-pressed=${(r[k] || '') === v} onClick=${() => go({ [k]: v })}><span class="ck">${(r[k] || '') === v ? I(IC.check, 11) : ''}</span><span class="lt">${n}</span></button>`
  return html`<div class="anchor"><button class=${label ? 'btn' : 'ib'} aria-expanded=${open} aria-label="Filters" onClick=${() => setOpen(!open)}>${I(IC.filter, label ? 16 : 20)}${label}${r.order || r.atype ? html`<b>${!!r.order + !!r.atype}</b>` : ''}</button>
    ${open && html`<div class="scrim" onClick=${() => setOpen(false)}></div><div class="pop"><div class="pop-h">Order</div>${opt('order', '', 'Newest first')}${opt('order', 'old', 'Oldest first')}
      <div class="pop-h">Type</div>${[['', 'All'], ['yn', 'Yes/no'], ['pick', 'Pick'], ['approval', 'Approval']].map(([k, n]) => opt('atype', k, n))}</div>`}</div>`
}
const asked = (d, a) => a.age == null ? 'Time asked not recorded' : `Asked ${dur(a.age + Math.max(0, now() - d.generated))} ago`
// A question on its own page, like a photo in a gallery: a swipe on a phone, the arrows or J/K (and the arrow keys) on a
// computer move through the questions in the order and type the list shows, with the position in the header; the ends stop.
function AskPage({ d, list, id, go, wide }) {
  const at = list.findIndex(a => a.id === id), a = list[at], ref = useRef(), x0 = useRef(null)
  const step = k => { const n = list[at + k]; if (n) go({ ask: n.id }) }, close = () => go({ ask: null })
  useEffect(() => {
    ref.current?.focus()
    const f = e => { if (e.target.closest?.('input, textarea') || e.metaKey || e.ctrlKey || e.altKey) return
      const k = { Escape: 0, j: 1, ArrowRight: 1, ArrowDown: 1, k: -1, ArrowLeft: -1, ArrowUp: -1 }[e.key]
      if (k === 0) close(); else if (k) { e.preventDefault(); step(k) } }
    addEventListener('keydown', f); return () => removeEventListener('keydown', f)
  }, [id, list])
  if (!a) return null
  const touch = { ontouchstart: e => { const t = e.changedTouches[0]; x0.current = [t.clientX, t.clientY] },
    ontouchend: e => { const t = e.changedTouches[0], [x, y] = x0.current || [t.clientX, t.clientY], dx = t.clientX - x
      if (Math.abs(dx) > 60 && Math.abs(dx) > Math.abs(t.clientY - y)) step(dx < 0 ? 1 : -1) } }
  const nav = html`<span class="pos num" aria-live="polite">${at + 1} of ${list.length}</span>
    <button class="ib" disabled=${at <= 0} onClick=${() => step(-1)} aria-label="Previous question" title=${at <= 0 ? 'This is the first question' : 'Previous (K)'}>${I(LIC.back, 20)}</button>
    <button class="ib" disabled=${at >= list.length - 1} onClick=${() => step(1)} aria-label="Next question" title=${at >= list.length - 1 ? 'This is the last question' : 'Next (J)'}>${I(LIC.next, 20)}</button>`
  const body = html`<section class="soft hero"><div class="ahd"><span class="tch">${ASK_WORD[a.kind]}</span><small>${asked(d, a)}</small></div><h2>${a.text}</h2></section>
    ${a.why ? html`<section class="soft words"><label>${I(LIC.q, 16)}Why it is asked</label><p>${a.why}</p></section>` : ''}
    ${a.options?.length ? html`<section class="soft words"><label>${I(LIC.list, 16)}Answers</label><div class="opts">${a.options.map(o => html`<span class=${o === a.default ? 'on' : ''}>${o}${o === a.default ? ' · suggested' : ''}</span>`)}</div></section>` : ''}
    ${a.url ? html`<a class="gbtn" href=${a.url} target="_blank" rel="noreferrer">${I(IC.inbox, 16)}Answer where it was asked</a>` : html`<p class="note">Answer Main where it asked you.</p>`}`
  return html`<aside class=${'tpage ask' + (wide ? ' wide' : '')} role="dialog" aria-label=${a.text} tabindex="-1" ref=${ref} ...${touch}>
    ${wide ? html`<div class="crumbs">${LABEL()}<span>›</span><a onClick=${close}>Needs you</a><span>›</span>Question<span class="sp"></span>${nav}</div><div class="tcol">${body}</div>`
      : html`<div class="tbar"><button class="ib" onClick=${close} aria-label="Close">${I(IC.x, 20)}</button><b>Question</b>${nav}</div>${body}`}</aside>`
}
const Needs = ({ d, r, go, wide }) => {
  if (d.asks == null) return html`<div class="none"><p>The ask list could not be read.</p></div>`
  if (!d.asks.length) return html`<div class="none">${I(IC.inbox, 32)}<p>Nothing needs you.</p></div>`
  const all = d.asks.map(a => ({ ...a, kind: askType(a.text, a.type) })), shown = askOrder(all, r.order !== 'old').map(a => ({ ...a, kind: askType(a.text, a.type) })).filter(a => !r.atype || a.kind === r.atype)
  const hero = html`<section class="soft hero"><div class="h"><div class="sp"><label>Questions waiting on you</label><div class="big num">${d.asks.length}</div></div>
    <div class="hside">${Object.entries(ASK_WORD).filter(([k]) => all.some(a => a.kind === k)).map(([k, n]) => html`<span class="delta num">${all.filter(a => a.kind === k).length} ${n.toLowerCase()}</span>`)}</div></div></section>`
  const list = html`<div class="grp">${shown.map(a => html`<div class="trow" role="button" tabindex="0" onClick=${() => go({ ask: a.id })} onKeyDown=${e => e.key === 'Enter' && go({ ask: a.id })}><span class="tile">${I(ASK_IC[a.kind], 20)}</span><span class="rx two"><span class="t"><h3>${a.text}</h3><span class="tch">${ASK_WORD[a.kind]}</span></span>
    <span class="m"><span>${asked(d, a)}</span>${a.url ? html`<a href=${a.url} target="_blank" rel="noreferrer" onClick=${e => e.stopPropagation()}>Open ›</a>` : ''}</span></span></div>`)}${!shown.length ? html`<p class="empty">Nothing of this type waits on you</p>` : ''}</div>`
  const name = html`<h2>Questions</h2><small class="num">${shown.length}</small><span class="all">${r.order === 'old' ? 'Oldest first' : 'Newest first'}</span>`
  const page = r.ask && html`<${AskPage} d=${d} list=${shown} id=${r.ask} go=${go} wide=${wide}/>`
  return wide ? html`<div class="kgrid" style="margin-top:0"><section class="soft k8"><div class="lhd">${name}</div>${list}</section><div class="k4">${hero}</div></div>${page}`
    : html`<div class="ph">${hero}<div class="lh">${name}</div><div class="soft">${list}</div></div>${page}`
}

// Overview: the fleet's numbers as charts - each figure with its trend, the lifecycle as a rail of stages,
// colour that means something (stage colours for work in motion, orange and red only where it waits or is stuck).
const QTONE = ['--green', '--orange', '--accent', '--grey', '--grey']
const OV_STATES = [['building', 'Building', ''], ['validating', 'Validating or CI', 'v'], ['finished', 'Finished, not landed', 'f'],
  ['waiting', 'Waiting', 'w'], ['decision', 'On a decision', 'd'], ['blocked', 'Blocked', 'b']]
const sum = v => Object.values(v || {}).reduce((a, b) => a + (b || 0), 0)
const ts = v => typeof v === 'number' ? v : typeof v === 'string' ? Date.parse(v) / 1000 : null
const sign = n => n > 0 ? `+${n}` : `${n}`
// A day's trend from the 10-minute samples: the line, and the change since the sample nearest 24 hours ago.
function trend(hist, key, v) {
  const t = now(), day = (hist || []).filter(x => x.at >= t - 90000 && x[key] != null)
  if (day.length < 2 || v == null) return {}
  const ago = day.reduce((a, b) => Math.abs(b.at - (t - 86400)) < Math.abs(a.at - (t - 86400)) ? b : a)
  return { line: [...day.map(x => x[key]), v], delta: Math.abs(ago.at - (t - 86400)) < 7200 ? v - ago[key] : null }
}
function Line({ vals, c }) {
  const top = Math.max(1, ...vals), lo = Math.min(...vals), span = Math.max(1, top - lo), dx = 100 / Math.max(1, vals.length - 1)
  const pts = vals.map((v, k) => `${(k * dx).toFixed(1)},${(26 - (v - lo) / span * 22).toFixed(1)}`).join(' ')
  return html`<svg class="ov-line" viewBox="0 0 100 28" preserveAspectRatio="none" aria-hidden="true" style=${{ color: `var(${c})` }}>
    <polygon points=${`0,28 ${pts} 100,28`} fill="currentColor" fill-opacity=".12"/><polyline points=${pts} fill="none" stroke="currentColor" stroke-width="1.6" vector-effect="non-scaling-stroke" stroke-linejoin="round"/></svg>`
}
function Kpi({ name, v, sub, c, t, good, href, onClick, src }) {
  const tag = href ? 'a' : onClick ? 'button' : 'div', d = t?.delta
  const dc = !d || !good ? '' : (d > 0) === (good === 'up') ? 'up' : 'dn'
  return html`<${tag} class="ov-kpi" href=${href} onClick=${onClick} title=${src && `Source: ${src}`} style=${{ '--c': `var(${c})` }}>
    <span><i></i>${name}${d != null ? html`<em class=${'num ' + dc} title="change since this time yesterday">${d ? sign(d) : '±0'}</em>` : ''}</span>
    <b class="num">${v}${sub ? html`<small>${sub}</small>` : ''}</b>${t?.line ? html`<${Line} vals=${t.line} c=${c}/>` : html`<div class="ov-line"></div>`}</${tag}>`
}
// 14 days of a daily count: today in the accent, earlier days muted, the period average dashed; marks, when given,
// marks another count of the same days (GitHub's merges beside the recorded ones) as a tick on each bar.
function Days({ rows, c, label, marks }) {
  if (!rows?.length) return html`<p class="ov-tot">No days on record</p>`
  const known = rows.filter(r => r.value != null), top = Math.max(1, ...known.map(r => r.value), ...(marks || []).map(r => r.value || 0)), w = 100 / rows.length
  const prior = rows.slice(0, -1).filter(r => r.value != null), avg = prior.length ? prior.reduce((a, r) => a + r.value, 0) / prior.length : null
  const day = s => new Date(`${s}T12:00:00`).toLocaleDateString([], { day: 'numeric', month: 'short' })
  return html`<div class="ov-days" style=${{ '--c': `var(${c})` }}><svg viewBox="0 0 100 60" preserveAspectRatio="none" role="img" aria-label=${`${label}, last ${rows.length} days`}>
    ${rows.map((r, k) => { if (r.value == null) return ''; const h = r.value / top * 56; return html`<rect class=${k === rows.length - 1 ? 'now' : ''} x=${(k * w + w * .14).toFixed(2)} y=${(60 - h).toFixed(2)} width=${(w * .72).toFixed(2)} height=${Math.max(.5, h).toFixed(2)} rx=".6"><title>${day(r.day)}: ${r.value}</title></rect>` })}
    ${(marks || []).map((r, k) => !r.value ? '' : html`<rect class="ref" x=${(k * w + w * .06).toFixed(2)} y=${(60 - r.value / top * 56 - .6).toFixed(2)} width=${(w * .88).toFixed(2)} height="1.2"><title>${day(r.day)}: ${r.value} on GitHub</title></rect>`)}
    ${avg != null ? html`<line x1="0" x2="100" y1=${(60 - avg / top * 56).toFixed(2)} y2=${(60 - avg / top * 56).toFixed(2)} vector-effect="non-scaling-stroke"/>` : ''}</svg>
    <div class="ov-axis"><span>${day(rows[0].day)}</span><span>today</span></div><small>${avg != null ? `avg ${Math.round(avg)} a day before today` : 'no known days to average'}</small></div>`
}
// GitHub's merges in the fleet's repositories beside the recorded ones: today, the average of the days before today
// (the same days as the recorded average) and how many of GitHub's merges the records hold.
function Forge({ m }) {
  const f = m.landed_forge
  if (!f) return ''
  if (f.status === 'unknown') return html`<small class="ov-fg bad">GitHub merges unknown: ${f.reason}</small>`
  const days = (f.daily || []).slice(0, -1).map((x, k) => [m.landed?.daily?.[k]?.value, x.value]).filter(([r, g]) => r != null && g != null)
  const rec = days.reduce((n, [r]) => n + r, 0), gh = days.reduce((n, [, g]) => n + g, 0)
  return html`<small class="ov-fg" title=${`${f.repos?.length} repositories: ${(f.repos || []).join(', ')}`}><i></i>GitHub ${f.value} today · avg ${days.length ? Math.round(gh / days.length) : '–'} a day before today ·
    records hold ${gh ? `${Math.round(rec / gh * 1000) / 10}%` : '–'} (${rec} of ${gh}) in ${f.repos?.length} ${f.repos?.length === 1 ? 'repository' : 'repositories'}${f.status === 'partial' ? html` · <span class="bad">${f.reason}</span>` : ''}</small>`
}
// The lifecycle rail: every open lane by stage, split into moving, waiting and stuck, then today's landings.
function Rail({ d, go }) {
  const cs = d.cards, col = s => cs.filter(c => c.stage === s)
  const top = Math.max(1, ...ACTIVE.map(s => col(s).length))
  return html`<div class="ov-rail">${[...ACTIVE, 'landed'].map(s => {
    const xs = col(s), n = xs.length, st = xs.filter(stuck).length, wt = xs.filter(c => c.wait && !stuck(c)).length
    const old = s === 'landed' ? null : Math.max(0, ...xs.map(c => c.since ? now() - c.since : 0))
    return html`<button class="ov-stage" key=${s} style=${{ '--c': `var(--st-${s})` }} onClick=${() => go({ view: 'board', tab: s === 'landed' ? 'landed' : 'active', stage: s === 'landed' ? [] : [s], state: [], card: null })}>
      <span class="ov-sh"><${StageIcon} s=${s}/>${SNAME[s]}</span><b class="num">${s === 'landed' ? total(d, n, 'landed') : n}</b>
      ${s === 'landed' ? html`<span class="ov-sbar done"></span>` : html`<span class="ov-sbar"><i style=${{ width: `${(n - st - wt) / top * 100}%` }}></i><i class="w" style=${{ width: `${wt / top * 100}%` }}></i><i class="s" style=${{ width: `${st / top * 100}%` }}></i></span>`}
      <small>${s === 'landed' ? 'merged today' : !n ? 'empty' : [st && html`<em class="s">${st} stuck</em>`, wt && `${wt} waiting`, old > 60 && `oldest ${dur(old)}`].filter(Boolean).flatMap((p, k) => k ? [' · ', p] : [p])}</small></button>` })}</div>`
}
// Memory as the memory gate reads it: free memory and the sustained pressure (the lower of the 10 s and 60 s averages),
// each against the line where heavy jobs wait, and the watcher's peak over the last hour.
function Memory({ m, q }) {
  const free = m.free_memory_gb?.value, all = m.total_memory_gb?.value, psi = m.memory_pressure?.value, peak = q.machine?.peak, lim = q.machine_limits || {}
  const tone = v => v == null ? '--grey' : v >= lim.memory_pressure ? '--red' : v >= lim.memory_pressure / 2 ? '--orange' : '--green'
  const pct = v => v == null ? '–' : `${v < 10 ? v.toFixed(1) : Math.round(v)}%`
  const row = (name, frac, c, value) => html`<div class="ov-qrow"><span>${name}</span><span class=${'ov-bar' + (frac == null ? ' unk' : '')}><i style=${{ width: `${frac == null ? 0 : Math.max(2, Math.min(100, frac * 100))}%`, background: `var(${c})` }}></i></span><b class="num">${value}</b></div>`
  return html`<div class="ov-ql">${row(all ? `Free of ${Math.round(all)} GB` : 'Free', free != null && all ? free / all : null, free != null && free < lim.min_memory_gb ? '--red' : '--green', free == null ? '–' : `${Math.round(free)} GB`)}
    ${row('Pressure', psi == null ? null : psi / 100, tone(psi), pct(psi))}${row('Peak, last hour', peak == null ? null : peak / 100, tone(peak), pct(peak))}</div>
    <p class="ov-tot">Pressure is the lower of the 10 s and 60 s averages, as the memory gate reads it; heavy jobs wait below ${lim.min_memory_gb} GB free or at ${lim.memory_pressure}%</p>`
}
// Time in stage: each open lane as a dot at its time in its current stage, counted from the status line that
// entered the stage (log scale), one row per stage with its median. The bottleneck is the stage holding the most
// lane-hours now, leaving out lanes the captain holds on purpose. A row opens the Board filtered to its stage.
const AGE_TICKS = [[3600, '1h'], [21600, '6h'], [86400, '1d'], [259200, '3d'], [604800, '7d'], [2592000, '30d']]
const short = a => a < 3600 ? `${Math.floor(a / 60)}m` : a < 86400 ? `${Math.round(a / 3600)}h` : `${Math.round(a / 86400)}d`
function Aging({ d, go }) {
  const t = now(), open = d.cards.filter(c => ACTIVE.includes(c.stage)), untimed = open.filter(c => !c.since).length
  const rows = ACTIVE.map(s => { const xs = open.filter(c => c.stage === s && c.since).map(c => ({ c, a: Math.max(60, t - c.since) })).sort((x, y) => x.a - y.a)
    const live = xs.filter(x => x.c.wait !== 'parked')
    return { s, xs, live, sum: live.reduce((n, x) => n + x.a, 0), med: xs.length ? xs[(xs.length - 1) >> 1].a : null } })
  const top = rows.reduce((a, b) => b.sum > a.sum ? b : a), max = Math.max(604800, ...open.filter(c => c.since).map(c => t - c.since))
  const f = a => Math.log(a / 60) / Math.log(max / 60) * 100, x = a => `${f(a).toFixed(1)}%`
  const ticks = AGE_TICKS.filter(([v]) => v <= max).reduce((k, tk) => !k.length || f(tk[0]) - f(k.at(-1)[0]) >= 14 ? [...k, tk] : k, [])  // labels never crowd
  const tone = c => stuck(c) ? 'var(--red)' : c.wait === 'parked' ? 'var(--grey)' : c.wait ? 'var(--orange)' : `var(--st-${c.stage})`
  return html`${top.sum ? html`<p class="ov-tot">Bottleneck now: <b>${SNAME[top.s]}</b> · ${top.live.length} ${top.live.length === 1 ? 'lane' : 'lanes'} not on hold · oldest ${dur(top.live.at(-1).a)} · ${Math.round(top.sum / 3600)} lane-hours</p>`
      : html`<p class="ov-tot">No open lane has a recorded stage time</p>`}
    <div class="ov-age">${rows.map(r => html`<button key=${r.s} class=${'ov-arow' + (r === top && r.sum ? ' ov-abn' : '')} onClick=${() => go({ view: 'board', tab: 'active', stage: [r.s], state: [], card: null })}>
      <span><${StageIcon} s=${r.s}/>${SNAME[r.s]}</span><span class="ov-atrack">${r.xs.map(({ c, a }) => html`<i key=${c.id} style=${{ left: x(a), background: tone(c) }} title=${`${c.title}: ${dur(a)} in ${SNAME[r.s]}`}></i>`)}
        ${r.med ? html`<b style=${{ left: x(r.med) }} title=${`median ${dur(r.med)}`}></b>` : ''}</span><small class="num" title=${r.med ? `median ${dur(r.med)}` : ''}>${r.med ? short(r.med) : '–'}</small></button>`)}
      <div class="ov-arow ov-aaxis"><span></span><span class="ov-atrack">${ticks.map(([v, n]) => html`<em key=${n} style=${{ left: x(v) }}>${n}</em>`)}</span><small>median</small></div></div>
    <p class="ov-tot">Stage colour moving · orange waiting · red stuck · grey on hold, not counted in the bottleneck${untimed ? ` · ${untimed} open ${untimed === 1 ? 'lane has' : 'lanes have'} no recorded stage time` : ''}</p>`
}
// Every figure names the records it is computed from: on hover, and as a footnote under its card.
const Src = ({ m, ids, text }) => html`<p class="ov-src" title=${ids?.map(i => m[i]?.window).find(Boolean) || ''}>Source: ${(text || [...new Set(ids.map(i => m[i]?.source).filter(Boolean))].join(' · ') || 'not recorded').replace(/\s*~?\/[\w./-]+/g, '')}</p>`
function Overview({ d, od, go }) {
  const q = od.data
  if (!q) return html`<div class="ov"><div class="none"><p>${od.err ? `Cannot load the overview: ${od.err}` : 'Loading the overview…'}</p></div></div>`
  const m = q.metrics, asks = d.asks, openCards = d.cards.filter(c => ACTIVE.includes(c.stage)), hist = q.lane_history
  const stk = openCards.filter(stuck).length, toLand = openCards.filter(c => c.stage === 'merge').length
  const states = m.lane_states?.value
  const qr = q.queue_reasons || [], qOk = m.queue?.value != null, qTop = Math.max(1, ...qr.map(x => sum(x.by_home)))
  const flow = (mid, label, foot, c) => { const r = m[mid]; return html`<div class="ov-flow"><span>${label}</span>
    <b class="num">${r?.status === 'unknown' ? 'unknown' : `${r?.status === 'lower_bound' && mid === 'landed' ? '≥' : ''}${r?.value ?? '–'}`}</b><small>${foot}</small>
    <${Days} rows=${r?.daily} c=${c} label=${label} marks=${mid === 'landed' ? m.landed_forge?.daily : null}/>${mid === 'landed' ? html`<${Forge} m=${m}/>` : ''}</div>` }
  return html`<div class="ov">
    ${od.err ? html`<p class="ov-tot"><span class="bad">Refresh failed: ${od.err}</span></p>` : ''}
    <div class="ov-kpis">
      <${Kpi} name="Needs you" v=${asks == null ? '?' : asks.length} c=${asks?.length ? '--orange' : '--green'} href="#/needs" src=${m.asks?.source}/>
      <${Kpi} name="Stuck" v=${stk} c=${stk ? '--red' : '--green'} t=${trend(hist, 'stuck', stk)} good="down" src=${m.stuck?.source} onClick=${() => go({ view: 'board', tab: 'active', state: ['blocked', 'decision'], stage: [], card: null })}/>
      <${Kpi} name="To land" v=${toLand} c="--st-merge" src=${m.lanes?.source} onClick=${() => go({ view: 'board', tab: 'active', stage: ['merge'], state: [], card: null })}/>
      <${Kpi} name="Lanes open" v=${m.lanes?.value ?? '–'} sub=${` of ${m.lane_plan?.value ?? '–'}`} c="--accent" t=${trend(hist, 'lanes', m.lanes?.value)} good="up" src=${m.lanes?.source}/>
      <${Kpi} name="Ready" v=${m.ready?.value ?? '–'} c="--h-2" t=${trend(hist, 'ready', m.ready?.value)} src=${m.ready?.source}/>
    </div><${Src} m=${m} text=${`Needs you: ${m.asks?.source || 'not recorded'} · Stuck, To land, Lanes open: ${m.lanes?.source || 'not recorded'} · Ready: ${m.ready?.source || 'not recorded'}`}/>
    <div class="ov-grid">
      ${asks?.length ? html`<section class="ov-card wide"><h3>Needs you</h3><div class="ov-asks">${askOrder(asks).map((a, k) =>
        html`<a class="ov-ask" key=${k} href=${a.url || '#/needs'} target=${a.url ? '_blank' : null} rel="noreferrer"><span><em class="ktag">${ASK_TAG[askType(a.text, a.type)]}</em>${a.text}</span><small class="num">${a.age == null ? '' : dur(a.age)}</small></a>`)}</div></section>` : ''}
      <section class="ov-card wide"><h3>Lifecycle</h3><${Rail} d=${d} go=${go}/><${Src} m=${m} ids=${['lanes', 'landed']}/></section>
      <section class="ov-card wide"><h3>Time in stage</h3><${Aging} d=${d} go=${go}/><${Src} m=${m} ids=${['lanes']}/></section>
      <section class="ov-card w2"><h3>Flow</h3><div class="ov-flows">${flow('landed', 'Landed today', 'recorded merges', '--st-landed')}${flow('closed', 'Closed 7 d', 'backlog items', '--green')}</div><${Src} m=${m} ids=${['landed', 'landed_forge', 'closed']}/></section>
      <section class="ov-card w1"><h3>Lanes by state</h3>
        <div class="ov-bar tall">${states ? OV_STATES.map(([k, , c]) => states[k] ? html`<i class=${c} key=${k} style=${{ flex: states[k] }}></i>` : '') : ''}</div>
        <div class="ov-legend">${OV_STATES.map(([k, nm, c]) => html`<span key=${k}><i class=${c}></i>${nm}<b class="num">${states ? states[k] : '–'}</b></span>`)}</div><${Src} m=${m} ids=${['lane_states']}/></section>
      <section class="ov-card w1"><h3>Why work is queued</h3>
        <div class="ov-ql">${qr.map((x, k) => { const n = sum(x.by_home); return html`<div class="ov-qrow" key=${k}><span>${x.reason}</span>
          <span class="ov-bar">${qOk && n > 0 ? html`<i style=${{ width: `${n / qTop * 100}%`, background: `var(${QTONE[k] || '--grey'})` }}></i>` : ''}</span><b class="num">${qOk ? n : '–'}</b></div>` })}</div>
        <p class="ov-tot">Total <b class="num">${qOk ? sum(m.queue.value) : '–'}</b> queued</p><${Src} m=${m} ids=${['queue']}/></section>
      <section class="ov-card w1"><h3>Memory</h3><${Memory} m=${m} q=${q}/><${Src} m=${m} ids=${['memory_pressure']}/></section>
      ${q.claude_accounts?.length ? html`<section class="ov-card wide"><h3>Claude accounts</h3><div class="ov-ql ov-quota ov-ca">${q.claude_accounts.map((a, k) => html`<div key=${k}><b class="ov-can">${a.name}<span class="ov-cload">${a.workers ? `${a.workers} worker${a.workers > 1 ? 's' : ''}` : 'no workers'}</span></b>
        ${[['5 h', a.five_hour], ['7 d', a.seven_day]].map(([nm, w]) => { const left = w?.left, tone = left == null ? 'mut' : left <= 10 ? 'bad' : left <= 25 ? 'warn' : ''
          return html`<div class="ov-qrow" key=${nm}><span>${nm}</span><span class=${'ov-bar ' + (left == null ? 'unk' : '')}><i style=${{ width: `${left == null ? 0 : Math.max(2, Math.min(100, 100 - left))}%`,
            background: `var(${{ bad: '--red', warn: '--orange', mut: '--grey' }[tone] || '--green'})` }}></i></span><b class=${'num ' + tone}>${left == null ? '–' : `${Math.round(left)}% left`}</b></div>` })}
        ${a.problem ? html`<small class="ov-qsub mut">${a.problem}</small>` : ''}</div>`)}</div><${Src} m=${m} text="the claude-accounts add-on's account readings"/></section>` : ''}
      <section class="ov-card wide"><h3>Quota runway</h3><div class="ov-ql ov-quota">${(q.quota_accounts || []).map((a, k) => {
        const w = a.limit || (a.windows || []).filter(x => x.used != null).sort((x, y) => y.used - x.used)[0]
        const tone = a.empty ? 'bad' : a.problem ? 'mut' : a.status === 'projected_exhaustion' ? 'warn' : ''
        const right = a.empty ? 'used up' : a.problem ? 'unknown' : a.runout ? `out in ${dur(ts(a.runout) - now())}` : w?.reset ? `resets ${hm(ts(w.reset))}` : 'lasts'
        return html`<div key=${k}><div class="ov-qrow"><span>${a.name}</span><span class=${'ov-bar ' + (w?.used == null ? 'unk' : '')}><i style=${{ width: `${w?.used != null ? Math.max(2, Math.min(100, w.used)) : 0}%`,
          background: `var(${{ bad: '--red', warn: '--orange', mut: '--grey' }[tone] || '--green'})` }}></i></span>
          <b class="num ${tone}">${w?.used != null ? `${Math.round(w.used)}%` : '–'}</b></div><small class="ov-qsub ${tone}">${right}</small></div>` })}</div>
        ${!q.quota_accounts?.length ? html`<p class="ov-tot">No account reported a window</p>` : ''}<${Src} m=${m} ids=${['quota']}/></section>
      <section class="ov-card wide"><h3>Homes</h3><div class="ov-homes">${(q.homes || []).map(h => {
        const n = h.lanes?.value, xs = openCards.filter(c => c.home === h.home), cap = Math.max(h.plan || 0, n || 0, 1)
        return html`<button class="ov-hrow" key=${h.home} onClick=${() => go({ view: 'board', tab: 'active', home: [h.home], card: null })}>
        <span class="sq" style=${{ '--c': hc(d, h.home) }}></span><b>${hname(d, h.home)}</b>
        <span class="ov-load" title=${`${n ?? '?'} of ${h.plan} lanes`}>${ACTIVE.map(s => { const k = xs.filter(c => c.stage === s).length; return k ? html`<i key=${s} style=${{ width: `${k / cap * 100}%`, background: `var(--st-${s})` }}></i>` : '' })}</span>
        <span class="num">${h.lanes?.status === 'unknown' ? '?' : n ?? '–'}<small> of ${h.plan}</small></span>
        <span class="num">${h.ready?.value ?? '–'}<small> ready</small></span>
        <span class="num">${h.closed?.status === 'unknown' ? '–' : h.closed?.value}<small> closed</small></span></button>` })}</div><${Src} m=${m} ids=${['lanes', 'ready', 'closed']}/></section>
      <section class="ov-card wide"><h3>Recently landed</h3><div class="ov-merges">${(q.recent_merges || []).map((x, k) =>
        html`<div class="ov-mrow" key=${k}><${StageIcon} s="landed"/><a href=${x.url} target="_blank" rel="noreferrer">${x.title}</a><span><span class="sq" style=${{ '--c': hc(d, x.home) }}></span>${hname(d, x.home)}</span><small class="num">${hm(x.at)}</small></div>`)}
        ${!q.recent_merges?.length ? html`<p class="ov-tot">No merge on record</p>` : ''}</div><${Src} m=${m} ids=${['landed']}/></section>
    </div></div>`
}

// Search, as the reference has it: a pill, then what matches by group (views, open tickets by priority, lanes in
// flight, homes), three of each until you type; arrows and Enter pick one.
function Palette({ d, go, close }) {
  const [q, setQ] = useState(''), [i, setI] = useState(0), input = useRef(), wide = innerWidth >= 760
  useEffect(() => input.current?.focus(), [])  // autofocus is ignored while a card holds focus
  const ql = q.toLowerCase(), hit = s => !ql || s.toLowerCase().includes(ql), n = k => ql ? k : 3, tp = Object.fromEntries((d.tickets || []).map(t => [t.id, t.priority]))
  const hits = [
    ['Go to', NAV.filter(([, , t]) => hit(t)).map(([v, ic, t]) => ({ t, tile: html`<span class="tile">${I(ic, 20)}</span>`, run: () => go({ view: v, card: null, ticket: null }) }))],
    ['Tickets', (d.tickets || []).filter(t => t.state !== 'done' && hit(t.title)).sort((a, b) => (a.priority ?? 9) - (b.priority ?? 9)).slice(0, n(8))
      .map(t => ({ t: t.title, p: t.priority, tile: html`<${Tile} d=${d} name=${proj(d, t)}/>`, run: () => go({ view: 'tickets', ticket: t.id, card: null }) }))],
    ['Lanes', ACTIVE.flatMap(s => sorted(d.cards.filter(c => c.stage === s))).filter(c => hit(c.title)).slice(0, n(8))
      .map(c => ({ t: c.title, p: tp[c.id], tile: html`<${Tile} d=${d} name=${c.home}/>`, run: () => go({ view: 'board', card: c.id, ticket: null }) }))],
    ['Homes', d.homes.filter(h => hit(h.name)).slice(0, n(12)).map(h => ({ t: h.name, tile: html`<${Tile} d=${d} name=${h.id}/>`, run: () => go({ view: 'board', home: [h.id], card: null, ticket: null }) }))],
  ].filter(([, xs]) => xs.length)
  const flat = hits.flatMap(([, xs]) => xs), pick = a => { a.run(); close() }
  const key = e => {
    if (e.key === 'ArrowDown') { e.preventDefault(); setI(Math.min(i + 1, flat.length - 1)) }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setI(Math.max(i - 1, 0)) }
    else if (e.key === 'Enter' && flat[i]) pick(flat[i])
  }
  useEffect(() => document.querySelector('.pal [aria-current=true]')?.scrollIntoView({ block: 'nearest' }), [i])
  let k = -1
  return html`<div class="scrim dim" onClick=${close}></div><div class="pal" role="dialog" aria-label="Search and jump">
    <div class="in">${I(IC.search, 20)}<input ref=${input} placeholder="Search tickets, lanes, homes, views" value=${q} onInput=${e => { setQ(e.target.value); setI(0) }} onKeyDown=${key}/>
      <button class="ib" onClick=${close} aria-label="Close">${I(IC.x, 16)}</button></div>
    <div class="res">${hits.map(([g, xs]) => html`<div class="lh"><h2>${g}</h2></div><div class="soft grp">${xs.map(a => { const j = ++k
      return html`<${Row} onClick=${() => pick(a)} cur=${wide && i === j} tile=${a.tile} chip=${a.p !== undefined && html`<${Chip} p=${a.p}/>`} title=${a.t} value=${i === j && wide ? html`<kbd>Enter</kbd>` : null}/>` })}</div>`)}
      ${!flat.length && html`<p class="empty">Nothing matches “${q}”</p>`}</div></div>`
}
const KEYS = [['⌘K or /', 'Search and jump'], ['G then B, T, N', 'Board, Tickets, Needs you'], ['H J K L or arrows', 'Move between cards'], ['Enter', 'Open the card'],
  ['J K in a card', 'Next and previous lane'], ['Esc', 'Close'], ['⇧G', 'Rows by home on or off'], ['T', 'Light or dark theme'], ['?', 'This list']]
function Shortcuts({ close }) {
  const ref = useRef(); useEffect(() => ref.current?.focus(), [])
  return html`<div class="scrim dim" onClick=${close}></div><div class="pal" role="dialog" aria-label="Keyboard shortcuts" tabindex="-1" ref=${ref}>
  <div class="pop-h" style="padding:14px 16px 8px">Keyboard shortcuts</div><dl class="keys">${KEYS.map(([k, v]) => html`<dt><kbd>${k}</kbd></dt><dd>${v}</dd>`)}</dl></div>`
}
// Board keys move on a grid: up and down inside a column, left and right across columns.
function moveFocus(dx, dy) {
  const cols = [...document.querySelectorAll('.col')].map(p => [...p.querySelectorAll('[data-card]')]).filter(p => p.length)
  const a = document.activeElement
  let ci = cols.findIndex(p => p.includes(a)), ri = ci < 0 ? -1 : cols[ci].indexOf(a)
  if (ci < 0) return cols[0]?.[0]?.focus()
  if (dx) { ci = Math.max(0, Math.min(cols.length - 1, ci + dx)); ri = Math.min(ri, cols[ci].length - 1) } else ri = Math.max(0, Math.min(cols[ci].length - 1, ri + dy))
  cols[ci][ri].focus(); cols[ci][ri].scrollIntoView({ block: 'nearest', inline: 'nearest' })
}
function useKeys(r, go, setPal, setKeys, toggleTheme, pal, keys) {
  const overlay = useRef(); overlay.current = [pal, keys]
  useEffect(() => {
    let g = false
    const f = e => {
      const [pal, keys] = overlay.current
      if (pal || keys) { if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); keys ? setKeys(false) : setPal(false) } return }
      if (e.target.closest?.('input') || e.altKey) return
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') { e.preventDefault(); return setPal(true) }
      if (e.metaKey || e.ctrlKey) return
      if (e.key === '/') { e.preventDefault(); return setPal(true) }
      if (e.key === '?') return setKeys(true)
      if (g) { g = false; const v = { b: 'board', t: 'tickets', n: 'needs' }[e.key]; if (v) go({ view: v, card: null }); return }
      if (e.key === 'g') { g = true; setTimeout(() => g = false, 900); return }
      if (e.key === 'G') return go({ view: 'board', rows: r.rows ? '' : 'home' })
      if (e.key === 't') return toggleTheme()
      if (r.view !== 'board' || r.card) return
      const m = { j: [0, 1], ArrowDown: [0, 1], k: [0, -1], ArrowUp: [0, -1], h: [-1, 0], ArrowLeft: [-1, 0], l: [1, 0], ArrowRight: [1, 0] }[e.key]
      if (m) { e.preventDefault(); moveFocus(...m) }
    }
    addEventListener('keydown', f, true)
    return () => removeEventListener('keydown', f, true)
  }, [r])
}

function App() {
  const [st, refresh] = useBoard(), [r, go] = useRoute(), wide = useWide(), ov = useData(r.view === 'overview')
  const [pal, setPal] = useState(false), [keys, setKeys] = useState(false), [, setTheme] = useState(root.dataset.theme)
  // the button shows the theme a click turns on
  const themeIcon = () => root.dataset.theme === 'dark' ? IC.sun : IC.theme
  const toggleTheme = () => { const t = root.dataset.theme === 'dark' ? 'light' : 'dark'; root.dataset.theme = t; setTheme(t); try { localStorage.setItem('fm-theme', t) } catch {} }
  useKeys(r, go, setPal, setKeys, toggleTheme, pal, keys)
  const d = st.data
  useEffect(() => { document.title = d?.asks?.length ? `(${d.asks.length}) Fleet dashboard` : 'Fleet dashboard' }, [d])
  if (!d) return html`<div class="none" style="height:100vh">${st.err ? `Cannot load the fleet: ${st.err}` : ''}</div>`
  const cards = filterCards(d, r), open = d.cards.filter(c => ACTIVE.includes(c.stage)), stk = open.filter(stuck)
  const asks = d.asks?.length, today = total(d, d.landed.at(-1), 'landed'), opencard = id => go({ card: id })
  const count = t => t === 'all' ? null : total(d, d.cards.filter(c => inTab(t, c)).length, t)
  const shown = cards.filter(c => inTab(r.tab, c))
  const list = (byStage(r.tab) ? stagesOf(r.tab, r.stage) : [r.tab]).flatMap(s => sorted(shown.filter(c => c.stage === s)))
  const title = NAV.find(([v]) => v === r.view)[2], head = r.view === 'tickets' ? ticketsHead(d, r) : r.view === 'needs' ? { h: 'What waits on you', sub: `${d.asks?.length ?? '?'} questions from your leads and Main · answer each where it was asked` } : { h: title }
  const overlays = html`${r.card && html`<${Detail} d=${d} id=${r.card} go=${go} list=${list}/>`}
    ${pal && html`<${Palette} d=${d} go=${go} close=${() => setPal(false)}/>`}${keys && html`<${Shortcuts} close=${() => setKeys(false)}/>`}`
  const body = r.view === 'tickets' ? html`<${Tickets} d=${d} r=${r} go=${go} wide=${wide}/>` : r.view === 'overview' ? html`<${Overview} d=${d} od=${ov} go=${go}/>` : r.view === 'insights' ? html`<${Insights} d=${d}/>` : r.view === 'needs' ? html`<${Needs} d=${d} r=${r} go=${go} wide=${wide}/>` : null
  if (!wide) return html`<div class="phone">
    <header class="top">${LABEL()}<div class="tr"><h1>${title}</h1><div class="caps">${r.view === 'board' ? html`<${Filters} d=${d} r=${r} go=${go}/>` : r.view === 'tickets' ? html`<${TicketFilter} d=${d} r=${r} go=${go}/>` : r.view === 'needs' ? html`<${NeedsFilter} r=${r} go=${go}/>` : ''}<button class="ib" onClick=${toggleTheme} aria-label="Light or dark theme">${I(themeIcon(), 20)}</button></div></div></header>
    ${r.view !== 'tickets' && r.view !== 'needs' ? html`<div class="sum"><${Live} d=${d} st=${st} refresh=${refresh}/></div>` : ''}
    ${r.view === 'board' ? html`<div class="sum"><b>${asks == null ? 'Ask list unreadable' : asks ? `${asks} need${asks > 1 ? '' : 's'} you` : 'Nothing needs you'}</b> · <span>${total(d, open.length)} in flight</span> · <span class=${stk.length ? 'bad' : ''}>${total(d, stk.length)} stuck</span> · <span>${today} landed today</span></div>
      <div class="seg">${TABS.map(([t, n]) => html`<button aria-pressed=${r.tab === t} onClick=${() => go({ tab: t })}>${n === 'Landed today' ? 'Landed' : n}${count(t) != null ? html`<small class="num">${count(t)}</small>` : ''}</button>`)}</div>
      <${Chips} d=${d} r=${r} go=${go}/><${MobileKanban} d=${d} cards=${shown} r=${r} open=${opencard}/>` : html`<div class=${r.view === 'tickets' ? 'ph' : ''}>${body}</div>`}
    <div class="dock"><nav aria-label="Views">${NAV.map(([v, ic, n]) =>
      html`<a href=${'#/' + v} aria-label=${n} aria-current=${r.view === v ? 'page' : null}>${I(ic, 20)}<span>${n}</span>${v === 'needs' && asks && r.view !== v ? html`<span class="badge">${asks}</span>` : ''}</a>`)}</nav>
      <button onClick=${() => setPal(true)} aria-label="Search">${I(IC.search, 24)}</button></div>${overlays}</div>`
  return html`<div class="app">
    <nav class="side">
      ${LABEL()}<button class="dsearch" onClick=${() => setPal(true)} title="Search (⌘K)">${I(IC.search)}Search<kbd>⌘K</kbd></button>
      ${NAV.map(([v, ic, n]) => html`<a class="nav" href=${'#/' + v} aria-current=${r.view === v && !(v === 'board' && r.home.length) ? 'page' : null} onClick=${v === 'board' ? () => go({ view: 'board', home: [] }) : null}>${I(ic)}${n}
        ${v === 'needs' ? (asks ? html`<span class="badge">${asks}</span>` : html`<span class="n num">${asks ?? '?'}</span>`) : v === 'tickets' ? html`<span class="n num">${(d.tickets || []).filter(t => t.state !== 'done').length}</span>` : v === 'board' ? html`<span class="n num">${total(d, open.length)}</span>` : ''}</a>`)}
      ${r.view === 'tickets' ? html`<div class="sec">Projects</div>${Object.entries((d.tickets || []).filter(t => t.state !== 'done' && (r.kind === 'system') !== !!t.asked).reduce((m, t) => (m[proj(d, t)] = (m[proj(d, t)] || 0) + 1, m), {}))
        .sort((x, y) => y[1] - x[1]).slice(0, 8).map(([p, n]) => html`<button class="nav home-nav" aria-pressed=${r.project.length === 1 && r.project[0] === p} onClick=${() => go({ project: r.project[0] === p ? [] : [p] })}>
          <${Tile} d=${d} name=${p} small/><span class="home-name">${p}</span><span class="n num">${n}</span></button>`)}` : html`<div class="sec">Projects</div>
      ${d.homes.map(h => { const cs = open.filter(c => c.home === h.id)
        return html`<button class="nav home-nav" aria-label=${h.name} title=${h.name} aria-current=${r.view === 'board' && r.home.length === 1 && r.home[0] === h.id ? 'page' : null} onClick=${() => go({ view: 'board', home: [h.id], card: null })}>
          <${Tile} d=${d} name=${h.id} small/><span class="home-name">${h.name}</span><span class="home-short" aria-hidden="true">${Array.from(h.name).slice(0, 4).join('')}</span>${cs.some(stuck) ? html`<span class="dot" title="Stuck lanes"></span>` : ''}<span class="n num">${h.known ? cs.length : '?'}</span></button>` })}`}
      <div class="foot"><${Me} d=${d} st=${st} refresh=${refresh}/><span class="sp"></span><button class="ib" onClick=${toggleTheme} aria-label="Light or dark theme">${I(themeIcon())}</button></div>
    </nav>
    <main class="main">
      <header class="hd"><div class="tx">${LABEL(html`<em>› ${title}</em>`)}<h1>${head.h}</h1>${head.sub ? html`<p>${head.sub}</p>` : ''}</div>
        ${r.view === 'tickets' ? html`<${KindSeg} d=${d} r=${r} go=${go}/><${TicketFilter} d=${d} r=${r} go=${go} label="Filters"/>` : r.view === 'needs' ? html`<${NeedsFilter} r=${r} go=${go} label="Filters"/>` : ''}
        ${r.view === 'board' ? html`${TABS.map(([t, n]) => html`<button class="tab" aria-pressed=${r.tab === t} onClick=${() => go({ tab: t })}>${n}${count(t) != null ? html`<small class="num">${count(t)}</small>` : ''}</button>`)}
          <span class="sp"></span>
          <div class="kpi num"><a href="#/needs">Needs you <b>${asks ?? '?'}</b></a><button class=${stk.length ? 'bad' : ''} onClick=${() => go({ tab: 'active', state: ['blocked', 'decision'], stage: [], card: null })}>Stuck <b>${total(d, stk.length)}</b></button>
            <button onClick=${() => go({ tab: 'landed' })}>Landed today <b>${today}</b></button><span title="Typical time from start to landed">Cycle p50 <b>${d.cycle_p50 == null ? '–' : dur(d.cycle_p50)}</b></span></div>
          <${Filters} d=${d} r=${r} go=${go} label="Filter"/>
          ${byStage(r.tab) ? html`<${Pop} label="Display" icon=${IC.display}><div class="pop-h">Rows</div>
            ${[['', 'No grouping'], ['home', 'Home']].map(([v, n]) => html`<button class="opt" aria-pressed=${r.rows === v} onClick=${() => go({ rows: v })}><span class="ck">${r.rows === v ? I(IC.check, 11) : ''}</span>${n}</button>`)}</${Pop}>` : ''}` : ''}
      </header>
      ${r.view === 'board' ? html`<${Chips} d=${d} r=${r} go=${go}/><${Board} d=${d} cards=${shown} r=${r} open=${opencard}/>` : body}
    </main>${overlays}</div>`
}
render(html`<${App}/>`, document.getElementById('app'))
