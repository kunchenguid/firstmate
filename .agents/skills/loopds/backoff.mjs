// backoff.mjs —— 基础设施错误指数退避(采纳自 gnhf 对比研究 data/gnhf-vs-loopds-a3)
// 与既有 pillar-③/⑥ 的 dry/circuit-breaker(判断"没有进展")是两类不同的失败:
// dry 是"这轮跑完了但没长东西",退避是"这轮根本没跑完"(Workflow 调用抛错、API 500、
// 限流)。两类失败混在一起处理会让"工具本身在闹脾气"和"这条探索方向枯竭了"被同一个
// 熔断器计数,退避与生长队列的 dry 计数必须分开累计。
// 公式与 gnhf 的 orchestrator.ts start() 一致:60_000 * 2^(n-1) 毫秒,n = 连续基础设施
// 错误数(第 1 次错误 = 60s,第 2 次 = 120s,第 3 次 = 240s...)。任意一轮成功完成(不论
// 是否 dry)都应把 consecutiveErrors 清零 —— 退避只对*连续*的基础设施错误生效。
export function backoffDelayMs(consecutiveErrors) {
  const n = Number(consecutiveErrors)
  if (!Number.isFinite(n) || n < 1) return 0
  return 60_000 * 2 ** (n - 1)
}
