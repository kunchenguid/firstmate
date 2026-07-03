// drive.mjs —— loopds 自动生长驱动器(确定性,把 autogrow 引擎接到真 loop 上)
// 状态目录来自环境变量 LOOPDS_DIR(默认当前目录);loop 用它管 facet 队列。
// 这个目录本身就是"统一 run-id 目录"(采纳自 gnhf 对比研究 data/gnhf-vs-loopds-a3):
// 把它设成 $CLAUDE_JOB_DIR/tmp/loopds-runs/<runId>/,loopds-contract.md、
// loopds-ledger.md、loopds-facets.json 都落在同一个可按名字寻址的目录下,一次会话
// 死掉后按 runId 就能找回整个 run,不用从零散的 tmp/* 文件里猜状态。这纯粹是命名/
// 归档约定,不是新逻辑 —— drive.mjs 本身不需要改一行就已经支持(它一直只认
// LOOPDS_DIR,从不假设扁平布局)。
// 用法:
//   LOOPDS_DIR=<run目录> node drive.mjs pick                      # 自动弹下一方向 → 写 current-facet.txt(绝不手选)
//   LOOPDS_DIR=<run目录> node drive.mjs ingest <result.json> <grewBytes> [deadlinePassed]
//   node drive.mjs backoff <consecutiveErrors>                    # 基础设施错误退避毫秒数(不读 LOOPDS_DIR)
// 前置:<run目录>/loopds-facets.json 已存在,queue 里放一个种子 facet。
import fs from 'node:fs'
import path from 'node:path'
import { ingest, pickNext, recordRound, shouldStop } from './autogrow.mjs'
import { backoffDelayMs } from './backoff.mjs'

const DIR = process.env.LOOPDS_DIR || process.cwd()
const FACETS = path.join(DIR, 'loopds-facets.json')
const CURF_TXT = path.join(DIR, 'loopds-current-facet.txt')

function load() {
  const s = JSON.parse(fs.readFileSync(FACETS, 'utf8'))
  s.explored = s.explored || []
  s.queue = s.queue || []
  s.binsLastRound = s.binsLastRound || {}
  s.dryRounds = s.dryRounds || 0
  s.round = s.round || 0
  return s
}
function save(s) { fs.writeFileSync(FACETS, JSON.stringify(s, null, 2)) }

const cmd = process.argv[2]

if (cmd === 'pick') {
  let s = load()
  const { facet, state } = pickNext(s)
  if (!facet) { console.log('PICK: 队列空,无方向可弹'); process.exit(3) }
  state.current = facet
  save(state)
  fs.writeFileSync(CURF_TXT, facet.facet)
  console.log('PICK: [bin=' + facet.bin + ' prio=' + facet.priority + ' origin=' + facet.origin + ']')
  console.log(facet.facet)
} else if (cmd === 'ingest') {
  const resultPath = process.argv[3]
  const grewBytes = Number(process.argv[4] || 0)
  const deadlinePassed = process.argv[5] === 'true'
  const result = JSON.parse(fs.readFileSync(resultPath, 'utf8'))
  let s = load()
  const before = s.queue.length
  const ing = ingest(s, { proposedNextFacets: result.proposedNextFacets || [], blindSpots: result.blindSpots || [] })
  s = ing.state
  s = recordRound(s, { facet: s.current || { facet: '?', bin: 'misc' }, ledgerGrewBytes: grewBytes })
  s.history = (s.history || []).concat([{ round: s.round, facet: (s.current || {}).facet, bin: (s.current || {}).bin, grewBytes, added: ing.added }])
  save(s)
  const stop = shouldStop(s, { dryLimit: 2, deadlinePassed })
  console.log('INGEST round ' + s.round + ': 入队新方向 +' + ing.added + ' (去重后 ' + before + '→' + s.queue.length + '), 账本增 ' + grewBytes + 'B, dryRounds=' + s.dryRounds)
  console.log('STOP: ' + JSON.stringify(stop))
  console.log('QUEUE 现有方向: ' + s.queue.map(q => '[' + q.bin + ']').join(' '))
} else if (cmd === 'backoff') {
  const consecutiveErrors = Number(process.argv[3] || 0)
  const ms = backoffDelayMs(consecutiveErrors)
  console.log('BACKOFF: consecutiveErrors=' + consecutiveErrors + ' delayMs=' + ms + ' (~' + Math.round(ms / 1000) + 's)')
} else {
  console.log('用法: LOOPDS_DIR=<dir> node drive.mjs pick | ingest <result.json> <grewBytes> [deadlinePassed] | backoff <consecutiveErrors>')
  process.exit(1)
}
