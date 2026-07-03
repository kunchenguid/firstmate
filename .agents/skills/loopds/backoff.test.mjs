// backoff.test.mjs —— 第0档裁判:退避公式的确定性断言
import assert from 'node:assert'
import { backoffDelayMs } from './backoff.mjs'

let pass = 0, fail = 0
function t(name, fn) {
  try { fn(); pass++; console.log('  ok  - ' + name) }
  catch (e) { fail++; console.log('  FAIL- ' + name + '  :: ' + e.message) }
}

t('0 次连续错误 = 不退避', () => {
  assert.strictEqual(backoffDelayMs(0), 0)
})
t('第 1 次基础设施错误 = 60s', () => {
  assert.strictEqual(backoffDelayMs(1), 60_000)
})
t('第 2 次 = 120s,第 3 次 = 240s(指数翻倍)', () => {
  assert.strictEqual(backoffDelayMs(2), 120_000)
  assert.strictEqual(backoffDelayMs(3), 240_000)
})
t('第 6 次 ≈ 32min,验证公式在多轮后仍是纯指数而非线性', () => {
  assert.strictEqual(backoffDelayMs(6), 60_000 * 32)
})
t('负数/非数字输入退化为 0,不炸主循环', () => {
  assert.strictEqual(backoffDelayMs(-1), 0)
  assert.strictEqual(backoffDelayMs(NaN), 0)
  assert.strictEqual(backoffDelayMs('not-a-number'), 0)
})

console.log('\n' + pass + ' passed, ' + fail + ' failed')
process.exit(fail === 0 ? 0 : 1)
