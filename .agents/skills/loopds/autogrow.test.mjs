// autogrow.test.mjs —— 第0档裁判:跑它,断言全绿才算自动生长逻辑成立
import assert from 'node:assert'
import { initState, ingest, pickNext, recordRound, shouldStop, similarity, isDup } from './autogrow.mjs'

let pass = 0, fail = 0
function t(name, fn) {
  try { fn(); pass++; console.log('  ok  - ' + name) }
  catch (e) { fail++; console.log('  FAIL- ' + name + '  :: ' + e.message) }
}

// 1) 确定性去重 = novelty 外部锚(不靠模型自判)
t('相似方向被确定性判重,不入队', () => {
  let s = initState([{ facet: '自动课程生成的优先级排序机制', bin: 'auto-curriculum', priority: 2 }])
  const r = ingest(s, { proposedNextFacets: [{ facet: '自动课程生成中的优先级排序机制怎么做', bin: 'auto-curriculum' }] })
  assert.strictEqual(r.added, 0, '近重复应被去重,added 应为 0')
  assert.strictEqual(r.state.queue.length, 1, '队列不应增长')
})
t('真正不同的方向能入队', () => {
  let s = initState([{ facet: '自动课程生成的优先级排序', bin: 'auto-curriculum' }])
  const r = ingest(s, { blindSpots: [{ facet: '形式化契约当 gate 的开放式探索', bin: 'formal-spec' }] })
  assert.strictEqual(r.added, 1, '全新方向应入队')
})
t('similarity 自洽:同句=1,毫不相干≈0', () => {
  assert.ok(similarity('novelty search 新颖性搜索', 'novelty search 新颖性搜索') > 0.99)
  assert.ok(similarity('编译器当裁判', 'xkqz9 71203 plff') < 0.2)
})

// 2) 多样性分箱:冷 bin / 新类别优先 → 横向泛化、防坍缩
t('新类别(从没探的 bin)优先于刚探过的 bin', () => {
  let s = initState([
    { facet: 'A 在 auto-curriculum 里继续钻', bin: 'auto-curriculum', priority: 3 },
    { facet: 'B 开一个全新类别 quality-diversity', bin: 'quality-diversity', priority: 1 },
  ])
  // 假装 auto-curriculum 刚在第1轮探过
  s = { ...s, round: 1, binsLastRound: { 'auto-curriculum': 1 } }
  const { facet } = pickNext(s)
  assert.strictEqual(facet.bin, 'quality-diversity', '应优先弹从没探过的新类别(staleness=∞),即使它优先级更低')
})
t('同为冷 bin 时按优先级', () => {
  let s = initState([
    { facet: '低优新类别 X', bin: 'x', priority: 1 },
    { facet: '高优新类别 Y', bin: 'y', priority: 3 },
  ])
  const { facet } = pickNext(s)
  assert.strictEqual(facet.bin, 'y', '都没探过时,高优先级先')
})

// 3) blindSpot(critic 盲区)开新 bin → 自动先扩类别再钻深
t('completeness-critic 的 blindSpot 入队并因新 bin 被优先探', () => {
  let s = initState([{ facet: '在 auto-curriculum 钻深', bin: 'auto-curriculum', priority: 2 }])
  s = { ...s, round: 2, binsLastRound: { 'auto-curriculum': 2 } }
  const ing = ingest(s, { blindSpots: [{ facet: '测试时训练 TTT 当 loop 内自适应', bin: 'test-time-training' }] })
  assert.strictEqual(ing.added, 1)
  const { facet } = pickNext(ing.state)
  assert.strictEqual(facet.bin, 'test-time-training', 'critic 盲区开的新类别应被先探(扩边界)')
  assert.strictEqual(facet.origin, 'blindSpot')
})

// 4) 终止 + dry 兜底
t('账本没长 → dry 累加;达上限 → 停,reason=dry', () => {
  let s = initState([{ facet: 'f1', bin: 'b1' }, { facet: 'f2', bin: 'b2' }])
  let p = pickNext(s); s = recordRound(p.state, { facet: p.facet, ledgerGrewBytes: 0 })
  assert.strictEqual(s.dryRounds, 1)
  p = pickNext(s); s = recordRound(p.state, { facet: p.facet, ledgerGrewBytes: 0 })
  assert.strictEqual(s.dryRounds, 2)
  assert.deepStrictEqual(shouldStop(s, { dryLimit: 2 }), { stop: true, reason: 'dry' })
})
t('账本长了 → dry 清零(novelty 兜底:有真增长就继续)', () => {
  let s = initState([{ facet: 'f1', bin: 'b1' }, { facet: 'f2', bin: 'b2' }])
  let p = pickNext(s); s = recordRound(p.state, { facet: p.facet, ledgerGrewBytes: 0 })
  assert.strictEqual(s.dryRounds, 1)
  p = pickNext(s); s = recordRound(p.state, { facet: p.facet, ledgerGrewBytes: 420 })
  assert.strictEqual(s.dryRounds, 0, '有真增长应清零 dry')
})
t('队列空 → 停,reason=queue-empty', () => {
  let s = initState([{ facet: 'only', bin: 'b' }])
  let p = pickNext(s); s = recordRound(p.state, { facet: p.facet, ledgerGrewBytes: 100 })
  assert.deepStrictEqual(shouldStop(s, { dryLimit: 5 }), { stop: true, reason: 'queue-empty' })
})
t('预算到 → 停,reason=budget(最高优先)', () => {
  let s = initState([{ facet: 'a', bin: 'b' }])
  assert.deepStrictEqual(shouldStop(s, { dryLimit: 5, deadlinePassed: true }), { stop: true, reason: 'budget' })
})

// 端到端微缩:三轮自动生长不手填,验证 explored 增长 + 自动选 bin 多样
t('端到端:连续三轮全自动弹方向,explored 严格增长且 bin 多样', () => {
  let s = initState([{ facet: '种子:auto-curriculum 机制', bin: 'auto-curriculum', priority: 3 }])
  const rounds = [
    { proposedNextFacets: [{ facet: '课程难度自适应调度', bin: 'auto-curriculum' }], blindSpots: [{ facet: '新颖性搜索 archive 设计', bin: 'novelty-search' }] },
    { proposedNextFacets: [], blindSpots: [{ facet: 'MCTS 树搜索当探索调度', bin: 'tree-search' }] },
    { proposedNextFacets: [{ facet: '预算感知 bandit 资源分配', bin: 'bandit' }], blindSpots: [] },
  ]
  const seenBins = new Set()
  for (let i = 0; i < 3; i++) {
    const ing = ingest(s, rounds[i]); s = ing.state
    const p = pickNext(s); assert.ok(p.facet, '每轮都应能自动弹出一个方向')
    seenBins.add(p.facet.bin)
    s = recordRound(p.state, { facet: p.facet, ledgerGrewBytes: 200 })
  }
  assert.strictEqual(s.explored.length, 3, '三轮应探了 3 个方向')
  assert.ok(seenBins.size >= 3, '自动选出的方向应跨 >=3 个不同类别(泛化非坍缩),实得 ' + seenBins.size)
})

console.log('\n' + pass + ' passed, ' + fail + ' failed')
process.exit(fail === 0 ? 0 : 1)
