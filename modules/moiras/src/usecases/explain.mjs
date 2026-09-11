// Explicit one-shot reasoning; observing a task never silently spends model tokens.
export async function explain({ reasoner, audit }, roles, roleName, taskId, snapshot) {
  if (!Object.hasOwn(roles, roleName)) throw Error('Unknown Fate');
  const worker = snapshot.workers.find(task => task.id === taskId);
  if (!worker) throw Error('Unknown task; no reasoning request sent');
  const role = roles[roleName], packet = { task: worker.id, observedAt: snapshot.now, busy: worker.busy,
    generationMatched: ['busy', 'idle'].includes(worker.busy), statusAgeSeconds: worker.age,
    last: worker.last, recentStatus: worker.lines ?? [], pr: worker.pr ?? null,
    findings: snapshot.findings.filter(finding => finding.task === taskId) };
  const result = await audit.step('reason', () => reasoner.read(role, packet), [roleName, taskId], Buffer.byteLength(JSON.stringify(packet)), role);
  audit.decision('advisory', 'recorded', [roleName, result.text.split('|')[1]]);
  return result;
}
