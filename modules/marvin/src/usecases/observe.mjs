import { classify } from '../core/quota.mjs';

export async function observe({ source, clock, renderer, telemetry }, config) {
  const start = clock.now();
  telemetry.append('source.enter');
  const inputs = await source.read(config.pools);
  const errors = inputs.filter(pool => pool.error).length;
  telemetry.append('source.exit', { outcome: errors ? 'error' : 'accepted',
    reasons: errors ? ['Quota source unavailable'] : [], stepsMs: { source: clock.now() - start }, counters: { errors, pools: inputs.length } });
  const frame = classify(inputs, clock.now());
  // Persist only quota metrics, never account identity, credential paths or raw source output.
  telemetry.append('sample', { outcome: 'accepted', counters: frame.counts,
    pools: frame.pools.map(pool => ({ id: pool.id, provider: pool.provider, tags: pool.tags,
      windows: pool.windows.map(({ id, remaining, idealPercent, delta, status }) => ({ id, remaining, idealPercent, delta, status })) })) });
  telemetry.append('renderer.enter');
  try {
    renderer.render(frame);
    telemetry.append('renderer.exit', { outcome: 'accepted' });
  } catch (error) {
    telemetry.append('renderer.exit', { outcome: 'error', reasons: ['Renderer failed'] });
    throw error;
  }
  return frame;
}

export async function watch(ports, config, frames = Infinity) {
  for (let i = 0; i < frames; i++) {
    await observe(ports, config);
    if (i + 1 < frames) await ports.clock.sleep(config.refreshSeconds * 1000);
  }
}
