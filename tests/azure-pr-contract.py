#!/usr/bin/env python3
"""Behavior cases run by fm-pr-merge.test.sh against a synthetic az transport.

No network, agent, or real runtime endpoint is used. Requests and completion
bodies are checked at the CLI boundary, never by inspecting implementation text.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
URL = "https://dev.azure.com/example/Project/_git/repo/pullrequest/7"
HEAD = "a" * 40
TARGET = "b" * 40
MERGE = "c" * 40
PROJECT = "11111111-1111-1111-1111-111111111111"
REPO = "22222222-2222-2222-2222-222222222222"
MIN_APPROVER_POLICY = "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd"
MERGE_STRATEGY_POLICY = "fa4e907d-c16b-4a4c-9dfa-4916e5d171ab"
STATUS_POLICY = "cbdc66da-9728-4af8-aada-9a5a32e4a226"
FILE_SIZE_POLICY = "2e26e725-8201-4edd-8bf5-978563c34a80"
CASE_ENFORCEMENT_POLICY = "7ed39669-655c-494e-b4a0-a08b4da0fcce"
MAX_PATH_LENGTH_POLICY = "001a79cf-fda1-4c4e-9e7c-bac40ee5ead8"
RESERVED_NAMES_POLICY = "db2b9b4c-180d-4529-9701-01541d19f36b"
AUTHOR_EMAIL_POLICY = "77ed4bd3-b063-4689-934a-175e4d0a78d7"
FILE_PATH_POLICY = "51c78909-e838-41a2-9496-c647091e3c61"

FAKE = r'''#!/usr/bin/env python3
import json,os,sys,time
from pathlib import Path
root=Path(os.environ['AZ_FIXTURE'])
a=sys.argv[1:]
with (root/'calls').open('a') as f: f.write(json.dumps(a)+'\n')
assert a[:2] == ['devops','invoke']
assert a[a.index('--detect')+1] == 'false'
resource=a[a.index('--resource')+1]
if (root/'slow').exists(): time.sleep(30)
if (root/'fail').exists(): print('simulated auth/network failure', file=sys.stderr); sys.exit(1)
if (root/'malformed').exists(): print('not json'); sys.exit(0)
data=json.loads((root/(resource+'.json')).read_text())
if resource=='pullRequests':
    n=int((root/'reads').read_text()) if (root/'reads').exists() else 0
    (root/'reads').write_text(str(n+1))
    if (root/'changed').exists() and n>=1: data['lastMergeSourceCommit']['commitId']='d'*40
    if '--in-file' in a:
        body=json.loads(Path(a[a.index('--in-file')+1]).read_text())
        (root/'patch').write_text(json.dumps(body))
        if (root/'race').exists(): sys.exit(1)
        assert body['lastMergeSourceCommit']['commitId']==data['lastMergeSourceCommit']['commitId']
        if not (root/'pending-completion').exists():
            data.update(status='completed',closedDate='2026-01-01T00:00:00Z')
            (root/'pullRequests.json').write_text(json.dumps(data))
data.setdefault('continuation_token',None)
if (root/'missing-continuation').exists(): data.pop('continuation_token',None)
print(json.dumps(data))
'''


class AzureContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fm-azure-contract-")
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        (self.dir / "bin").mkdir()
        (self.dir / "state").mkdir()
        (self.dir / "data").mkdir()
        (self.dir / "config").mkdir()
        (self.dir / "config/backlog-backend").write_text("manual\n")
        # Match the other forge-boundary fixtures: the advisory supervisor guard
        # is not an Azure check. Its host/harness discovery adds unrelated,
        # variable work to registration's subprocess budget.
        # Keep the real merge, registration, locks, and Azure policy checks.
        (self.dir / "bin/fm-guard.sh").write_text("#!/bin/sh\nexit 0\n")
        (self.dir / "bin/fm-guard.sh").chmod(0o700)
        (self.dir / "bin/az").write_text(FAKE)
        (self.dir / "bin/az").chmod(0o700)
        self.env = dict(os.environ, AZ_FIXTURE=str(self.dir), FM_HOME=str(self.dir),
                        FM_STATE_OVERRIDE=str(self.dir / "state"), FM_ROOT_OVERRIDE=str(self.dir),
                        FM_CONFIG_OVERRIDE=str(self.dir / "config"), FM_DATA_OVERRIDE=str(self.dir / "data"),
                        PATH=str(self.dir / "bin") + os.pathsep + os.environ['PATH'],
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", FM_BACKLOG_AUTOTRANSITION="0")
        self.env.pop("FM_PR_CHECK_MERGE", None)
        self.pr = dict(pullRequestId=7, status="active", isDraft=False, mergeStatus="succeeded",
                       mergeFailureType="none", repository=dict(id=REPO, name="repo", project=dict(id=PROJECT, name="Project")),
                       sourceRefName="refs/heads/users/example/fix", targetRefName="refs/heads/main",
                       lastMergeSourceCommit=dict(commitId=HEAD), lastMergeTargetCommit=dict(commitId=TARGET),
                       lastMergeCommit=dict(commitId=MERGE), completionOptions=dict(mergeStrategy="squash"),
                       reviewers=[dict(id="reviewer", vote=10, isRequired=True), dict(id="optional", vote=-10, isRequired=False)])
        self.approval_config = dict(id=1, revision=1, isEnabled=True, isBlocking=True,
                                    type=dict(id=MIN_APPROVER_POLICY),
                                    settings=dict(minimumApproverCount=1, allowDownvotes=True))
        self.merge_config = dict(id=2, revision=1, isEnabled=True, isBlocking=True,
                                 type=dict(id=MERGE_STRATEGY_POLICY),
                                 settings=dict(allowSquash=True, allowRebase=False, allowRebaseMerge=False, allowNoFastForward=False))
        self.configs = [self.approval_config, self.merge_config]
        self.policies = [
            dict(configuration=self.approval_config, status="approved",
                 artifactId=f"vstfs:///CodeReview/CodeReviewId/{PROJECT}/7",
                 context=dict(iterationId=2, sourceCommitId=HEAD,
                              lastMergeTargetCommitId=TARGET, lastMergeCommitId=MERGE)),
            dict(configuration=self.merge_config, status="approved",
                 artifactId=f"vstfs:///CodeReview/CodeReviewId/{PROJECT}/7",
                 context=dict(iterationId=2, sourceCommitId=HEAD,
                              lastMergeTargetCommitId=TARGET, lastMergeCommitId=MERGE)),
        ]
        self.save("pullRequests", self.pr)
        self.rows("policyConfigurations", self.configs)
        self.rows("evaluations", self.policies)
        self.rows("pullRequestIterations", [dict(id=2, sourceRefCommit=dict(commitId=HEAD), targetRefCommit=dict(commitId="d" * 40))])
        self.rows("pullRequestStatuses", [dict(id=1, state="succeeded", iterationId=2, context=dict(name="ci"))])
        self.rows("pullRequestThreads", [dict(status="active", comments=[dict(commentType="text", content="Reviewed")])])
        (self.dir / "state/task.meta").write_text("kind=ship\nmode=no-mistakes\nyolo=off\n")

    def save(self, resource, value):
        (self.dir / (resource + ".json")).write_text(json.dumps(value))

    def rows(self, resource, value):
        self.save(resource, dict(count=len(value), value=value, continuation_token=None))

    def status_policy(self, status_id, *, blocking=True):
        config = dict(id=3, revision=1, isEnabled=True, isBlocking=blocking,
                      type=dict(id=STATUS_POLICY), settings=dict(statusName="ci"))
        self.rows("policyConfigurations", self.configs + [config])
        self.rows("evaluations", self.policies + [
            dict(self.policies[0], configuration=config,
                 context=dict(iterationId=2, sourceCommitId=HEAD, latestStatusId=status_id))])

    def run_helper(self, action, url=URL):
        return subprocess.run([sys.executable, str(ROOT / "bin/fm-azure-pr.py"), action, url], env=self.env,
                              text=True, capture_output=True, timeout=15)

    def script(self, script, *args):
        # Successful registration/completion also publishes durable poll and
        # wake records through the real locks. Allow that shell/filesystem work
        # on slower hosts; the disposition test asserts its own tighter bound.
        return subprocess.run([str(ROOT / "bin" / script), *args], env=self.env,
                              text=True, capture_output=True, timeout=90)

    def prepare_crew(self, outcome):
        wt = self.dir / "wt"
        wt.mkdir()
        for args in (("init", "-q", "-b", "users/example/fix"),
                     ("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                      "commit", "-qm", "base", "--allow-empty")):
            subprocess.run(["git", "-C", str(wt), *args], env=self.env, check=True, capture_output=True)
        head = subprocess.check_output(["git", "-C", str(wt), "rev-parse", "HEAD"], env=self.env, text=True).strip()
        status = "completed" if outcome == "passed" else outcome
        self.run_record = (f'run:\n  id: "01RUN"\n  branch: users/example/fix\n  status: {status}\n'
                           f'  head: "{head}"\n  pr: "{URL}"\n  findings: none\noutcome: {outcome}\n')
        if outcome != "passed":
            self.run_record += "steps[9]{step,status,findings,duration_ms}:\n" + "".join(
                f"  {step},{outcome if step == 'ci' else 'completed'},0,0\n"
                for step in ("intent", "rebase", "review", "test", "document", "lint", "push", "pr", "ci"))
        (self.dir / "run-record").write_text(self.run_record)
        (self.dir / "ci-log").write_text("all CI checks passed - still monitoring until merged or closed\n")
        (self.dir / "state/task.meta").write_text(
            f"kind=ship\nmode=no-mistakes\nyolo=off\nworktree={wt}\nwindow=fm-task\npr={URL}\n")
        (self.dir / "bin/no-mistakes").write_text('''#!/usr/bin/env python3
import os,sys
from pathlib import Path
root=Path(os.environ['AZ_FIXTURE'])
a=sys.argv[1:]
if a[:2]==['axi','logs']:
    print((root/'ci-log').read_text())
elif a==['axi'] or a[:2]==['axi','status']:
    print((root/'run-record').read_text())
elif a==['daemon','status']:
    print('daemon running')
else:
    sys.exit(1)
''')
        (self.dir / "bin/no-mistakes").chmod(0o700)
        (self.dir / "bin/tmux").write_text("#!/bin/sh\nexit 1\n")
        (self.dir / "bin/tmux").chmod(0o700)
        self.env.update(NM_HOME=str(self.dir / "nm"), FM_CREW_STATE_NO_FORGE="0")
        for name in ("FM_CREW_STATE_META_OVERRIDE", "FM_CREW_STATE_STATUS_OVERRIDE"):
            self.env.pop(name, None)

    def calls(self):
        calls = self.dir / "calls"
        if not calls.exists():
            return []
        return [json.loads(line) for line in calls.read_text().splitlines() if line]

    def test_identity_routes(self):
        for url in (URL, "https://example.visualstudio.com/DefaultCollection/Project/_git/repo/pullrequest/7",
                    "https://example.visualstudio.com/Project/_git/repo/pullrequest/7",
                    "https://dev.azure.com/example/Team%20Project/_git/repo/pullrequest/7"):
            with self.subTest(url=url):
                p = self.run_helper("parse", url)
                self.assertEqual(p.returncode, 0, p.stderr)
                p = subprocess.run(["bash", "-c", '. "$1/bin/fm-pr-lib.sh"; fm_pr_url_parse "$2" && printf "%s\n%s\n" "$FM_PR_PROVIDER" "$FM_PR_URL"', "_", str(ROOT), url],
                                   env=self.env, text=True, capture_output=True)
                self.assertEqual(p.stdout, "azuredevops\n" + url + "\n")

    def test_malformed_identity(self):
        for url in (URL+"?x=1", URL+"#fragment", URL.replace("https:", "http:"),
                    URL.replace("dev.azure.com", "dev.azure.com.evil"), URL.replace("dev.azure.com", "user@dev.azure.com"),
                    URL.replace("Project", "%2e%2e"), URL.replace("Project", ".."), URL.replace("Project", "A%2FB"),
                    URL.replace("Project", "A%5CB"), URL.replace("Project", "A%0AB"), URL.replace("Project", "A%252FB"),
                    URL.replace("Project", "Team Project"), URL.replace("Project", "-/_git/x"), URL[:-1]+"0", URL[:-1]+"07",
                    URL.replace("repo", "repo;touch"), URL.replace("dev.azure.com", "dev.azure.com:443")):
            with self.subTest(url=url):
                self.assertNotEqual(self.run_helper("parse", url).returncode, 0)
        self.assertFalse((self.dir / "calls").exists())

    def test_arbitrary_legacy_collections_refuse_before_transport(self):
        for collection in ("Anything", "OtherCollection", "defaultcollection", "%44efaultCollection"):
            url = f"https://example.visualstudio.com/{collection}/Project/_git/repo/pullrequest/7"
            with self.subTest(collection=collection):
                for action in ("parse", "head"):
                    p = self.run_helper(action, url)
                    self.assertNotEqual(p.returncode, 0, p.stdout)
                p = subprocess.run(["bash", "-c", '. "$1/bin/fm-pr-lib.sh"; fm_pr_url_parse "$2"', "_", str(ROOT), url],
                                   env=self.env, text=True, capture_output=True)
                self.assertNotEqual(p.returncode, 0, p.stdout)
        self.assertEqual(self.calls(), [])

    def test_legacy_collection_transport_uses_root_organization_url(self):
        for path in ("DefaultCollection/Project", "Project"):
            url = f"https://example.visualstudio.com/{path}/_git/repo/pullrequest/7"
            with self.subTest(path=path):
                before = len(self.calls())
                p = self.run_helper("head", url)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(p.stdout, HEAD + "\n")
                organizations = [call[call.index("--organization") + 1] for call in self.calls()[before:]]
                self.assertEqual(organizations, ["https://example.visualstudio.com", "https://example.visualstudio.com"])

    def test_head_uses_current_iteration_source(self):
        current = "e" * 40
        self.rows("pullRequestIterations", [dict(id=3, sourceRefCommit=dict(commitId=current), targetRefCommit=dict(commitId="f" * 40))])
        p = self.run_helper("head")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, current + "\n")
        p = self.script("fm-pr-check.sh", "task", URL)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("pr_head=" + current, (self.dir / "state/task.meta").read_text())

    def test_registration_refuses_draft_transition_before_publication(self):
        (self.dir / "config/fleet-ledger").touch()
        (self.dir / ".fm-secondmate-home").write_text("azure-fixture\n")
        (self.dir / ".fm-secondmate-parent").write_text("schema=fm-secondmate-parent.v1\nroute=remote\n")
        p = self.run_helper("head")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, HEAD + "\n")
        self.save("pullRequests", dict(self.pr, isDraft=True))
        meta = self.dir / "state/task.meta"
        before = meta.read_bytes()
        p = self.script("fm-pr-check.sh", "task", URL)
        self.assertNotEqual(p.returncode, 0, p.stdout)
        self.assertIn("draft", p.stderr)
        self.assertIn(URL, p.stderr)
        self.assertEqual(meta.read_bytes(), before)
        for name in ("task.check.sh", "task.pr-poll", "task.pr-poll-registration",
                     "fleet-ledger.jsonl", "parent-replies.status"):
            self.assertFalse((self.dir / "state" / name).exists(), name)
        self.assertFalse((self.dir / "patch").exists())

        self.save("pullRequests", self.pr)
        p = self.script("fm-pr-check.sh", "task", URL)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("pr=" + URL, meta.read_text().splitlines())
        self.assertIn("pr_head=" + HEAD, meta.read_text().splitlines())
        self.assertTrue((self.dir / "state/task.check.sh").is_file())
        self.assertEqual((self.dir / "state/task.pr-poll").read_text(),
                         "azuredevops\n" + URL + "\ndev.azure.com\nexample/Project/_git/repo\n7\n")
        events = [json.loads(line) for line in (self.dir / "state/fleet-ledger.jsonl").read_text().splitlines()]
        self.assertEqual([(e["event"], e["task"], e["pr"]) for e in events], [("task.pr_ready", "task", URL)])
        self.assertIn("child task PR ready: " + URL, (self.dir / "state/parent-replies.status").read_text())

    def test_registration_accepts_non_draft_or_unknown_draft_field(self):
        for label, value in (("ready", False), ("null", None), ("missing", None)):
            with self.subTest(label=label):
                pr = dict(self.pr, isDraft=value)
                if label == "missing":
                    pr.pop("isDraft")
                self.save("pullRequests", pr)
                task = "task-" + label
                meta = self.dir / "state" / (task + ".meta")
                meta.write_text("kind=ship\nmode=no-mistakes\nyolo=off\n")
                p = self.script("fm-pr-check.sh", task, URL)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertIn("pr=" + URL, meta.read_text().splitlines())
                self.assertIn("pr_head=" + HEAD, meta.read_text().splitlines())
                self.assertTrue((self.dir / "state" / (task + ".check.sh")).is_file())

    def test_merge_reregistration_keeps_completion_draft_guard(self):
        self.save("pullRequests", dict(self.pr, isDraft=True))
        p = self.script("fm-pr-merge.sh", "task", URL)
        self.assertNotEqual(p.returncode, 0, p.stdout)
        self.assertIn("Azure PR is not active, non-draft and immediately mergeable", p.stderr)
        self.assertIn("pr=" + URL, (self.dir / "state/task.meta").read_text().splitlines())
        self.assertTrue((self.dir / "state/task.check.sh").is_file())
        self.assertFalse((self.dir / "patch").exists())

    def test_revision_bound_completion(self):
        p = self.run_helper("complete")
        self.assertEqual(p.returncode, 0, p.stderr)
        body = json.loads((self.dir / "patch").read_text())
        self.assertEqual(body, dict(status="completed", lastMergeSourceCommit=dict(commitId=HEAD),
                                   completionOptions=dict(mergeStrategy="squash", bypassPolicy=False,
                                                          deleteSourceBranch=False, transitionWorkItems=False)))
        self.assertEqual(self.run_helper("merged").stdout, "merged\n")

    def test_landed_identity_is_actual_merge_result_not_source_snapshot(self):
        self.save("pullRequests", dict(self.pr, status="completed", closedDate="2026-01-01T00:00:00Z"))
        result = self.run_helper("landed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, MERGE + "\n")
        self.assertNotEqual(MERGE, HEAD)
        self.save("pullRequests", dict(self.pr, status="completed", closedDate="2026-01-01T00:00:00Z", lastMergeCommit={}))
        self.assertNotEqual(self.run_helper("landed").returncode, 0)

    def test_refusal_matrix(self):
        cases = [dict(status="abandoned"), dict(isDraft=True), dict(mergeStatus="conflicts"),
                 dict(mergeStatus="queued"), dict(autoCompleteSetBy=dict(id="someone")),
                 dict(reviewers=[dict(vote=-10, isRequired=True)]), dict(reviewers=[dict(vote=-5, isRequired=True)]),
                 dict(reviewers=[dict(vote=0, isRequired=True)]), dict(reviewers=None),
                 dict(completionOptions=dict(mergeStrategy="rebase")),
                 dict(repository=dict(id=REPO, name="wrong", project=dict(id=PROJECT, name="Project")))]
        for change in cases:
            with self.subTest(change=change):
                self.save("pullRequests", dict(self.pr, **change))
                p = self.run_helper("complete")
                self.assertNotEqual(p.returncode, 0, p.stdout)
                self.assertFalse((self.dir / "patch").exists())

    def test_policy_refusal_matrix(self):
        # Optional failures must neither block nor waive a mandatory policy.
        self.rows("pullRequestStatuses", [dict(id=1, context=dict(name="informational"), state="failed", iterationId=2)])
        for status in ("queued", "running", "rejected", "broken", None):
            with self.subTest(status=status):
                self.rows("evaluations", [dict(self.policies[0], status=status), self.policies[1]])
                self.assertNotEqual(self.run_helper("complete").returncode, 0)
        self.rows("evaluations", [self.policies[1]])
        self.assertIn("missing", self.run_helper("complete").stderr)
        self.rows("evaluations", [dict(self.policies[0], context=dict(iterationId=1)), self.policies[1]])
        self.assertIn("older iteration", self.run_helper("complete").stderr)
        self.rows("evaluations", [dict(self.policies[0], context=dict(sourceCommitId=TARGET)), self.policies[1]])
        self.assertIn("different source", self.run_helper("complete").stderr)
        for context in (dict(lastMergeSourceCommitId=TARGET), dict(lastMergeTargetCommitId=HEAD),
                        dict(lastMergeCommitId=HEAD), dict(isExpired=True), dict(buildIsNotCurrent=True)):
            self.rows("evaluations", [dict(self.policies[0], context=context), self.policies[1]])
            self.assertNotEqual(self.run_helper("complete").returncode, 0)
        self.rows("evaluations", [dict(self.policies[0], configuration=dict(self.approval_config, revision=0)), self.policies[1]])
        self.assertIn("outdated", self.run_helper("complete").stderr)
        self.assertFalse((self.dir / "patch").exists())

    def test_push_only_policies_do_not_require_pr_evaluations(self):
        file_size = dict(id=3, revision=1, isEnabled=True, isBlocking=True,
                         type=dict(id=FILE_SIZE_POLICY),
                         settings=dict(maximumGitBlobSizeInBytes=1, useUncompressedSize=False))
        case_enforcement = dict(id=4, revision=1, isEnabled=True, isBlocking=True,
                                type=dict(id=CASE_ENFORCEMENT_POLICY),
                                settings=dict(enforceConsistentCase=True))
        max_path_length = dict(id=5, revision=1, isEnabled=True, isBlocking=True,
                               type=dict(id=MAX_PATH_LENGTH_POLICY),
                               settings=dict(maxPathLength=1))
        reserved_names = dict(id=6, revision=1, isEnabled=True, isBlocking=True,
                              type=dict(id=RESERVED_NAMES_POLICY),
                              settings=dict(reservedNames=['aux']))
        author_email = dict(id=7, revision=1, isEnabled=True, isBlocking=True,
                            type=dict(id=AUTHOR_EMAIL_POLICY),
                            settings=dict(authorEmailPatterns=['*@example.com']))
        file_path = dict(id=8, revision=1, isEnabled=True, isBlocking=True,
                         type=dict(id=FILE_PATH_POLICY),
                         settings=dict(filenamePatterns=['*.tmp']))
        self.rows("policyConfigurations", self.configs + [file_size, case_enforcement, max_path_length, reserved_names, author_email, file_path])
        self.rows("evaluations", self.policies)
        p = self.run_helper("complete")
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_required_build_exact_revision(self):
        c = dict(self.merge_config, id=3, type=dict(id="0609b952-1397-4640-95ec-e00a01b2c241"))
        self.rows("policyConfigurations", [self.approval_config, c])
        self.rows("evaluations", [self.policies[0], dict(self.policies[1], configuration=c, context=dict(buildId=10))])
        build = dict(status="completed", result="succeeded", repository=dict(id=REPO), sourceVersion=MERGE)
        self.save("builds", build)
        self.assertEqual(self.run_helper("complete").returncode, 0)
        (self.dir / "patch").unlink()
        self.save("pullRequests", self.pr)
        for change in (dict(sourceVersion=TARGET), dict(result="failed"), dict(status="inProgress")):
            self.save("builds", dict(build, **change))
            self.assertNotEqual(self.run_helper("complete").returncode, 0)
        self.assertFalse((self.dir / "patch").exists())

    def test_optional_checks_do_not_block_guarded_completion(self):
        self.status_policy(1)
        required = dict(id=1, state="succeeded", iterationId=2, context=dict(name="ci"))
        for check in (dict(state="pending", iterationId=2), dict(state="failed", iterationId=2),
                      dict(state="succeeded", iterationId=1), dict(state="failed", iterationId=1),
                      dict(state="succeeded")):
            with self.subTest(optional=check):
                self.save("pullRequests", self.pr)
                (self.dir / "patch").unlink(missing_ok=True)
                self.rows("pullRequestStatuses", [required, dict(id=2, context=dict(name="informational"), **check)])
                p = self.script("fm-pr-merge.sh", "task", URL)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertIn("merged", p.stdout.splitlines())
                body = json.loads((self.dir / "patch").read_text())
                self.assertEqual(body["lastMergeSourceCommit"], dict(commitId=HEAD))
                self.assertIs(body["completionOptions"]["bypassPolicy"], False)

    def test_only_blocking_status_policies_require_success(self):
        self.rows("pullRequestStatuses", [dict(id=1, state="failed", iterationId=2, context=dict(name="ci"))])
        # Same failed status and approved evaluation; only isBlocking changes.
        for blocking in (False, True):
            with self.subTest(blocking=blocking):
                self.save("pullRequests", self.pr)
                (self.dir / "patch").unlink(missing_ok=True)
                self.status_policy(1, blocking=blocking)
                p = self.run_helper("complete")
                if blocking:
                    self.assertNotEqual(p.returncode, 0, p.stdout)
                    self.assertIn("status policy", p.stderr)
                    self.assertFalse((self.dir / "patch").exists())
                else:
                    self.assertEqual(p.returncode, 0, p.stderr)
                    self.assertTrue((self.dir / "patch").exists())

    def test_unresolved_discussions_without_policy(self):
        self.rows("pullRequestStatuses", [])
        self.rows("pullRequestThreads", [dict(status="active", comments=[dict(commentType="text")])])
        self.assertEqual(self.run_helper("complete").returncode, 0)

    def test_status_policy_record_is_revision_bound(self):
        self.status_policy(1)
        current = dict(id=1, state="succeeded", iterationId=2, context=dict(name="ci"))
        p = self.run_helper("complete")
        self.assertEqual(p.returncode, 0, p.stderr)
        (self.dir / "patch").unlink()
        self.save("pullRequests", self.pr)
        cases = ([dict(current, state="pending")], [dict(current, state="failed")],
                 [dict(id=1, state="succeeded", context=dict(name="ci"))],
                 [dict(current, iterationId=1), dict(current, id=2)],
                 [dict(current, id=2)], [], [current, current])
        for statuses in cases:
            with self.subTest(statuses=statuses):
                self.rows("pullRequestStatuses", statuses)
                p = self.run_helper("complete")
                self.assertNotEqual(p.returncode, 0, p.stdout)
                self.assertIn("status policy", p.stderr)
                self.assertFalse((self.dir / "patch").exists())

    def test_status_policy_selects_the_current_check(self):
        older = dict(id=1, context=dict(name="ci"), state="failed", iterationId=1)
        current = dict(id=2, context=dict(name="ci"), state="succeeded", iterationId=2)
        self.status_policy(2)
        self.rows("pullRequestStatuses", [older, current])
        p = self.run_helper("complete")
        self.assertEqual(p.returncode, 0, p.stderr)
        (self.dir / "patch").unlink()
        self.save("pullRequests", self.pr)
        self.status_policy(3)
        for latest in (dict(current, id=3, state="pending"), dict(id=3, context=dict(name="ci"), state="succeeded")):
            with self.subTest(latest=latest):
                self.rows("pullRequestStatuses", [older, current, latest])
                p = self.run_helper("complete")
                self.assertNotEqual(p.returncode, 0, p.stdout)
                self.assertIn("status policy", p.stderr)
                self.assertFalse((self.dir / "patch").exists())

    def test_ambiguous_method_needs_selection(self):
        self.save("pullRequests", dict(self.pr, completionOptions={}))
        self.assertEqual(self.run_helper("complete").returncode, 0)  # single allowed method
        (self.dir / "patch").unlink()
        self.save("pullRequests", dict(self.pr, completionOptions={}))
        self.rows("policyConfigurations", [])
        self.rows("evaluations", [])
        self.assertIn("ambiguous", self.run_helper("complete").stderr)

    def test_auth_network_json_and_partial_errors(self):
        for flag in ("fail", "malformed", "missing-continuation"):
            (self.dir / flag).touch()
            self.assertNotEqual(self.run_helper("complete").returncode, 0)
            self.assertEqual(self.run_helper("merged").stdout, "")
            (self.dir / flag).unlink()
        self.save("evaluations", dict(count=len(self.policies), value=self.policies, continuation_token="next"))
        self.assertIn("partial", self.run_helper("complete").stderr)
        self.assertFalse((self.dir / "patch").exists())

    def test_changed_head_and_server_race(self):
        self.status_policy(1)
        self.rows("pullRequestStatuses", [dict(id=1, state="succeeded", iterationId=2, context=dict(name="ci")),
                                           dict(id=2, state="pending", iterationId=2, context=dict(name="informational"))])
        (self.dir / "changed").touch()
        self.assertIn("changed", self.run_helper("complete").stderr)
        self.assertFalse((self.dir / "patch").exists())
        (self.dir / "changed").unlink()
        (self.dir / "race").touch()
        self.assertNotEqual(self.run_helper("complete").returncode, 0)
        self.assertEqual(self.run_helper("merged").stdout, "")

    def test_completed_not_abandoned_poll(self):
        for status in ("active", "abandoned", "completed"):
            self.save("pullRequests", dict(self.pr, status=status, closedDate="2026-01-01T00:00:00Z"))
            p = self.script("fm-pr-poll.sh", "--validated", "azuredevops", URL, "dev.azure.com", "example/Project/_git/repo", "7")
            self.assertEqual(p.stdout, "merged\n" if status == "completed" else "")
        self.save("pullRequests", dict(self.pr, status="completed", closedDate=None))
        self.assertEqual(self.run_helper("merged").stdout, "")
        self.assertEqual(self.script("fm-pr-poll.sh", "--validated", "azuredevops", URL, "evil.example", "example/Project/_git/repo", "7").stdout, "")

    def test_crew_passed_disposition(self):
        self.prepare_crew("passed")
        cases = ((dict(status="active"), "open"),
                 (dict(status="completed", closedDate="2026-01-01T00:00:00Z"), "merged"),
                 (dict(status="abandoned"), "closed"),
                 (dict(status="completed"), "state unknown (unreadable)"),
                 (dict(status="completed", closedDate="2026-01-01T00:00:00Z", mergeStatus="queued"), "state unknown (unreadable)"),
                 (dict(status="unknown"), "state unknown (unreadable)"))
        for changes, expected in cases:
            with self.subTest(changes=changes):
                self.save("pullRequests", dict(self.pr, **changes))
                p = self.script("fm-crew-state.sh", "task")
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertIn("state: done", p.stdout)
                self.assertIn("run passed: PR " + expected, p.stdout)
        self.assertTrue(self.calls())
        self.assertFalse((self.dir / "patch").exists())

    def test_crew_green_monitor_disposition(self):
        self.prepare_crew("failed")
        self.save("pullRequests", dict(self.pr, reviewers=[dict(vote=0, isRequired=True)]))
        for outcome in ("failed", "cancelled"):
            (self.dir / "run-record").write_text(self.run_record.replace("failed", outcome))
            for status, label in (("active", "held for merge"), ("completed", "merged"), ("abandoned", None)):
                with self.subTest(outcome=outcome, status=status):
                    self.save("pullRequests", dict(self.pr, status=status, closedDate="2026-01-01T00:00:00Z",
                                                    reviewers=[dict(vote=0, isRequired=True)]))
                    p = self.script("fm-crew-state.sh", "task")
                    self.assertEqual(p.returncode, 0, p.stderr)
                    if label:
                        self.assertIn("state: done", p.stdout)
                        self.assertIn("checks green: PR " + label + " (ci monitor ended)", p.stdout)
                    else:
                        self.assertIn("state: " + ("failed" if outcome == "failed" else "unknown"), p.stdout)
                        self.assertNotIn("checks green", p.stdout)
        self.assertFalse((self.dir / "patch").exists())

    def test_crew_unreadable_and_skipped_disposition(self):
        self.prepare_crew("failed")
        for flag in ("fail", "malformed", "missing-continuation"):
            with self.subTest(flag=flag):
                (self.dir / flag).touch()
                p = self.script("fm-crew-state.sh", "task")
                self.assertIn("state: failed", p.stdout)
                self.assertNotIn("checks green", p.stdout)
                (self.dir / flag).unlink()
        before = self.calls()
        self.env["FM_CREW_STATE_NO_FORGE"] = "1"
        p = self.script("fm-crew-state.sh", "task")
        self.assertIn("state: failed", p.stdout)
        self.assertEqual(self.calls(), before)
        self.assertFalse((self.dir / "patch").exists())

    def test_crew_disposition_read_is_bounded(self):
        self.prepare_crew("passed")
        (self.dir / "slow").touch()
        start = time.monotonic()
        p = self.script("fm-crew-state.sh", "task")
        self.assertLess(time.monotonic() - start, 12)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("run passed: PR state unknown (unreadable)", p.stdout)
        self.assertTrue(self.calls())
        self.assertFalse((self.dir / "patch").exists())

    def test_registration_and_guarded_merge(self):
        p = self.script("fm-pr-check.sh", "task", URL)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((self.dir / "state/task.pr-poll").read_text(),
                         "azuredevops\n" + URL + "\ndev.azure.com\nexample/Project/_git/repo\n7\n")
        self.assertIn("pr_head=" + HEAD, (self.dir / "state/task.meta").read_text())
        p = self.script("fm-pr-merge.sh", "task", URL)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(URL, (self.dir / "state/.wake-queue").read_text())
        self.assertTrue((self.dir / "state/task.merge-authority").exists())

    def test_no_waivers_or_async_success(self):
        for args in (("--allow-red", "ci"), ("--allow-missing", "ci"), ("--", "--bypass-policy"), ("--attended-override", "--", "--auto")):
            p = self.script("fm-pr-merge.sh", "task", URL, *args)
            self.assertNotEqual(p.returncode, 0)
            self.assertFalse((self.dir / "patch").exists())
        (self.dir / "pending-completion").touch()
        p = self.script("fm-pr-merge.sh", "task", URL)
        self.assertNotEqual(p.returncode, 0, p.stdout)
        self.assertTrue((self.dir / "state/task.pr-poll").exists())
        self.assertFalse((self.dir / "state/.wake-queue").exists())


if __name__ == "__main__":
    unittest.main()
