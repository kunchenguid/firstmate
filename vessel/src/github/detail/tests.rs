use super::*;

#[test]
fn includes_review_messages_and_automation_comments() {
    let response = br#"{"data":{"repository":{"pullRequest":{
            "title":"Review feedback","body":"Description",
            "comments":{"nodes":[
                {"author":{"login":"github-actions[bot]"},"body":"Build report"}
            ]},
            "reviews":{"nodes":[
                {"id":"review-1","author":{"login":"reviewer"},"body":"Please handle retries","state":"CHANGES_REQUESTED","submittedAt":"2026-09-14T09:00:00Z"}
            ]},
            "reviewThreads":{"nodes":[]}
        }}}}"#;
    let detail = parse_pull_request_detail(response).unwrap();
    assert_eq!(
        detail
            .comments
            .iter()
            .map(|comment| comment.body.as_str())
            .collect::<Vec<_>>(),
        ["Build report", "Please handle retries"]
    );
}

#[test]
fn parses_pull_request_detail_and_comments() {
    let response = br#"{"data": {"repository": {"pullRequest": {
            "title": "Improve GitHub pages",
            "body": "Show the full pull request description.",
            "latestCommit": {"nodes": [{"commit": {"oid": "detail123", "statusCheckRollup": {"state": "SUCCESS"}}}]},
            "comments": {"nodes": [
                {"author": {"login": "octocat"}, "body": "Looks good."},
                {"author": {"login": "github-actions"}, "body": "Automated result."},
                {"author": null, "body": "Deleted user comment."}
            ]},
            "reviewThreads": {"nodes": [
                {"id": "thread-1", "isResolved": false, "comments": {"nodes": [
                    {"author": {"login": "reviewer"}, "body": "Please change this.", "path": "src/ui.rs", "line": 40, "diffHunk": "@@ -35,8 +35,8 @@\n line 35\n line 36\n line 37\n line 38\n line 39\n+referenced line\n line 41\n line 42"},
                    {"author": {"login": "author"}, "body": "Fixed."},
                    {"author": {"login": "github-actions[bot]"}, "body": "Automated reply."}
                ]}},
                {"id": "thread-file", "isResolved": false, "comments": {"nodes": [
                    {"author": {"login": "reviewer"}, "body": "Whole-file feedback.", "path": "README.md", "line": null, "originalLine": null, "diffHunk": "@@ -1,2 +1,2 @@\n-old\n+new"}
                ]}},
                {"id": "thread-2", "isResolved": true, "comments": {"nodes": [
                    {"author": {"login": "reviewer"}, "body": "Old resolved feedback."}
                ]}}
            ]}
        }}}}"#;

    let detail = parse_pull_request_detail(response).unwrap();

    assert_eq!(detail.title, "Improve GitHub pages");
    assert_eq!(detail.head_commit, "detail123");
    assert_eq!(
        detail.description,
        "Show the full pull request description."
    );
    assert_eq!(detail.comments.len(), 8);
    assert_eq!(detail.comments[0].author, "octocat");
    assert_eq!(detail.comments[2].author, "unknown");
    assert_eq!(detail.comments[3].thread.as_deref(), Some("thread-1"));
    assert_eq!(detail.comments[4].thread.as_deref(), Some("thread-1"));
    assert_eq!(detail.comments[3].path.as_deref(), Some("src/ui.rs"));
    assert_eq!(detail.comments[3].line, Some(40));
    assert_eq!(
        detail.comments[3].diff_hunk.as_deref(),
        Some(" line 35\n line 36\n line 37\n line 38\n line 39\n+referenced line")
    );
    assert_eq!(detail.comments[6].path.as_deref(), Some("README.md"));
    assert_eq!(detail.comments[6].line, None);
    assert_eq!(detail.comments[6].diff_hunk, None);
    assert!(detail.comments[7].resolved);
    assert_eq!(detail.comments[7].body, "Old resolved feedback.");
    assert_eq!(detail.comments[1].body, "Automated result.");
    assert_eq!(detail.comments[5].body, "Automated reply.");
}

#[test]
fn groups_directly_addressed_standalone_comments() {
    let response = br#"{"data":{"repository":{"pullRequest":{
            "title":"Title","body":"Body",
            "comments":{"nodes":[
                {"author":{"login":"reviewer"},"body":"Please check this."},
                {"author":{"login":"author"},"body":"@Reviewer Fixed in the latest push."},
                {"author":{"login":"reviewer"},"body":"@author Thanks, that works."},
                {"author":{"login":"author"},"body":"@reviewer-two Can you also take a look?"}
            ]},
            "reviewThreads":{"nodes":[]}
        }}}}"#;

    let detail = parse_pull_request_detail(response).unwrap();

    assert_eq!(detail.comments.len(), 4);
    assert_eq!(detail.comments[0].thread, detail.comments[1].thread);
    assert_eq!(detail.comments[1].thread, detail.comments[2].thread);
    assert!(
        detail.comments[0]
            .thread
            .as_deref()
            .is_some_and(is_inferred_comment_chain)
    );
    assert_eq!(detail.comments[3].thread, None);
}

#[test]
fn groups_standalone_comments_that_quote_their_parent() {
    let response = br#"{"data":{"repository":{"pullRequest":{
            "title":"Title","body":"Body",
            "comments":{"nodes":[
                {"author":{"login":"copilot"},"body":"> @copilot Please review this PR.\n\nThe target branch is ambiguous."},
                {"author":{"login":"author"},"body":"> > @copilot Please review this PR.\n>\n> The target branch is ambiguous.\n\nAny PR directed at main should be up to date with main."}
            ]},
            "reviewThreads":{"nodes":[]}
        }}}}"#;

    let detail = parse_pull_request_detail(response).unwrap();

    assert_eq!(detail.comments[0].thread, detail.comments[1].thread);
    assert!(
        detail.comments[0]
            .thread
            .as_deref()
            .is_some_and(is_inferred_comment_chain)
    );
}

#[test]
fn keeps_chronological_conversations_and_submitted_review_states() {
    let response = br#"{"data":{"repository":{"pullRequest":{
        "title":"Timeline","body":"Description",
        "comments":{"nodes":[{"id":"issue","body":"Later issue comment","createdAt":"2026-09-14T11:00:00Z"}]},
        "reviews":{"nodes":[
            {"id":"review","body":"","state":"APPROVED","submittedAt":"2026-09-14T10:00:00Z"},
            {"id":"draft","body":"Not submitted","state":"PENDING","submittedAt":null}
        ]},
        "reviewThreads":{"nodes":[{"id":"thread","isResolved":true,"comments":{"nodes":[
            {"id":"root","body":"Earlier inline comment","createdAt":"2026-09-14T09:00:00Z"},
            {"id":"reply","body":"Later reply stays in its thread","createdAt":"2026-09-14T12:00:00Z"}
        ]}}]}
    }}}}"#;
    let detail = parse_pull_request_detail(response).unwrap();
    assert_eq!(
        detail
            .comments
            .iter()
            .map(|comment| comment.id.as_deref().unwrap())
            .collect::<Vec<_>>(),
        ["root", "reply", "review", "issue"]
    );
    assert_eq!(detail.comments[2].review_state.as_deref(), Some("APPROVED"));
    assert!(detail.comments[0].resolved);
    assert!(detail.comments[1].resolved);
}
