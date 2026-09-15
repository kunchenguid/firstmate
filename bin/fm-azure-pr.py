#!/usr/bin/env python3
"""Azure DevOps Services PR identity, live verification and completion transport.

Usage: fm-azure-pr.py parse|head|merged|landed|verify|complete <canonical-pr-url>
`parse` prints host, repository path and number; `head` prints the live source
SHA; `merged` prints only `merged` after proof; `landed` prints the completed
source SHA. `verify` is read-only. `complete` is called only by fm-pr-merge.sh
under its authority locks and repeats verification immediately before PATCH.
Requires python3 and az with azure-devops (1.0.5+). REST 7.1 via devops invoke
retains continuation_token, unlike typed CLI views. Partial lists are refused.
No CLI defaults, auto-complete, bypass, branch deletion or caller body overrides.
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote, unquote, urlsplit


class Refused(Exception):
    pass


def require(ok, message):
    if not ok:
        raise Refused(message)


def component(raw):
    text = unquote(raw, errors="strict")
    require(0 < len(text) <= 255 and text not in (".", ".."), "invalid Azure path segment")
    require(not any(c in text for c in "/\\%?#") and
            not any(ord(c) < 32 or ord(c) == 127 for c in text), "invalid Azure path segment")
    require(quote(text, safe="-._~") == raw, "noncanonical Azure path encoding")
    return text


class Identity:
    def __init__(self, url):
        u = urlsplit(url)
        require(u.scheme == "https" and not u.query and not u.fragment and
                u.netloc == u.hostname and len(url) < 2048, "invalid Azure PR URL")
        self.host = u.netloc
        parts = u.path.split("/")[1:]
        require(len(parts) >= 5 and parts[-4] == "_git" and parts[-2] == "pullrequest"
                and re.fullmatch(r"[1-9][0-9]{0,9}", parts[-1]), "invalid Azure PR route")
        require(int(parts[-1]) <= 2147483647, "invalid Azure PR number")
        if self.host == "dev.azure.com":
            require(len(parts) == 6 and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", parts[0]),
                    "invalid Azure organization")
            self.org = "https://dev.azure.com/" + parts[0]
        else:
            require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}\.visualstudio\.com", self.host)
                    and len(parts) in (5, 6), "unsupported Azure Services host or route")
            self.org = "https://" + self.host
            if len(parts) == 6:
                component(parts[0])
                self.org += "/" + parts[0]
        self.project = component(parts[-5])
        self.repo = component(parts[-3])
        self.number = parts[-1]
        self.path = "/".join(parts[:-2])
        self.url = url
        require(url == f"https://{self.host}/{self.path}/pullrequest/{self.number}",
                "noncanonical Azure PR URL")


def sha(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value),
            "unreadable Azure commit ID")
    return value


def guid(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value),
            "unreadable Azure repository/project ID")
    return value


class Azure:
    def __init__(self, identity):
        self.i = identity

    def invoke(self, resource, area="git", query=None, body=None, project=None, repo=True, route_extra=None):
        route = {"project": project or self.i.project}
        if repo:
            route.update(repositoryId=self.i.repo, pullRequestId=self.i.number)
        route.update(route_extra or {})
        args = ["az", "devops", "invoke", "--organization", self.i.org,
                "--detect", "false", "--area", area, "--resource", resource,
                "--api-version", "7.1-preview" if area == "policy" else "7.1", "--only-show-errors", "--output", "json",
                "--route-parameters"] + [f"{k}={v}" for k, v in route.items()]
        if query:
            args += ["--query-parameters"] + [f"{k}={v}" for k, v in query.items()]
        # invoke requires a file for PATCH. Private, ephemeral and contains no
        # credentials; the extension owns Azure authentication unchanged.
        with tempfile.NamedTemporaryFile(mode="w+", suffix=".json") as payload:
            if body is not None:
                json.dump(body, payload)
                payload.flush()
                args += ["--http-method", "PATCH", "--in-file", payload.name]
            try:
                result = subprocess.run(args, capture_output=True, text=True, timeout=45)
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise Refused("Azure API unavailable (az/azure-devops required, or request timed out)") from exc
        require(result.returncode == 0, f"Azure {resource} read/completion failed; check Azure authentication and network")
        try:
            data = json.loads(result.stdout)
        except (ValueError, TypeError) as exc:
            raise Refused("unreadable Azure JSON response") from exc
        require(isinstance(data, dict), "unexpected Azure API response")
        require("continuation_token" in data, "Azure extension did not preserve continuation evidence; upgrade azure-devops")
        require(data["continuation_token"] in (None, ""), "partial Azure response; refusing incomplete evidence")
        return data

    def listing(self, resource, **kwargs):
        data = self.invoke(resource, **kwargs)
        rows = data.get("value")
        require(isinstance(rows, list) and type(data.get("count")) is int and data["count"] == len(rows)
                and all(isinstance(row, dict) for row in rows), "unreadable Azure list")
        return rows

    def pr(self):
        pr = self.invoke("pullRequests")
        repo = pr.get("repository", {})
        project = repo.get("project", {})
        require(str(pr.get("pullRequestId")) == self.i.number and
                self.i.repo.casefold() in (str(repo.get("name", "")).casefold(), str(repo.get("id", "")).casefold()) and
                self.i.project.casefold() in (str(project.get("name", "")).casefold(), str(project.get("id", "")).casefold()),
                "Azure response does not match the requested PR identity")
        guid(repo.get("id"))
        guid(project.get("id"))
        sha(pr.get("lastMergeSourceCommit", {}).get("commitId"))
        return pr

    def landed(self):
        pr = self.pr()
        require(pr.get("status") == "completed" and pr.get("mergeStatus") == "succeeded"
                and isinstance(pr.get("closedDate"), str) and bool(pr["closedDate"]),
                "Azure PR completion is not confirmed")
        sha(pr.get("lastMergeCommit", {}).get("commitId"))
        return sha(pr["lastMergeSourceCommit"]["commitId"])

    def verify(self):
        pr = self.pr()
        require(pr.get("status") == "active" and pr.get("isDraft") is False and
                pr.get("mergeStatus") == "succeeded" and pr.get("mergeFailureType") in (None, "none") and
                not pr.get("autoCompleteSetBy"), "Azure PR is not active, non-draft and immediately mergeable")
        head = sha(pr["lastMergeSourceCommit"]["commitId"])
        target = sha(pr.get("lastMergeTargetCommit", {}).get("commitId"))
        iterations = self.listing("pullRequestIterations")
        require(iterations and all(type(x.get("id")) is int for x in iterations), "unreadable Azure iterations")
        iteration = max(iterations, key=lambda x: x["id"])
        require(iteration.get("sourceRefCommit", {}).get("commitId") == head,
                "Azure iteration does not match the candidate source revision")
        reviewers = pr.get("reviewers")
        require(isinstance(reviewers, list), "unreadable Azure reviewers")
        for r in reviewers:
            require(isinstance(r, dict) and type(r.get("vote")) is int and r["vote"] in (-10, -5, 0, 5, 10),
                    "unreadable Azure reviewer vote")
            require(not r.get("isRequired") or r["vote"] in (5, 10),
                    "Azure required reviewer has not supplied an approval")
        # The server's applicable policy evaluations own approval counts, group
        # membership, author exclusions, resets, build expiry and required status
        # contexts. Never derive these requirements from a fixed vote count.
        project_id = pr["repository"]["project"]["id"]
        artifact = f"vstfs:///CodeReview/CodeReviewId/{project_id}/{self.i.number}"
        policies = self.listing("evaluations", area="policy", project=project_id, repo=False,
                                query={"artifactId": artifact, "includeNotApplicable": "true"})
        configurations = self.listing("policyConfigurations", project=project_id, repo=False,
                                      query={"repositoryId": pr["repository"]["id"], "refName": pr["targetRefName"]})
        for c in configurations:
            require(type(c.get("id")) is int and type(c.get("revision")) is int and
                    type(c.get("isEnabled")) is bool and type(c.get("isBlocking")) is bool,
                    "unreadable applicable Azure policy")
            if c["isEnabled"] and c["isBlocking"]:
                matches = [p for p in policies if p.get("configuration", {}).get("id") == c.get("id")]
                require(len(matches) == 1 and matches[0]["configuration"] == c,
                        "mandatory Azure policy has missing, duplicate or outdated evaluation")
        methods = {"noFastForward", "squash", "rebase", "rebaseMerge"}
        required_status_ids = []
        for p in policies:
            config = p.get("configuration", {})
            require(p.get("artifactId") == artifact and type(config.get("isEnabled")) is bool and
                    type(config.get("isBlocking")) is bool, "unreadable Azure policy configuration")
            if not config["isEnabled"] or not config["isBlocking"]:
                continue
            require(p.get("status") in ("approved", "notApplicable"),
                    "mandatory Azure policy is pending, rejected, broken or unreadable")
            if p["status"] == "notApplicable":
                continue
            context = p.get("context") or {}
            require(isinstance(context, dict), "unreadable Azure policy context")
            # Not all policy types carry a revision; where Azure supplies one,
            # contradictory/stale evidence is never overridden by 'approved'.
            for field in ("sourceCommitId", "lastMergeSourceCommitId"):
                if field in context:
                    require(context[field] == head, "Azure policy evaluated a different source revision")
            if "lastMergeTargetCommitId" in context:
                require(context["lastMergeTargetCommitId"] == target, "Azure policy evaluated a different target revision")
            if "lastMergeCommitId" in context:
                require(context["lastMergeCommitId"] == sha(pr.get("lastMergeCommit", {}).get("commitId")),
                        "Azure policy evaluated a different candidate merge")
            if "iterationId" in context:
                require(context["iterationId"] == iteration["id"], "Azure policy evaluated an older iteration")
            for field in ("isExpired", "buildIsNotCurrent"):
                if field in context:
                    require(context[field] is False, "Azure policy build evidence is expired or not current")
            if "latestStatusId" in context:
                require(type(context["latestStatusId"]) is int and context["latestStatusId"] > 0,
                        "Azure status policy has no verifiable status record")
                required_status_ids.append(context["latestStatusId"])
            policy_type = config.get("type", {}).get("id", "").lower()
            if policy_type == "0609b952-1397-4640-95ec-e00a01b2c241" and p["status"] == "approved":
                build_id = context.get("buildId")
                require(type(build_id) is int and build_id > 0, "Azure build policy has no verifiable build")
                build = self.invoke("builds", area="build", project=project_id, repo=False,
                                    route_extra={"buildId": build_id})
                require(build.get("status") == "completed" and build.get("result") == "succeeded" and
                        build.get("repository", {}).get("id") == pr["repository"]["id"] and
                        build.get("sourceVersion") in (head, sha(pr.get("lastMergeCommit", {}).get("commitId"))),
                        "Azure required build did not succeed at the candidate revision")
            if policy_type == "fa4e907d-c16b-4a4c-9dfa-4916e5d171ab":
                settings = config.get("settings", {})
                keys = {"noFastForward": "allowNoFastForward", "squash": "allowSquash",
                        "rebase": "allowRebase", "rebaseMerge": "allowRebaseMerge"}
                require(all(type(settings.get(k)) is bool for k in keys.values()),
                        "unreadable Azure allowed merge strategies")
                methods &= {m for m, k in keys.items() if settings[k]}
        # A PR-scoped status without an iteration cannot prove the revision it
        # checked. Require iteration-bound success rather than guessing from a
        # timestamp or treating a previous iteration's success as current.
        statuses = self.listing("pullRequestStatuses")
        for status_id in required_status_ids:
            matches = [s for s in statuses if s.get("id") == status_id]
            require(len(matches) == 1 and matches[0].get("iterationId") == iteration["id"] and
                    matches[0].get("state") in ("succeeded", "notApplicable"),
                    "Azure status policy does not prove a successful current-iteration check")
        contexts = {}
        for status in statuses:
            context = status.get("context", {})
            require(isinstance(context, dict) and isinstance(context.get("name"), str) and context["name"]
                    and isinstance(context.get("genre", ""), str) and type(status.get("id")) is int,
                    "unreadable Azure check identity")
            key = (context.get("genre", ""), context["name"])
            contexts.setdefault(key, []).append(status)
        for group in contexts.values():
            current = [s for s in group if s.get("iterationId") == iteration["id"]]
            require(current, "Azure PR check has no result bound to the current revision")
            # Azure can retain several status records for a context. A newer
            # current-iteration record supersedes older ones, never vice versa.
            latest = max(group, key=lambda s: s["id"])
            require(latest.get("iterationId") == iteration["id"],
                    "newest Azure check record is not bound to the current revision")
            require(sum(s["id"] == latest["id"] for s in group) == 1,
                    "contradictory Azure check records")
            require(latest.get("state") in ("succeeded", "notApplicable"), "Azure PR check is not successful")
        options = pr.get("completionOptions") or {}
        method = options.get("mergeStrategy")
        if method is None and type(options.get("squashMerge")) is bool:
            method = "squash" if options["squashMerge"] else "noFastForward"
        if method is None and len(methods) == 1:
            method = next(iter(methods))
        require(method in methods, "Azure merge strategy is unset, disallowed or ambiguous; select it on the PR first")
        # Re-read after policy/check reads. PATCH lastMergeSourceCommit
        # provides the server-side source compare-and-swap; normal (non-bypass)
        # completion rechecks current mandatory policies on the server.
        final = self.pr()
        require(final == pr, "Azure PR changed while verifying; retry against its current revision")
        return head, method

    def complete(self):
        head, method = self.verify()
        result = self.invoke("pullRequests", body={
            "status": "completed", "lastMergeSourceCommit": {"commitId": head},
            "completionOptions": {"mergeStrategy": method, "bypassPolicy": False,
                                  "deleteSourceBranch": False, "transitionWorkItems": False}})
        require(str(result.get("pullRequestId")) == self.i.number and
                result.get("status") in ("active", "completed") and
                result.get("lastMergeSourceCommit", {}).get("commitId") == head,
                "Azure completion returned contradictory evidence; landing is unconfirmed")
        # An accepted request is not a landed result. fm-pr-merge.sh persists the
        # authority and retains its poll, then uses a separate landed read.
        print("accepted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("parse", "head", "merged", "landed", "verify", "complete"))
    parser.add_argument("url")
    args = parser.parse_args()
    try:
        identity = Identity(args.url)
        if args.action == "parse":
            print(identity.host, identity.path, identity.number, sep="\n")
            return
        azure = Azure(identity)
        if args.action == "head":
            print(azure.pr()["lastMergeSourceCommit"]["commitId"])
        elif args.action == "merged":
            azure.landed()
            print("merged")
        elif args.action == "landed":
            print(azure.landed())
        elif args.action == "verify":
            print(*azure.verify())
        else:
            azure.complete()
    except (Refused, ValueError, KeyError, TypeError, AttributeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
