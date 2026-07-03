// autogrow.mjs —— loopds 第四根支柱「自动生长」驱动(纯函数,可测)
//
// 职责:管理 facet 队列(自动生长的外部状态),让 loop 自己生成下一步探索方向,
//       而不靠人手填,也不靠模型自判「新不新」。三个外部锚:
//   1) 确定性去重(bigram Jaccard)= novelty 的外部锚(不让生成方向的同一模型当裁判)
//   2) 多样性分箱(bin staleness 优先)= 防坍缩 + 强制横向泛化(先开新类别再钻深)
//   3) dry 兜底(账本字节没长就计 dry)= 即使「看着新」也由客观信号毙掉
//
// 设计纪律:全部纯函数,返回新 state 不可变;判断权全在确定性代码,不在模型。

function norm(s) {
  return String(s == null ? '' : s).toLowerCase().replace(/[^\p{L}\p{N}]/gu, '')
}

// bigram 集合:对中英混排都稳(中文无空格,按字符二元组)
function bigrams(s) {
  const n = norm(s)
  const g = new Set()
  if (n.length === 1) { g.add(n); return g }
  for (let i = 0; i < n.length - 1; i++) g.add(n.slice(i, i + 2))
  return g
}

export function similarity(a, b) {
  const A = bigrams(a), B = bigrams(b)
  if (!A.size || !B.size) return 0
  let inter = 0
  for (const x of A) if (B.has(x)) inter++
  return inter / (A.size + B.size - inter)
}

// novelty 外部锚:与任一已有方向相似度 >= 阈值 即判重(确定性,非模型自判)
export function isDup(facet, against, threshold = 0.5) {
  return against.some(g => similarity(facet, g) >= threshold)
}

function normCand(c, defBin, defPrio, defOrigin) {
  if (typeof c === 'string') return { facet: c, bin: defBin || 'misc', priority: defPrio || 1, origin: defOrigin || 'seed' }
  return {
    facet: c.facet || '',
    bin: c.bin || defBin || 'misc',
    priority: (typeof c.priority === 'number') ? c.priority : (defPrio || 1),
    origin: c.origin || defOrigin || 'seed',
  }
}

export function initState(seedFacets = []) {
  return { explored: [], queue: seedFacets.map(s => normCand(s)), binsLastRound: {}, dryRounds: 0, round: 0 }
}

// 把本轮产出的新方向入队:blindSpots(critic 的类别级盲区)优先级最高=先扩类别;
// proposedNextFacets(发现引出的增量)次之。两者都做确定性去重(against explored+queue+本批)。
export function ingest(state, { proposedNextFacets = [], blindSpots = [] } = {}) {
  const against = [
    ...state.explored.map(e => e.facet),
    ...state.queue.map(q => q.facet),
  ]
  const queue = state.queue.slice()
  let added = 0
  const batch = [
    ...blindSpots.map(b => normCand(b, 'blindspot', 3, 'blindSpot')),
    ...proposedNextFacets.map(p => normCand(p, 'incremental', 2, 'nextFacet')),
  ]
  for (const c of batch) {
    if (!c.facet || !c.facet.trim()) continue
    if (isDup(c.facet, against)) continue
    queue.push(c)
    against.push(c.facet)
    added++
  }
  return { state: { ...state, queue }, added }
}

// 自动弹下一个方向:主序=bin 越冷(越久没探/从没探)越优先 → 横向泛化、防坍缩;
// 次序=优先级高者先。新类别(blindSpot 开的新 bin)staleness=∞,天然最先被探。
export function pickNext(state) {
  if (!state.queue.length) return { facet: null, state }
  const scored = state.queue.map((q, idx) => {
    const last = state.binsLastRound[q.bin]
    const staleness = (last === undefined) ? Infinity : (state.round - last)
    return { q, idx, staleness, priority: q.priority }
  })
  scored.sort((a, b) => {
    const ds = (a.staleness === b.staleness) ? 0 : (b.staleness - a.staleness)
    if (ds !== 0) return ds
    return b.priority - a.priority
  })
  const chosen = scored[0]
  const queue = state.queue.filter((_, i) => i !== chosen.idx)
  return { facet: chosen.q, state: { ...state, queue } }
}

// 记一轮:把 facet 移入 explored;更新 bin 最近探索轮;dry 兜底=账本没长就 +1,长了清零。
export function recordRound(state, { facet, ledgerGrewBytes }) {
  const round = state.round + 1
  const explored = [...state.explored, { facet: facet.facet, bin: facet.bin }]
  const binsLastRound = { ...state.binsLastRound, [facet.bin]: round }
  const dryRounds = (ledgerGrewBytes > 0) ? 0 : (state.dryRounds + 1)
  return { ...state, round, explored, binsLastRound, dryRounds }
}

// 客观停机:预算到 ∨ 连续 dry 达上限 ∨ 队列空(生长枯竭)。三者最先满足即停。
export function shouldStop(state, { dryLimit = 2, deadlinePassed = false } = {}) {
  if (deadlinePassed) return { stop: true, reason: 'budget' }
  if (state.dryRounds >= dryLimit) return { stop: true, reason: 'dry' }
  if (state.queue.length === 0) return { stop: true, reason: 'queue-empty' }
  return { stop: false, reason: '' }
}
