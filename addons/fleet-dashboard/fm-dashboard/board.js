// The board in Linear's language: columns of issue cards on a desktop (by stage, or by home for queued and landed work,
// optionally one band per home), a list grouped by stage on a phone, and the card detail as Linear's issue peek.
import { html, useState, useEffect, useRef, now, dur, hm, prNum, STAGES, ACTIVE, SNAME, stuck, state, reason, plain, total, hc, hname, mname,
  sorted, age, toCol, I, IC, Caret, StageIcon, Av } from './ui.js'

// Which lanes a tab shows, and whether its columns are stages or homes.
export const TABS = [['active', 'Active'], ['stuck', 'Stuck'], ['waiting', 'Waiting'], ['queued', 'Queued'], ['landed', 'Landed today'], ['all', 'All']]
const PICK = { active: () => true, stuck: stuck, waiting: c => c.wait === 'waiting' }
export const inTab = (t, c) => t === 'all' || (PICK[t] ? ACTIVE.includes(c.stage) && PICK[t](c) : c.stage === t)
// Queued and landed work is grouped by home; every other tab is grouped by stage.
export const byStage = t => t !== 'queued' && t !== 'landed'
// A stage filter (the Metrics lifecycle rail or To land) keeps only its own columns.
export const stagesOf = (t, only = []) => (t === 'all' ? STAGES : ACTIVE).filter(s => !only.length || only.includes(s))
// A home's count against its lane cap ("5 / 6"), amber over the cap; only when the group holds exactly that home's open lanes.
const Count = ({ d, n, home, cs }) => {
  const h = d.homes.find(x => x.id === home), cap = h?.plan
  return cap != null && cs.length === h.open ? html`<span class=${'n num cap' + (n > cap ? ' over' : '')} title="Open lanes of the lane cap">${n} / ${cap}</span>` : html`<span class="n num">${n}</span>`
}

const HomePill = ({ d, id }) => html`<span class="pill"><span class="sq" style=${{ '--c': hc(d, id) }}></span>${hname(d, id)}</span>`
export function Card({ d, c, open, home }) {
  const st = state(c), a = age(c), n = prNum(c.pr), why = reason(c)
  return html`<article class="card" role="button" tabindex="0" data-card=${c.id} onClick=${() => open(c.id)} onKeyDown=${e => { if (e.target === e.currentTarget && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); open(c.id) } }}>
    <div class="r1"><span class="id">${c.task}</span><span class="who"><${Av} m=${c.model} size=${14}/><span class="mn">${mname(c.model, d)}</span></span>${a != null ? html`<span class="num age">${c.stage === 'landed' ? hm(c.since) : dur(a)}</span>` : ''}</div>
    <h3>${c.title}</h3>
    ${why ? html`<p class="why">${why}</p>` : ''}
    <div class="r3">${st ? html`<span class="pill st"><i style=${{ '--c': st[1] }}></i>${st[0]}</span>` : ''}${home ? '' : html`<${HomePill} d=${d} id=${c.home}/>`}${c.kind === 'scout' ? html`<span class="pill">Scout</span>` : ''}
      ${n ? html`<a class="pill pr" href=${c.pr} target="_blank" rel="noreferrer" onClick=${e => e.stopPropagation()}>${I(IC.pr, 12)}${n}</a>` : ''}</div></article>`
}

const CAP = 20
function Col({ d, head, cs, open, home, stage }) {
  const [all, setAll] = useState(false), k = cs.filter(stuck).length
  return html`<section class="col"><header class="ch">${head}<span class="n num">${total(d, cs.length, stage)}</span><span class="sp"></span>${k ? html`<span class="hot">${total(d, k)} stuck</span>` : ''}</header>
    ${(all ? cs : cs.slice(0, CAP)).map(c => html`<${Card} key=${c.id} d=${d} c=${c} open=${open} home=${home}/>`)}
    ${cs.length > CAP && !all ? html`<button class="more" onClick=${() => setAll(true)}>${cs.length - CAP} more</button>` : ''}
    ${!cs.length ? html`<p class="empty">No recorded lanes</p>` : ''}</section>`
}
const stageHead = s => html`<${StageIcon} s=${s}/><b>${SNAME[s]}</b>`
const homeHead = (d, h) => html`<span class="sq" style=${{ '--c': hc(d, h) }}></span><b>${hname(d, h)}</b>`

export function Board({ d, cards, r, open }) {
  const stages = stagesOf(r.tab, r.stage)
  if (!cards.length) return html`<div class="none"><p>No recorded lanes match.</p></div>`
  if (!byStage(r.tab)) return html`<div class="board">${d.homes.filter(h => cards.some(c => c.home === h.id)).map(h =>
    html`<${Col} key=${h.id} d=${d} head=${homeHead(d, h.id)} cs=${sorted(cards.filter(c => c.home === h.id))} open=${open} home stage=${r.tab}/>`)}</div>`
  if (r.rows !== 'home') return html`<div class="board">${stages.map(s => html`<${Col} key=${s} d=${d} head=${stageHead(s)} cs=${sorted(cards.filter(c => c.stage === s))} open=${open} stage=${s}/>`)}</div>`
  return html`<div class="lanes" style=${{ '--n': stages.length }}>
    <div class="heads">${stages.map(s => html`<header class="ch">${stageHead(s)}<span class="n num">${total(d, cards.filter(c => c.stage === s).length, s)}</span></header>`)}</div>
    ${d.homes.filter(h => cards.some(c => c.home === h.id)).map(h => { const cs = cards.filter(c => c.home === h.id), k = cs.filter(stuck).length
      return html`<div class="band"><${Caret}/>${homeHead(d, h.id)}<${Count} d=${d} n=${total(d, cs.length, r.tab, h.id)} home=${h.id} cs=${cs}/><span class="sp"></span>${k ? html`<span class="hot">${total(d, k)} stuck</span>` : ''}</div>
        <div class="row">${stages.map(s => html`<div class="col">${sorted(cs.filter(c => c.stage === s)).map(c => html`<${Card} key=${c.id} d=${d} c=${c} open=${open} home/>`)}</div>`)}</div>` })}</div>`
}

// --- phone: a mobile kanban, one status column at a time (Linear/Jira mobile) --------
// A sticky switcher with counts jumps the horizontal, scroll-snapped columns to any status.
export function MobileKanban({ d, cards, r, open }) {
  const stages = stagesOf(r.tab, r.stage), grouped = byStage(r.tab) && r.rows !== 'home'
  const label = (s, n) => total(d, n, grouped ? s : r.tab)
  const cols = (grouped
    ? stages.map(s => ({ key: s, name: SNAME[s], head: stageHead(s), cs: sorted(cards.filter(c => c.stage === s)), home: false }))
    : d.homes.map(h => ({ key: h.id, name: hname(d, h.id), head: homeHead(d, h.id), cs: sorted(cards.filter(c => c.home === h.id)), home: true })))
    .filter(c => c.cs.length)
  const [i, setI] = useState(0), ref = useRef()
  const jump = k => { setI(k); toCol(ref.current, k, 'smooth') }
  const onScroll = () => { const el = ref.current; if (el) { const k = Math.min(cols.length - 1, Math.round(el.scrollLeft / (el.scrollWidth / cols.length))); if (k !== i) setI(k) } }
  useEffect(() => { if (i >= cols.length) setI(Math.max(0, cols.length - 1)) }, [cols.length])
  if (!cols.length) return html`<div class="none"><p>No recorded lanes match.</p></div>`
  return html`<div class="mk">
    <div class="mseg" role="tablist">${cols.map((c, k) => html`<button key=${c.key} role="tab" aria-selected=${i === k} onClick=${() => jump(k)}>${c.name}<small class="num">${label(c.key, c.cs.length)}</small></button>`)}</div>
    <div class="mcols" ref=${ref} onScroll=${onScroll}>${cols.map(c => html`<section class="mcol" key=${c.key}><header class="ch">${c.head}${c.home ? html`<${Count} d=${d} n=${label(c.key, c.cs.length)} home=${c.key} cs=${c.cs}/>` : html`<span class="n num">${label(c.key, c.cs.length)}</span>`}</header>
      ${c.cs.map(x => html`<${Card} key=${x.id} d=${d} c=${x} open=${open} home=${c.home}/>`)}</section>`)}</div>
  </div>`
}

// --- card detail -----------------------------------------------------------
// Repeated status lines with the same words read as one entry with a count.
export const squash = h => h.reduce((a, x) => { const p = a.at(-1)
  if (p && p.verb === x.verb && p.stage === x.stage && p.text === x.text) { p.n++; p.first = p.first ?? p.at; p.at = x.at } else a.push({ ...x, n: 1 }); return a }, [])
// Commit hashes, branch names and file names stay, set apart from the words around them; a long local path reads as its last part.
const CODE = /(\b[0-9a-f]{7,40}\b|\b(?:fm|nm|no-mistakes)\/[\w./-]+|\b[\w-]+\.(?:txt|md|json|sh|js|py)\b|\b\w+_\w+\b)/g
const words = t => (t || '').replace(/(?:~|\/home)\/[\w.@-]+(?:\/[\w.@-]+)*\/([\w.@-]+)/g, '…/$1').split(CODE).map((p, i) => i % 2 ? html`<code>${p}</code>` : p)
export function Entry({ x }) {
  const [raw, setRaw] = useState(false)
  return html`<li><b class=${x.tone}></b><div><div class="h"><strong>${x.verb}</strong>${x.n > 1 ? html`<span>${x.n}×</span>` : ''}
    ${x.at ? html`<span class="sp"></span><span class="num">${x.n > 1 && x.first ? `${hm(x.first)} – ` : ''}${hm(x.at)}</span>` : ''}</div>
    <p>${plain(x.text) || x.verb}${x.text ? html`<button class="rawb" aria-expanded=${raw} onClick=${() => setRaw(!raw)}>Raw</button>` : ''}</p>
    ${raw && html`<p class="raw">${words(x.text)}</p>`}</div></li>`
}
export const stageTimes = (enter, cur, done) => ACTIVE.map((s, i) => { const a = enter[s]; if (!a) return null
  const b = ACTIVE.slice(i + 1).map(x => enter[x]).find(Boolean) || (done ? enter.landed : i === cur ? now() : null)
  return b != null && b >= a ? b - a : null })
export function Detail({ d, id, go, list }) {
  const c = d.cards.find(x => x.id === id), at = list.findIndex(x => x.id === id), ref = useRef()
  const step = k => { const n = list[at + k]; if (n) go({ card: n.id }) }
  const close = () => { go({ card: null }); document.querySelector(`[data-card="${CSS.escape(id)}"]`)?.focus() }
  useEffect(() => {
    if (!document.querySelector('.pal')) ref.current?.focus()
    const f = e => { if (document.querySelector('.pal') || e.target.closest?.('input')) return
      if (e.key === 'Escape') close(); else if (e.key === 'j' || e.key === 'ArrowDown') step(1); else if (e.key === 'k' || e.key === 'ArrowUp') step(-1) }
    addEventListener('keydown', f)
    return () => removeEventListener('keydown', f)
  }, [id, list])
  if (!c) return null
  const st = state(c), why = reason(c), n = prNum(c.pr), cur = ACTIVE.indexOf(c.stage), done = c.stage === 'landed'
  const enter = { building: c.started, ...c.reached }, spent = stageTimes(enter, cur, done)
  const P = (k, v) => v ? html`<dt>${k}</dt><dd>${v}</dd>` : ''
  return html`<div class="scrim dim" onClick=${close}></div>
  <aside class="peek" role="dialog" aria-label=${c.title} tabindex="-1" ref=${ref}>
    <div class="bar"><${StageIcon} s=${c.stage}/><span>${SNAME[c.stage]}</span><span class="sp"></span>
      <button class="ib" disabled=${at <= 0} onClick=${() => step(-1)} aria-label="Previous lane">${I(IC.up)}</button>
      <button class="ib" disabled=${at < 0 || at >= list.length - 1} onClick=${() => step(1)} aria-label="Next lane">${I(IC.down)}</button>
      <button class="ib" onClick=${close} aria-label="Close">${I(IC.x)}</button></div>
    <div class="body">
      <div class="id">${hname(d, c.home)} · ${c.task}</div><h2>${c.title}</h2>${why ? html`<p class="why">${why}</p>` : ''}
      <dl class="props">
        ${P('State', st ? html`<span class="pill st"><i style=${{ '--c': st[1] }}></i>${st[0]}</span>` : done ? 'Landed' : c.state === 'validating' ? 'Checks running' : 'Moving')}
        ${P('Home', html`<${HomePill} d=${d} id=${c.home}/>${c.kind === 'scout' ? html`<span class="pill">Scout</span>` : ''}`)}
        ${P('Model', html`<${Av} m=${c.model}/>${mname(c.model, d)}${c.tool ? html`<small>${c.tool}${c.effort ? `, ${c.effort} effort` : ''}</small>` : ''}`)}
        ${c.since && !done && P(c.stage === 'queued' ? 'Ready for' : 'In stage', html`<span class="num">${dur(now() - c.since)}</span><small>since ${hm(c.since)}</small>`)}
        ${done && P('Landed', hm(c.since))}
        ${c.started && P('Started', html`<span class="num">${dur(now() - c.started)} ago</span><small>${hm(c.started)}</small>`)}
        ${n && P('Pull request', html`<a class="pill pr" href=${c.pr} target="_blank" rel="noreferrer">${I(IC.pr, 12)}#${n}</a>`)}
      </dl>
      ${c.stage !== 'queued' ? html`<div class="h4">Stages</div><div class="steps">${ACTIVE.map((s, i) => html`<div class=${'step' + (i === cur && !done ? ' cur' : done || enter[s] ? ' done' : '')} style=${{ '--st': `var(--st-${s})` }}>
        <i></i><span>${SNAME[s]}</span><small class="num">${spent[i] != null ? dur(spent[i]) : ''}</small></div>`)}</div>` : ''}
      ${c.history.length ? html`<div class="h4">Activity</div><ul class="act">${squash(c.history).reverse().map(x => html`<${Entry} x=${x}/>`)}</ul>` : ''}
    </div></aside>`
}
