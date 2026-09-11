import { run } from './command.mjs';
// Project before gh-axi's bounded TOON rendering; never parse PR prose as code.
const projection = 'map({key:("p"+(.number|tostring)),value:({url:.html_url,head:.head.ref,state,created:.created_at,merged:.merged_at,proof:((.body // "" | ascii_downcase) as $b | ["red","green","lint"] | all(. as $m | $b | test("\\\\b"+$m+"\\\\b")))}|tojson)})|from_entries';
/** @type {import('../ports/io').Forge} */
export const forge = { async read(repositories, signal) {
  const prs = [];
  for (const repo of repositories) {
    if (!/^[\w.-]+\/[\w.-]+$/.test(repo) || repo.split('/').some(part => ['.', '..'].includes(part))) throw Error('Invalid repository');
    for (let page = 1; page <= 10; page++) {
      const { stdout } = await run('gh-axi', ['api', `/repos/${repo}/pulls?state=all&sort=updated&direction=desc&per_page=100&page=${page}`, '--jq', projection], { timeout: 30000, maxBuffer: 1024 * 1024, signal });
      if (stdout.trim() === '{}') break;
      const rows = stdout.trim().split('\n').map(line => {
        const match = line.match(/^p\d+: (".*")$/); if (!match) throw Error('Unexpected or truncated forge response');
        let p;
        try { p = JSON.parse(JSON.parse(match[1])); } catch { throw Error('Malformed forge record'); }
        if (!/^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+$/.test(p.url) || typeof p.head !== 'string' || !['open', 'closed'].includes(p.state) || typeof p.proof !== 'boolean' || typeof p.created !== 'string' || !(p.merged === null || typeof p.merged === 'string')) throw Error('Invalid forge record');
        return p;
      });
      prs.push(...rows); if (rows.length < 100) break;
      if (page === 10) throw Error('Forge result exceeds 1000 PR limit');
    }
  }
  return prs;
} };
