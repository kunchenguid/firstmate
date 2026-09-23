use super::*;

#[cfg(test)]
mod tests;

pub(super) fn parse_team_queries(json: &[u8]) -> Result<Vec<String>, String> {
    let pages: Value = serde_json::from_slice(json)
        .map_err(|error| format!("Could not parse GitHub teams: {error}"))?;
    let pages = pages
        .as_array()
        .ok_or_else(|| "GitHub returned an unexpected teams response".to_string())?;
    let mut queries = Vec::new();
    for team in pages.iter().filter_map(Value::as_array).flatten() {
        let organization = team
            .pointer("/organization/login")
            .and_then(Value::as_str)
            .ok_or_else(|| "A GitHub team has no organization".to_string())?;
        let slug = string_field(team, "slug")?;
        queries.push(format!(
            "is:pr is:open team-review-requested:{organization}/{slug} {REVIEW_EXCLUSIONS}"
        ));
    }
    Ok(queries)
}

pub(super) fn insert_review_pull_requests(
    json: &[u8],
    pull_requests: &mut BTreeMap<String, ReviewPullRequest>,
    review_requested: bool,
) -> Result<(), String> {
    let pages: Value = serde_json::from_slice(json)
        .map_err(|error| format!("Could not parse GitHub response: {error}"))?;
    let pages = pages
        .as_array()
        .ok_or_else(|| "GitHub returned an unexpected response".to_string())?;
    for page in pages {
        let viewer = page
            .pointer("/data/viewer/login")
            .and_then(Value::as_str)
            .ok_or_else(|| "GitHub returned no viewer login".to_string())?;
        let nodes = page
            .pointer("/data/search/nodes")
            .and_then(Value::as_array)
            .ok_or_else(|| "GitHub returned an unexpected response".to_string())?;
        for node in nodes {
            if node.get("isDraft").and_then(Value::as_bool) == Some(true) {
                continue;
            }
            let reviews = node
                .pointer("/latestOpinionatedReviews/nodes")
                .and_then(Value::as_array)
                .ok_or_else(|| "A GitHub pull request has no reviews".to_string())?;
            let decisions = reviews
                .iter()
                .filter_map(|review| {
                    let author = review.pointer("/author/login")?.as_str()?;
                    let decision = match review.get("state")?.as_str()? {
                        "APPROVED" => ReviewDecision::Approved,
                        "CHANGES_REQUESTED" => ReviewDecision::ChangesRequested,
                        _ => return None,
                    };
                    Some((author, decision))
                })
                .collect::<Vec<_>>();
            let my_status = decisions
                .iter()
                .find(|(author, _)| author.eq_ignore_ascii_case(viewer))
                .map(|(_, decision)| *decision)
                .unwrap_or(ReviewDecision::Waiting);
            let total_status = if decisions
                .iter()
                .any(|(_, decision)| *decision == ReviewDecision::ChangesRequested)
            {
                ReviewDecision::ChangesRequested
            } else if decisions
                .iter()
                .any(|(_, decision)| *decision == ReviewDecision::Approved)
            {
                ReviewDecision::Approved
            } else {
                ReviewDecision::Waiting
            };
            let url = string_field(node, "url")?;
            pull_requests
                .entry(url.clone())
                .and_modify(|pull_request| {
                    if review_requested {
                        pull_request.my_status = ReviewDecision::Waiting;
                        pull_request.is_review_requested = true;
                    }
                })
                .or_insert(ReviewPullRequest {
                    repository: node
                        .pointer("/repository/nameWithOwner")
                        .and_then(Value::as_str)
                        .ok_or_else(|| "A GitHub pull request has no repository".to_string())?
                        .into(),
                    number: node
                        .get("number")
                        .and_then(Value::as_u64)
                        .ok_or_else(|| "A GitHub pull request has no number".to_string())?,
                    title: string_field(node, "title")?,
                    url,
                    head_commit: node
                        .pointer("/latestCommit/nodes/0/commit/oid")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .into(),
                    my_status: if review_requested {
                        ReviewDecision::Waiting
                    } else {
                        my_status
                    },
                    total_status,
                    is_review_requested: review_requested,
                });
        }
    }
    Ok(())
}

pub(super) fn insert_pull_requests(
    json: &[u8],
    pull_requests: &mut BTreeMap<String, PullRequest>,
) -> Result<(), String> {
    let pages: Value = serde_json::from_slice(json)
        .map_err(|error| format!("Could not parse GitHub response: {error}"))?;
    let pages = pages
        .as_array()
        .ok_or_else(|| "GitHub returned an unexpected response".to_string())?;
    for page in pages {
        let nodes = page
            .pointer("/data/search/nodes")
            .and_then(Value::as_array)
            .ok_or_else(|| "GitHub returned an unexpected response".to_string())?;
        for node in nodes {
            let url = string_field(node, "url")?;
            let reviews = node
                .pointer("/latestOpinionatedReviews/nodes")
                .and_then(Value::as_array)
                .ok_or_else(|| "A GitHub pull request has no reviews".to_string())?;
            let review_ids: Vec<String> = reviews
                .iter()
                .filter(|review| {
                    review.get("state").and_then(Value::as_str) == Some("CHANGES_REQUESTED")
                })
                .filter_map(|review| review.get("id").and_then(Value::as_str).map(str::to_owned))
                .collect();
            let unresolved_thread_ids: Vec<String> = node
                .pointer("/reviewThreads/nodes")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|thread| thread.get("isResolved").and_then(Value::as_bool) != Some(true))
                .filter_map(|thread| thread.get("id").and_then(Value::as_str).map(str::to_owned))
                .collect();
            pull_requests.entry(url.clone()).or_insert(PullRequest {
                repository: node
                    .pointer("/repository/nameWithOwner")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "A GitHub pull request has no repository".to_string())?
                    .into(),
                number: node
                    .get("number")
                    .and_then(Value::as_u64)
                    .ok_or_else(|| "A GitHub pull request has no number".to_string())?,
                title: string_field(node, "title")?,
                url,
                head_commit: node
                    .pointer("/latestCommit/nodes/0/commit/oid")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .into(),
                has_conflicts: node.get("mergeable").and_then(Value::as_str) == Some("CONFLICTING"),
                needs_attention: node.get("isDraft").and_then(Value::as_bool) == Some(true)
                    || reviews.iter().any(|review| {
                        review.get("state").and_then(Value::as_str) == Some("CHANGES_REQUESTED")
                            && !review_is_requested_again(node, review)
                    }),
                status: if node.get("isDraft").and_then(Value::as_bool) == Some(true) {
                    ReviewStatus::Draft
                } else if reviews.iter().any(|review| {
                    review.get("state").and_then(Value::as_str) == Some("CHANGES_REQUESTED")
                }) {
                    ReviewStatus::ChangesRequested
                } else if reviews
                    .iter()
                    .any(|review| review.get("state").and_then(Value::as_str) == Some("APPROVED"))
                {
                    ReviewStatus::Approved
                } else {
                    ReviewStatus::Waiting
                },
                ci_status: node
                    .pointer("/latestCommit/nodes/0/commit/statusCheckRollup/state")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                review_ids,
                unresolved_thread_ids,
            });
        }
    }
    Ok(())
}

fn review_is_requested_again(pull_request: &Value, review: &Value) -> bool {
    let Some(author) = review.pointer("/author/login").and_then(Value::as_str) else {
        return false;
    };
    // A pending request hands this reviewer's feedback back to them, even while
    // GitHub still reports their previous CHANGES_REQUESTED decision.
    pull_request
        .pointer("/reviewRequests/nodes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .any(|request| {
            request
                .pointer("/requestedReviewer/login")
                .and_then(Value::as_str)
                .is_some_and(|reviewer| reviewer.eq_ignore_ascii_case(author))
        })
}
