use std::{collections::BTreeMap, process::Command};

use serde_json::Value;

mod activity;
mod detail;
mod discussion;
pub(crate) use discussion::load_pull_request_detail;

use activity::*;
use detail::*;

const REVIEW_EXCLUSIONS: &str = "-author:@me -assignee:@me -author:app/dependabot";

const PULL_REQUESTS_QUERY: &str = r#"query($searchQuery: String!, $endCursor: String) {
    search(query: $searchQuery, type: ISSUE, first: 100, after: $endCursor) {
        nodes {
            ... on PullRequest {
                number title url isDraft mergeable repository { nameWithOwner }
                latestCommit: commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }
                latestOpinionatedReviews(first: 100) { nodes { id author { login } state } }
                reviewRequests(first: 100) {
                    nodes { requestedReviewer { ... on User { login } ... on Bot { login } } }
                }
                reviewThreads(first: 100) { nodes { id isResolved } }
            }
        }
        pageInfo { hasNextPage endCursor }
  }
}"#;

const REVIEW_REQUESTS_QUERY: &str = r#"query($searchQuery: String!, $endCursor: String) {
    viewer { login }
    search(query: $searchQuery, type: ISSUE, first: 100, after: $endCursor) {
        nodes {
            ... on PullRequest {
                number title url isDraft repository { nameWithOwner }
                latestCommit: commits(last: 1) { nodes { commit { oid } } }
                latestOpinionatedReviews(first: 100) { nodes { author { login } state } }
            }
        }
        pageInfo { hasNextPage endCursor }
    }
}"#;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ReviewStatus {
    Draft,
    Waiting,
    ChangesRequested,
    Approved,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ReviewDecision {
    Waiting,
    ChangesRequested,
    Approved,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PullRequest {
    pub(crate) repository: String,
    pub(crate) number: u64,
    pub(crate) title: String,
    pub(crate) url: String,
    pub(crate) head_commit: String,
    pub(crate) has_conflicts: bool,
    pub(crate) status: ReviewStatus,
    pub(crate) needs_attention: bool,
    pub(crate) ci_status: Option<String>,
    pub(crate) review_ids: Vec<String>,
    pub(crate) unresolved_thread_ids: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ReviewPullRequest {
    pub(crate) repository: String,
    pub(crate) number: u64,
    pub(crate) title: String,
    pub(crate) url: String,
    pub(crate) head_commit: String,
    pub(crate) my_status: ReviewDecision,
    pub(crate) total_status: ReviewDecision,
    pub(crate) is_review_requested: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PullRequestDetail {
    pub(crate) title: String,
    pub(crate) head_commit: String,
    pub(crate) description: String,
    pub(crate) author: String,
    pub(crate) is_draft: bool,
    pub(crate) review_decision: Option<String>,
    pub(crate) mergeable: Option<String>,
    pub(crate) merge_state_status: Option<String>,
    pub(crate) ci_status: Option<String>,
    pub(crate) reviewers: Vec<PullRequestReview>,
    pub(crate) comments: Vec<PullRequestComment>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PullRequestReview {
    pub(crate) author: String,
    pub(crate) state: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PullRequestComment {
    pub(crate) created_at: Option<String>,
    pub(crate) review_state: Option<String>,
    pub(crate) id: Option<String>,
    pub(crate) url: Option<String>,
    pub(crate) author: String,
    pub(crate) body: String,
    pub(crate) thread: Option<String>,
    pub(crate) resolved: bool,
    pub(crate) path: Option<String>,
    pub(crate) line: Option<u64>,
    pub(crate) diff_hunk: Option<String>,
}

impl PullRequestComment {
    pub(crate) fn feedback_key(&self, index: usize) -> String {
        self.thread
            .clone()
            .or_else(|| self.id.clone())
            .unwrap_or_else(|| format!("comment-{index}"))
    }
}

static TICKET_PROJECTS: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();

/// Restricts ticket-key detection to these Jira project keys (e.g. `["AA4FI"]`).
/// Without a configured list any `ABC-123` shaped token counts as a ticket key.
pub(crate) fn set_ticket_projects(projects: Vec<String>) {
    let _ = TICKET_PROJECTS.set(projects);
}

pub(crate) fn ticket_key_from_title(title: &str) -> Option<String> {
    let projects = TICKET_PROJECTS.get().map(Vec::as_slice).unwrap_or_default();
    ticket_key_in(title, projects)
}

/// Like [`ticket_key_from_title`], but only for configured Jira projects; used
/// where any `ABC-123` shaped word would be a guess (e.g. firstmate task ids).
pub(crate) fn configured_ticket_key(text: &str) -> Option<String> {
    let projects = TICKET_PROJECTS
        .get()
        .filter(|projects| !projects.is_empty())?;
    ticket_key_in(text, projects)
}

fn ticket_key_in(title: &str, projects: &[String]) -> Option<String> {
    let characters = title.char_indices().collect::<Vec<_>>();
    let mut index = 0;
    while index < characters.len() {
        let (start, character) = characters[index];
        let at_boundary = index == 0 || !characters[index - 1].1.is_ascii_alphanumeric();
        if at_boundary && character.is_ascii_uppercase() {
            let mut end = index;
            while end < characters.len()
                && (characters[end].1.is_ascii_uppercase() || characters[end].1.is_ascii_digit())
            {
                end += 1;
            }
            if end < characters.len() && characters[end].1 == '-' {
                let digits_start = end + 1;
                let mut digits_end = digits_start;
                while digits_end < characters.len() && characters[digits_end].1.is_ascii_digit() {
                    digits_end += 1;
                }
                let followed_by_word = characters
                    .get(digits_end)
                    .is_some_and(|(_, character)| character.is_ascii_alphanumeric());
                if digits_end > digits_start && !followed_by_word {
                    let project = &title[start..characters[end].0];
                    if projects.is_empty() || projects.iter().any(|known| known == project) {
                        let key_end = characters
                            .get(digits_end)
                            .map_or(title.len(), |(offset, _)| *offset);
                        return Some(title[start..key_end].to_owned());
                    }
                }
            }
            index = end.max(index + 1);
        } else {
            index += 1;
        }
    }
    None
}

pub(crate) fn load_pull_requests() -> Result<Vec<PullRequest>, String> {
    let mut pull_requests = BTreeMap::new();
    for search in ["is:pr is:open author:@me", "is:pr is:open assignee:@me"] {
        let output = search_pull_requests(PULL_REQUESTS_QUERY, search)?;
        insert_pull_requests(&output, &mut pull_requests)?;
    }
    Ok(pull_requests.into_values().collect())
}

pub(crate) fn load_review_pull_requests() -> Result<Vec<ReviewPullRequest>, String> {
    let mut searches = vec![
        (
            format!("is:pr is:open review-requested:@me {REVIEW_EXCLUSIONS}"),
            true,
        ),
        (
            format!("is:pr is:open reviewed-by:@me {REVIEW_EXCLUSIONS}"),
            false,
        ),
    ];
    searches.extend(load_team_queries()?.into_iter().map(|query| (query, true)));

    let mut pull_requests = BTreeMap::new();
    for (search, review_requested) in searches {
        let output = search_pull_requests(REVIEW_REQUESTS_QUERY, &search)?;
        insert_review_pull_requests(&output, &mut pull_requests, review_requested)?;
    }
    Ok(pull_requests.into_values().collect())
}

fn search_pull_requests(query: &str, search: &str) -> Result<Vec<u8>, String> {
    let output = Command::new("gh")
        .args([
            "api",
            "graphql",
            "--paginate",
            "--slurp",
            "-f",
            &format!("query={query}"),
            "-f",
            &format!("searchQuery={search}"),
        ])
        .output()
        .map_err(|error| format!("Could not run gh: {error}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    Ok(output.stdout)
}

fn load_team_queries() -> Result<Vec<String>, String> {
    let output = Command::new("gh")
        .args(["api", "user/teams", "--paginate", "--slurp"])
        .output()
        .map_err(|error| format!("Could not run gh: {error}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    parse_team_queries(&output.stdout)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_ticket_keys_from_pull_request_titles() {
        assert_eq!(
            ticket_key_from_title("AA4FI-1234 Add ticket linking"),
            Some("AA4FI-1234".into())
        );
        assert_eq!(ticket_key_from_title("No ticket"), None);
        assert_eq!(
            ticket_key_in("fix(ui): AA4FI-12 and KAN-3", &["KAN".into()]),
            Some("KAN-3".into())
        );
        assert_eq!(ticket_key_in("UTF-8 handling", &["AA4FI".into()]), None);
        assert_eq!(
            ticket_key_in("feature/AA4FI-12", &[]),
            Some("AA4FI-12".into())
        );
        assert_eq!(ticket_key_in("xAA4FI-12", &[]), None);
        assert_eq!(ticket_key_in("AA4FI-12a", &[]), None);
    }

    #[test]
    fn parses_statuses_and_deduplicates_authored_and_assigned_prs() {
        let authored = br#"[{"data": {"search": {"nodes": [
                    {"number": 11, "title": "Draft", "url": "https://github.test/a/11", "isDraft": true, "mergeable": "UNKNOWN", "repository": {"nameWithOwner": "org/app"}, "latestCommit": {"nodes": [{"commit": {"oid": "abc123"}}]}, "latestOpinionatedReviews": {"nodes": [{"state": "APPROVED"}]}},
                    {"number": 12, "title": "Ready", "url": "https://github.test/a/12", "isDraft": false, "mergeable": "MERGEABLE", "repository": {"nameWithOwner": "org/app"}, "latestOpinionatedReviews": {"nodes": [{"state": "APPROVED"}]}},
                    {"number": 13, "title": "Needs work", "url": "https://github.test/a/13", "isDraft": false, "mergeable": "CONFLICTING", "repository": {"nameWithOwner": "org/app"}, "latestOpinionatedReviews": {"nodes": [{"state": "APPROVED"}, {"state": "CHANGES_REQUESTED"}]}}
                ]}}}]"#;
        let assigned = br#"[{"data": {"search": {"nodes": [
                    {"number": 12, "title": "Ready", "url": "https://github.test/a/12", "isDraft": false, "mergeable": "MERGEABLE", "repository": {"nameWithOwner": "org/app"}, "latestOpinionatedReviews": {"nodes": [{"state": "APPROVED"}]}},
                    {"number": 2, "title": "Waiting", "url": "https://github.test/b/2", "isDraft": false, "mergeable": "MERGEABLE", "repository": {"nameWithOwner": "org/api"}, "latestOpinionatedReviews": {"nodes": []}}
                ]}}}]"#;
        let mut pull_requests = BTreeMap::new();

        insert_pull_requests(authored, &mut pull_requests).unwrap();
        insert_pull_requests(assigned, &mut pull_requests).unwrap();
        let pull_requests = pull_requests.into_values().collect::<Vec<_>>();

        assert_eq!(pull_requests.len(), 4);
        assert_eq!(pull_requests[0].status, ReviewStatus::Draft);
        assert_eq!(pull_requests[1].status, ReviewStatus::Approved);
        assert_eq!(pull_requests[2].status, ReviewStatus::ChangesRequested);
        assert!(pull_requests[2].has_conflicts);
        assert_eq!(pull_requests[3].status, ReviewStatus::Waiting);
        assert_eq!(pull_requests[0].head_commit, "abc123");
    }

    #[test]
    fn parses_personal_and_total_review_statuses() {
        let response = br#"[{"data": {
            "viewer": {"login": "me"},
            "search": {"nodes": [
                {"number": 1, "title": "Mixed", "url": "https://github.test/a/1", "repository": {"nameWithOwner": "org/app"}, "latestOpinionatedReviews": {"nodes": [
                    {"author": {"login": "me"}, "state": "APPROVED"},
                    {"author": {"login": "other"}, "state": "CHANGES_REQUESTED"}
                ]}, "latestCommit": {"nodes": [{"commit": {"oid": "review123"}}]}},
                {"number": 2, "title": "Approved", "url": "https://github.test/a/2", "repository": {"nameWithOwner": "org/app"}, "latestOpinionatedReviews": {"nodes": [
                    {"author": {"login": "other"}, "state": "APPROVED"}
                ]}},
                {"number": 3, "title": "Waiting", "url": "https://github.test/a/3", "repository": {"nameWithOwner": "org/app"}, "latestOpinionatedReviews": {"nodes": []}}
                ,{"number": 4, "title": "Draft", "url": "https://github.test/a/4", "isDraft": true, "repository": {"nameWithOwner": "org/app"}, "latestOpinionatedReviews": {"nodes": []}}
            ]}
        }}]"#;
        let mut pull_requests = BTreeMap::new();

        insert_review_pull_requests(response, &mut pull_requests, false).unwrap();
        let pull_requests = pull_requests.into_values().collect::<Vec<_>>();

        assert_eq!(pull_requests.len(), 3);
        assert_eq!(pull_requests[0].my_status, ReviewDecision::Approved);
        assert_eq!(
            pull_requests[0].total_status,
            ReviewDecision::ChangesRequested
        );
        assert_eq!(pull_requests[0].head_commit, "review123");
        assert_eq!(pull_requests[1].my_status, ReviewDecision::Waiting);
        assert_eq!(pull_requests[1].total_status, ReviewDecision::Approved);
        assert_eq!(pull_requests[2].total_status, ReviewDecision::Waiting);
    }

    #[test]
    fn rerequested_review_returns_to_waiting() {
        let response = br#"[{"data": {
            "viewer": {"login": "me"},
            "search": {"nodes": [
                {"number": 1, "title": "Review again", "url": "https://github.test/a/1", "repository": {"nameWithOwner": "org/app"}, "latestOpinionatedReviews": {"nodes": [
                    {"author": {"login": "me"}, "state": "APPROVED"}
                ]}}
            ]}
        }}]"#;
        let mut pull_requests = BTreeMap::new();

        insert_review_pull_requests(response, &mut pull_requests, false).unwrap();
        insert_review_pull_requests(response, &mut pull_requests, true).unwrap();

        assert_eq!(
            pull_requests["https://github.test/a/1"].my_status,
            ReviewDecision::Waiting
        );
    }

    #[test]
    fn builds_team_review_searches() {
        let teams = br#"[[
            {"slug": "platform", "organization": {"login": "acme"}},
            {"slug": "reviewers", "organization": {"login": "other"}}
        ]]"#;

        assert_eq!(
            parse_team_queries(teams).unwrap(),
            [
                "is:pr is:open team-review-requested:acme/platform -author:@me -assignee:@me -author:app/dependabot",
                "is:pr is:open team-review-requested:other/reviewers -author:@me -assignee:@me -author:app/dependabot"
            ]
        );
    }
}
