const number = value => typeof value === 'number' && Number.isFinite(value);
const percent = value => number(value) && value >= 0 && value <= 100;
const identity = data => data.account?.accountId || data.account?.email?.toLowerCase();

export function classify(inputs, now) {
  const pools = inputs.map(input => {
    const data = input.data;
    const windows = (data.windows || []).map(window => pace(window, now, input.windows?.[window.id]));
    const unavailable = !!input.error || data.source === 'unavailable' || data.state?.stale === true ||
      (data.state?.status && data.state.status !== 'fresh') || data.state?.untrustedWindowIds?.length > 0 ||
      !!data.state?.error || !windows.some(row => row.remaining !== null && row.status !== 'UNAVAILABLE');
    const status = unavailable ? 'UNAVAILABLE' : windows.some(row => row.status === 'HOT') ? 'HOT' :
      windows.some(row => row.status === 'UNDER') ? 'UNDER' : windows.some(row => row.status === 'ON PACE') ? 'ON PACE' : 'PACE UNKNOWN';
    const tags = [status];
    if (identity(data) && inputs.filter(other => other.data.provider === data.provider && identity(other.data) === identity(data)).length > 1) tags.push('DUPLICATE ACCOUNT');
    if (data.account?.identityStatus === 'mismatch' || (input.expectedEmail && data.account?.email && input.expectedEmail.toLowerCase() !== data.account.email.toLowerCase())) tags.push('IDENTITY MISMATCH');
    const effective = data.quotaSemantics?.effectiveAvailability?.find(row => row.scope === 'all_models' && row.status === 'known')?.effectivePercentRemaining;
    const measured = windows.filter(row => row.remaining !== null);
    return { id: input.id, provider: data.provider, label: input.label || data.label || data.provider,
      plan: data.plan || null, email: data.account?.email || null,
      credentialSource: input.credentialSource || data.credentialSource || data.source || null,
      remaining: unavailable ? null : percent(effective) ? effective : measured.length ? Math.min(...measured.map(row => row.remaining)) : null,
      tags, windows, error: input.error || (unavailable ? 'Quota unavailable or stale' : null) };
  });
  const count = tag => pools.filter(pool => pool.tags.includes(tag)).length;
  return { ts: new Date(now).toISOString(), pools, counts: { agents: new Set(pools.map(pool => pool.provider)).size,
    accounts: pools.length, hot: count('HOT'), unavailable: count('UNAVAILABLE'), mismatch: count('IDENTITY MISMATCH'), duplicate: count('DUPLICATE ACCOUNT') } };
}

export function pace(window, now, seconds) {
  const remaining = percent(window.percentRemaining) ? window.percentRemaining :
    percent(window.percentUsed) ? 100 - window.percentUsed : null;
  const reset = Date.parse(window.resetsAt);
  const start = Date.parse(window.startsAt);
  const duration = seconds ?? (Number.isFinite(start) ? (reset - start) / 1000 : window.windowSeconds ?? window.pace?.cycleSeconds);
  const resetsIn = Number.isFinite(reset) ? Math.max(0, Math.floor((reset - now) / 1000)) : null;
  const valid = number(duration) && duration > 0 && reset > now && reset - duration * 1000 <= now;
  const idealPercent = valid ? (reset - now) / (duration * 1000) * 100 : null;
  const delta = remaining !== null && idealPercent !== null ? remaining - idealPercent : null;
  return { id: window.id, label: window.label || window.id, remaining, idealPercent, delta, resetsIn,
    windowSeconds: number(duration) && duration > 0 ? duration : null,
    status: remaining === null || (Number.isFinite(reset) && reset <= now) ? 'UNAVAILABLE' :
      delta === null ? 'PACE UNKNOWN' : delta < -0.0001 ? 'HOT' : delta > 0.0001 ? 'UNDER' : 'ON PACE' };
}
