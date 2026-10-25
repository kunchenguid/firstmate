// Tickets, in the owner-approved look: Your asks or System, a hero that counts what is done with one square per ticket
// (its legend picks the list: Moving, To do, On hold or Done), the list sorted by priority with each row's project icon,
// P0-P3 chip, how far its lane has got and its age; By release lays the open items in Next release, After and Later.
// On a computer a By project list sits beside it. A row opens the ticket page: its description, the captain's words it
// serves, its fields and its thread: the captain's comments with the lead's answers and, for a live lane, its status lines.
import { html, useState, useEffect, useRef, now, dur, hm, prNum, hc, hname, I, IC, STAGES, ACTIVE, SNAME, state, plain } from './ui.js'
import { squash, stageTimes } from './board.js'
import { Tile, Chip, Row, LIC, PRIO, LABEL } from './look.js'

export const IC_TICKET = html`<path d="M2.5 4.5a1 1 0 0 1 1-1h9a1 1 0 0 1 1 1v2a1.5 1.5 0 0 0 0 3v2a1 1 0 0 1-1 1h-9a1 1 0 0 1-1-1v-2a1.5 1.5 0 0 0 0-3zM10 5.5v1M10 9.5v1"/>`
const IC_RELEASE = html`<path d="M8 2.5l5.5 5.5L8 13.5 2.5 8z"/>`
const COLS = [['todo', 'To do'], ['progress', 'In progress'], ['review', 'In review'], ['captain', 'Waiting on captain'], ['done', 'Done'], ['hold', 'On hold']]
const CAP = 30
// The last update is an exact time from a lane's status line, or only the day the item was filed or closed.
const at = u => typeof u === 'number' ? u : u ? Date.parse(`${u}T12:00:00`) / 1000 : 0
const ago = u => typeof u === 'number' ? dur(now() - u) : u ? (k => k < 1 ? 'today' : `${k}d`)(Math.round((new Date().setHours(12, 0, 0, 0) / 1000 - at(u)) / 86400)) : ''
const order = (s, ts) => [...ts].sort(s === 'done' ? (a, b) => at(b.updated) - at(a.updated) : (a, b) => (a.priority ?? 9) - (b.priority ?? 9) || at(b.updated) - at(a.updated))
// Release lanes: a project's open items by target release. Next, After and Later are their own lanes; of a project's
// named releases (v0.2.0, muxr 0.2.10) the lowest version is its Next release unless it already has items marked next.
const LANES = [['next', 'Next release'], ['after', 'After'], ['later', 'Later']]
const rel = t => t.release.toLowerCase(), cap = r => /^(?:next|after|later)$/i.test(r) ? r[0].toUpperCase() + r.slice(1).toLowerCase() : r
const nat = (a, b) => a.localeCompare(b, undefined, { numeric: true })
function laneOf(ts) {
  const first = {}
  for (const t of ts) { const r = rel(t), p = t.project || 'none'
    if (r === 'next') first[p] = r
    else if (r !== 'after' && r !== 'later' && first[p] !== 'next' && (first[p] == null || nat(r, first[p]) < 0)) first[p] = r }
  return t => { const r = rel(t); return r === 'after' || r === 'later' ? r : r === first[t.project || 'none'] ? 'next' : 'after' }
}
const relRank = r => ({ next: 0, after: 2, later: 3 })[r] ?? 1

// A comment goes to the ticket's lead as a steer. The server takes it only from a device that opened the owner's
// sign-off board link at this address, whose cookie this page never sees.
function Comment({ t, onSent }) {
  const [text, setText] = useState(''), [note, setNote] = useState(''), [busy, setBusy] = useState(false)
  async function send(e) {
    e.preventDefault()
    setBusy(true)
    try {
      const r = await fetch('comment', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ticket: t.id, text }) })
      const a = await r.json().catch(() => ({ error: `the dashboard server answered ${r.status}` }))
      if (!r.ok) return setNote(a.error || `the dashboard server answered ${r.status}`)
      onSent({ at: Math.floor(Date.now() / 1000), text: text.trim(), to: a.to }); setText(''); setNote('')
    } catch (err) { setNote(`Not sent: ${err.message || err}`) } finally { setBusy(false) }
  }
  return html`<form class="tk-say" onSubmit=${send}><textarea aria-label="Comment" placeholder=${t.home === 'main' ? 'Comment to Main' : `Comment to the ${t.home} lead`} maxlength="1000" rows="1" value=${text} onInput=${e => setText(e.target.value)}></textarea>
    <button class="send" type="submit" aria-label="Send" disabled=${busy || !text.trim()}>${I(LIC.send, 16)}</button></form><p class="note" role="status">${note || 'It reaches the owning lead as a steer.'}</p>`
}
const lead = (d, h) => h === 'main' ? 'Main' : `${hname(d, h)} lead`
// The seven stages a lane passes, each with the time it spent there.
const STEPN = { queued: 'Queued', building: 'Build', review: 'Review', test: 'Test', ci: 'CI', merge: 'Merge', landed: 'Landed' }
function Steps({ c }) {
  const cur = STAGES.indexOf(c.stage), spent = stageTimes({ building: c.started, ...c.reached }, ACTIVE.indexOf(c.stage), c.stage === 'landed')
  return html`<div class="tsteps">${STAGES.map((s, i) => html`<div class=${i < cur || c.stage === 'landed' ? 'done' : i === cur ? 'cur' : ''}><i></i><span>${STEPN[s]}</span>
    <span class="num">${spent[i - 1] > 0 ? dur(spent[i - 1]) : ''}</span></div>`)}</div>`
}
// The ticket page: the reference's project page on a phone (a hero with the ticket's progress, three tiles, the
// captain's words, then the thread as cards), Margin's job page on a computer (how far it has got stage by
// stage, what happened as a timeline, the comment bar, and the fields with the captain's words beside).
function TicketPage({ d, t, go, wide }) {
  const c = d.cards.find(x => x.id === t.id), n = prNum(t.pr), close = () => go({ ticket: null }), ref = useRef(), [sent, setSent] = useState([]), [all, setAll] = useState(false), [open, setOpen] = useState(false)
  // a comment shows at once; the build's copy replaces it on the next refresh
  const said = [...(t.comments || []), ...sent.filter(x => !(t.comments || []).some(y => y.text === x.text))]
  useEffect(() => { ref.current?.focus(); const f = e => e.key === 'Escape' && close(); addEventListener('keydown', f); return () => removeEventListener('keydown', f) }, [t.id])
  const p = pct(d, t), live = c && t.state !== 'done', wait = live && state(c)?.[0], col = COLS.find(([s]) => s === t.state)[1]
  // the thread, newest first: the captain's comments with their pickup and answers, then the lane's status lines
  const items = [...said.flatMap(x => [{ at: x.at, who: 'You', text: x.text, tone: x.error ? 'bad' : 'ok', note: x.error ? `Not delivered: ${x.error}` : x.to === 'main' ? 'Sent to Main' : `Sent to the ${lead(d, x.to)} as a steer` },
    ...(x.picked ? [{ at: x.picked, who: lead(d, x.to), text: 'Picked up your comment', tone: 'ok' }] : []), ...(x.replies || []).map(y => ({ at: y.at || x.at, who: lead(d, y.by), text: y.text, tone: 'ok' }))]),
    ...squash(c?.history || []).map(x => ({ at: x.at, who: x.n > 1 ? `${x.verb} ${x.n}×` : x.verb, text: plain(x.text) || x.verb, tone: x.tone }))].sort((a, b) => (b.at || 0) - (a.at || 0))
  const card = x => html`<div class=${'soft tcard ' + (x.tone || '')}><div class="h">${x.who}<small class="num">${hm(x.at)}</small></div><p>${x.text}</p>${x.note ? html`<small>${x.note}</small>` : ''}</div>`
  const more = k => items.length > k ? html`<button class="all" onClick=${() => setAll(!all)}>${all ? 'Show fewer' : 'See all'}</button>` : ''
  const empty = html`<p class="empty">No status lines yet: the thread starts when a lane works on it.</p>`
  const said1 = t.ask && html`${I(LIC.user, 16)}Your words${t.ask.day ? ` · ${t.ask.day}` : ''}${t.ask.ref ? ` · ${t.ask.ref}` : ''}`
  const rows = [[LIC.bolt, 'Priority', html`<${Chip} p=${t.priority}/>${t.priority != null ? PRIO[t.priority] : 'Not set'}`], [IC.board, 'Project', html`<${Tile} d=${d} name=${proj(d, t)} small/>${proj(d, t)}`],
    [LIC.user, 'Lead', lead(d, t.home)], [IC_RELEASE, 'Release', cap(t.release)],
    [LIC.check, 'Proof', t.proof && html`<span class=${'num ' + (t.proof.receipt === 'FAIL' || t.proof.check && t.proof.check !== 'pass' ? 'bad' : '')}>${[t.proof.receipt && `Receipt ${t.proof.receipt}`,
      t.proof.check && `done-done ${t.proof.check}`, t.proof.head].filter(Boolean).join(' · ')}</span>`],
    [LIC.glass, 'Updated', html`<span class="num">${ago(t.updated)}</span>${typeof t.updated === 'number' ? html`<small>${hm(t.updated)}</small>` : ''}`]]
  const fields = html`<section class="soft">${rows.map(([ic, k, v]) => v ? html`<div class="kv"><span>${I(ic, 16)}${k}</span><b>${v}</b></div>` : '')}
    ${t.ask ? html`<div class="noted"><small>${said1}</small>“${t.ask.words}”</div>` : ''}</section>`
  // a long description shows its first lines, as the reference does; a tap reads the rest
  const desc = cls => t.desc ? html`<p class=${cls + (open ? ' open' : '')} title=${open ? '' : 'Show all'} onClick=${() => setOpen(!open)}>${t.desc}</p>` : ''
  const say = html`<${Comment} t=${t} onSent=${x => setSent([...sent, x])}/>`
  if (wide) return html`<aside class="tpage wide" role="dialog" aria-label=${t.title} tabindex="-1" ref=${ref}>
    <div class="crumbs">${LABEL()}<span>›</span><a onClick=${close}>Tickets</a><span>›</span><${Tile} d=${d} name=${proj(d, t)} small/>${proj(d, t)}</div>
    <div class="dhd"><div><h1>${t.title}</h1>${desc('clamp')}</div>${n ? html`<a class="gbtn" href=${t.pr} target="_blank" rel="noreferrer">${I(IC.pr, 16)}Pull request #${n}</a>` : ''}</div>
    <div class="tgrid"><div><section class="soft"><div class="lhd"><h2>How far it has got</h2><span class="all num">${p}%</span></div>
        <div class="pad">${c && c.stage !== 'queued' ? html`<${Steps} c=${c}/>` : html`<div class="pb"><span class="bar"><i style=${{ width: `${p}%` }}></i></span></div>`}
        <p class="note">${live ? `Its lane: ${SNAME[c.stage]}${wait ? ` · ${wait}` : ''}` : col + (t.state === 'todo' ? ', no lane yet' : '')}</p></div></section>
      <section class="soft"><div class="lhd"><h2>What happened</h2>${items.length ? html`<small class="num">${items.length}</small>` : ''}${items.length > 5 ? more(5) : items.length ? html`<span class="all quiet">Newest last</span>` : ''}</div>
        ${!items.length ? empty : all ? html`<div class="pad">${items.map(card)}</div>` : html`<ol class="tl">${items.slice(0, 5).reverse().map(x => html`<li class=${x.tone || ''}><small class="num">${hm(x.at)}</small><b>${x.who}</b><p>${x.text}</p></li>`)}</ol>`}</section>
      ${say}</div><div>${fields}</div></div></aside>`
  return html`<aside class="tpage" role="dialog" aria-label=${t.title} tabindex="-1" ref=${ref}>
    <div class="tbar"><button class="ib" onClick=${close} aria-label="Close">${I(LIC.back, 20)}</button><b>${proj(d, t)}</b>${n ? html`<a class="ib" href=${t.pr} target="_blank" rel="noreferrer" aria-label="Pull request">${I(IC.pr, 20)}</a>` : html`<span class="ib ghost"></span>`}</div>
    <section class="soft hero"><h2>${t.title}</h2>${desc('tk-desc clamp')}
      <div class="pb"><span class="bar"><i style=${{ width: `${p}%` }}></i></span><small class="num">${p}%</small></div><div class="st">${live ? html`${SNAME[c.stage]}${wait ? html` · <em>${wait}</em>` : ''}` : col}</div></section>
    <div class="tiles3"><div class="soft"><span>${t.priority != null ? PRIO[t.priority] : 'No priority'}</span><b><${Chip} p=${t.priority}/></b></div>
      <div class="soft"><span>Project</span><b><${Tile} d=${d} name=${proj(d, t)} small/><em>${proj(d, t)}</em></b></div><div class="soft"><span>Last update</span><b class="num">${ago(t.updated)}</b></div></div>
    ${t.ask ? html`<section class="soft words"><label>${said1}</label><q>${t.ask.words}</q></section>` : ''}
    <div class="lh"><h2>Activity</h2>${items.length ? html`<small class="num">${items.length}</small>` : ''}${more(3)}</div>${items.length ? (all ? items : items.slice(0, 3)).map(card) : empty}${say}</aside>`
}
// How far a ticket's lane has got, from Queued to Landed; a ticket with no lane takes its state.
const STEP = { queued: 0, building: 17, review: 33, test: 50, ci: 67, merge: 83, landed: 100 }
const pct = (d, t) => t.state === 'done' ? 100 : (c => c ? STEP[c.stage] : { todo: 0, hold: 0, progress: 17, review: t.pr ? 67 : 33 }[t.state])(d.cards.find(x => x.id === t.id))
const SHOW = { done: ['Done', t => t.state === 'done', 'd'], moving: ['Moving', t => t.state === 'progress' || t.state === 'review', 'm'], todo: ['To do', t => t.state === 'todo', ''], hold: ['On hold', t => t.state === 'hold', 'h'] }
const weekDone = (ts, back) => ts.filter(t => t.state === 'done' && (s => s >= back * 604800 && s < (back + 1) * 604800)(now() - at(t.updated))).length
export const proj = (d, t) => t.project || hname(d, t.home)  // a ticket with no project line shows and filters under its lead's home
const mine = (d, all, r) => all.filter(t => (r.kind === 'system') !== !!t.asked && (!r.project.length || r.project.includes(proj(d, t))) && (!r.release.length || r.release.includes(rel(t))))
export const ticketsHead = (d, r) => { const ts = mine(d, d.tickets || [], r), k = f => ts.filter(f).length
  return { h: r.kind === 'system' ? 'Where the system work stands' : 'Where your asks stand', sub: `${k(SHOW.done[1])} done, ${k(SHOW.moving[1])} moving, ${k(SHOW.todo[1])} not started, ${k(SHOW.hold[1])} on hold · ${ts.length} tickets` } }
export const KindSeg = ({ d, r, go, counts }) => html`<div class="kseg" role="group" aria-label="Whose work">${[['', 'Your asks', t => t.asked], ['system', 'System', t => !t.asked]].map(([v, n, f]) =>
  html`<button aria-pressed=${(r.kind || '') === v} onClick=${() => go({ kind: v, ticket: null })}>${n}${counts ? html`<small class="num">${(d.tickets || []).filter(f).length}</small>` : ''}</button>`)}</div>`
function Hero({ ts, r, go, aside }) {
  const ord = { done: 0, review: 1, progress: 1, todo: 2, hold: 3 }, wk = weekDone(ts, 0), before = weekDone(ts, 1)
  const body = html`<div class="h"><div class="sp"><label>${r.kind === 'system' ? 'System work done' : 'Your asks done'}</label><div class="big num">${ts.filter(SHOW.done[1]).length}<small>of ${ts.length}</small></div></div>
      <div class="hside"><span class="delta num"><i>▲</i>${wk} this week</span>${before ? `${before} the week before` : 'none the week before'}</div></div>
    <div class="dots" aria-label=${`${ts.length} tickets, one square each`}>${[...ts].sort((a, b) => ord[a.state] - ord[b.state]).map(t => html`<i class=${Object.values(SHOW).find(([, f]) => f(t))?.[2] || ''}></i>`)}</div>
    <div class="legend" role="group" aria-label="Show in the list">${Object.entries(SHOW).map(([k, [n, f, c]]) => html`<button aria-pressed=${!r.by && (r.show || 'moving') === k} onClick=${() => go({ show: k === 'moving' ? '' : k, by: '' })}><i class=${c}></i>${n} <b class="num">${ts.filter(f).length}</b></button>`)}</div>`
  return aside ? html`<section class="soft hero hwide"><div>${body}</div><div class="side2">${aside}</div></section>` : html`<section class="soft hero">${body}</section>`
}
function List({ d, s, name, xs, go, wide, r, cap = wide ? 6 : 3 }) {
  const [all, setAll] = useState(false), more = xs.length > cap && html`<button class="all" onClick=${() => setAll(!all)}>${all ? 'Show fewer' : 'See all'}</button>`
  const rows = html`<div class="grp">${(all ? xs : xs.slice(0, cap)).map(t => html`<${Row} key=${t.id} onClick=${() => go({ ticket: t.id })} tile=${html`<${Tile} d=${d} name=${t.project || t.home}/>`} chip=${html`<${Chip} p=${t.priority}/>`}
    title=${t.title} value=${`${pct(d, t)}%`} pct=${pct(d, t)} note=${ago(t.updated)} two=${wide} cur=${r.ticket === t.id}/>`)}${!xs.length ? html`<p class="empty">Nothing here</p>` : ''}</div>`
  return wide ? html`<section class="soft lane" data-lane=${s}><div class="lhd"><h2>${name}</h2><small class="num">${xs.length}</small>${more}</div>${rows}</section>`
    : html`<div class="lane" data-lane=${s}><div class="lh"><h2>${name}</h2><small class="num">${xs.length}</small>${more}</div><div class="soft">${rows}</div></div>`
}
function ByProject({ d, ts, go }) {
  const ps = Object.entries(ts.reduce((m, t) => ((m[proj(d, t)] ||= []).push(t), m), {})).map(([p, xs]) => [p, xs.length, xs.filter(t => t.state === 'done').length]).sort((a, b) => (b[1] - b[2]) - (a[1] - a[2]) || b[1] - a[1])
  return html`<section class="soft"><div class="lhd"><h2>By project</h2><small class="num">${ps.length}</small></div><div class="grp">${ps.slice(0, 8).map(([p, n, k]) =>
    html`<${Row} key=${p} onClick=${() => go({ project: [p] })} tile=${html`<${Tile} d=${d} name=${p}/>`} title=${p} value=${`${k} of ${n}`} pct=${Math.round(100 * k / n)} note=${`${Math.round(100 * k / n)}%`}/>`)}</div></section>`
}
const Tiles = ({ d }) => html`<div class="stats"><a class="soft stat" href="#/needs">${I(LIC.q, 20)}<span>Waiting on you</span><b class="num">${d.asks == null ? '?' : d.asks.length}<small>${d.asks?.length === 1 ? 'question' : 'questions'}</small></b></a>
  <div class="soft stat" title=${`The median, over ${d.cycle_n ?? 'the'} recorded merges, of each one's time from the task's last dispatch to the merge`}>${I(LIC.glass, 20)}<span>Typical start to landed</span><b class="num">${d.cycle_p50 == null ? '–' : dur(d.cycle_p50)}</b></div></div>`
// The filters, in one sheet: project, release and whether the list goes by state or by release.
export function TicketFilter({ d, r, go, label }) {
  const all = d.tickets || [], [open, setOpen] = useState(false), n = r.project.length + r.release.length + !!r.by
  const opts = (k, vs) => vs.map(([v, name, c]) => html`<button class="opt" aria-pressed=${k === 'by' ? r.by === v : r[k].includes(v)} onClick=${() => go({ [k]: k === 'by' ? v : r[k].includes(v) ? r[k].filter(x => x !== v) : [...r[k], v] })}><span class="ck">${(k === 'by' ? r.by === v : r[k].includes(v)) ? I(IC.check, 11) : ''}</span><span class="lt">${name}</span>${c != null ? html`<small class="num">${c}</small>` : ''}</button>`)
  return html`<div class="anchor"><button class=${label ? 'btn' : 'ib'} aria-expanded=${open} aria-label="Filters" onClick=${() => setOpen(!open)}>${I(IC.filter, label ? 16 : 20)}${label}${n ? html`<b>${n}</b>` : ''}</button>
    ${open && html`<div class="scrim" onClick=${() => setOpen(false)}></div><div class="pop"><div class="pop-h">List</div>${opts('by', [['', 'By state'], ['release', 'By release']])}
      <div class="pop-h">Release</div>${opts('release', [...new Set(all.map(rel))].sort((a, b) => relRank(a) - relRank(b) || nat(a, b)).map(v => [v, cap(v), all.filter(t => rel(t) === v).length]))}
      <div class="pop-h">Project</div>${opts('project', [...new Set(all.map(t => proj(d, t)))].sort().map(p => [p, p, all.filter(t => proj(d, t) === p).length]))}</div>`}</div>`
}

export function Tickets({ d, r, go, wide }) {
  const all = d.tickets || [], unread = d.tickets_unread || [], lane = laneOf(all.filter(t => t.state !== 'done')), ts = mine(d, all, r), show = SHOW[r.show] ? r.show : 'moving'
  const lists = r.by ? LANES.map(([s, name]) => [s, name, order(s, ts.filter(t => t.state !== 'done' && lane(t) === s))]) : [[show, SHOW[show][0], order(show, ts.filter(SHOW[show][1]))]]
  const page = r.ticket && all.find(t => t.id === r.ticket)
  const body = lists.map(([s, name, xs]) => html`<${List} key=${s} d=${d} s=${s} name=${name} xs=${xs} go=${go} wide=${wide} r=${r}/>`)
  return html`<div class=${'tks' + (wide ? ' wide' : '')}>${unread.length ? html`<p class="sum"><span class="bad">Backlog not read: ${unread.map(h => hname(d, h)).join(', ')}</span></p>` : ''}
    ${wide ? html`<${Hero} ts=${ts} r=${r} go=${go} aside=${html`<${Tiles} d=${d}/>`}/><div class="kgrid"><div class="k8" style="display:flex;flex-direction:column;gap:16px">${body}</div><div class="k4"><${ByProject} d=${d} ts=${ts} go=${go}/></div></div>`
      : html`<${KindSeg} d=${d} r=${r} go=${go} counts/><div style="margin-top:16px"><${Hero} ts=${ts} r=${r} go=${go}/></div>${body}<${Tiles} d=${d}/>`}
    ${page ? html`<${TicketPage} d=${d} t=${page} go=${go} wide=${wide}/>` : ''}</div>`
}
