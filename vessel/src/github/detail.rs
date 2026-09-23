use super::*;

#[cfg(test)]
mod tests;

pub(super) fn parse_pull_request_detail(json: &[u8]) -> Result<PullRequestDetail, String> {
    let response: Value = serde_json::from_slice(json)
        .map_err(|error| format!("Could not parse GitHub pull request: {error}"))?;
    let pull_request = response
        .pointer("/data/repository/pullRequest")
        .ok_or_else(|| "GitHub returned no pull request detail".to_string())?;
    let mut comments = pull_request
        .pointer("/comments/nodes")
        .and_then(Value::as_array)
        .ok_or_else(|| "GitHub returned no pull request comments".to_string())?
        .iter()
        .map(|comment| parse_pull_request_comment(comment, None, false))
        .collect::<Result<Vec<_>, String>>()?;
    for index in 1..comments.len() {
        let parent = index - 1;
        let parent_is_standalone = comments[parent]
            .thread
            .as_deref()
            .is_none_or(is_inferred_comment_chain);
        let is_reply = parent_is_standalone
            && comments[index].thread.is_none()
            && (quotes_comment(&comments[index].body, &comments[parent].body)
                || starts_with_author_mention(&comments[index].body, &comments[parent].author));
        if is_reply {
            let chain = comments[parent].thread.clone().unwrap_or_else(|| {
                format!(
                    "inferred-comment-chain-{}",
                    comments[parent].feedback_key(parent)
                )
            });
            comments[parent].thread = Some(chain.clone());
            comments[index].thread = Some(chain);
        }
    }
    let review_threads = pull_request
        .pointer("/reviewThreads/nodes")
        .and_then(Value::as_array)
        .ok_or_else(|| "GitHub returned no pull request review threads".to_string())?;
    for thread in review_threads {
        let resolved = thread
            .get("isResolved")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let id = string_field(thread, "id")?;
        let thread_comments = thread
            .pointer("/comments/nodes")
            .and_then(Value::as_array)
            .ok_or_else(|| "GitHub returned an invalid pull request review thread".to_string())?;
        comments.extend(
            thread_comments
                .iter()
                .map(|comment| parse_pull_request_comment(comment, Some(id.clone()), resolved))
                .collect::<Result<Vec<_>, String>>()?,
        );
    }
    for review in pull_request
        .pointer("/reviews/nodes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        if review.get("state").and_then(Value::as_str) != Some("PENDING") {
            comments.push(parse_pull_request_comment(review, None, false)?);
        }
    }
    // Sort conversations by their first message, keeping every thread's replies together.
    let mut groups: Vec<Vec<PullRequestComment>> = Vec::new();
    for comment in comments {
        if comment.thread.is_some()
            && groups
                .last()
                .is_some_and(|group| group[0].thread == comment.thread)
        {
            groups.last_mut().unwrap().push(comment);
        } else {
            groups.push(vec![comment]);
        }
    }
    groups.sort_by(|left, right| left[0].created_at.cmp(&right[0].created_at));
    let comments = groups.into_iter().flatten().collect();
    Ok(PullRequestDetail {
        title: string_field(pull_request, "title")?,
        head_commit: pull_request
            .pointer("/latestCommit/nodes/0/commit/oid")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .into(),
        description: string_field(pull_request, "body")?,
        author: pull_request
            .pointer("/author/login")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .into(),
        is_draft: pull_request
            .get("isDraft")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        review_decision: pull_request
            .get("reviewDecision")
            .and_then(Value::as_str)
            .map(str::to_owned),
        mergeable: pull_request
            .get("mergeable")
            .and_then(Value::as_str)
            .map(str::to_owned),
        merge_state_status: pull_request
            .get("mergeStateStatus")
            .and_then(Value::as_str)
            .map(str::to_owned),
        ci_status: pull_request
            .pointer("/latestCommit/nodes/0/commit/statusCheckRollup/state")
            .and_then(Value::as_str)
            .map(str::to_owned),
        reviewers: pull_request
            .pointer("/latestOpinionatedReviews/nodes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .map(|review| PullRequestReview {
                author: review
                    .pointer("/author/login")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
                    .into(),
                state: review
                    .get("state")
                    .and_then(Value::as_str)
                    .unwrap_or("UNKNOWN")
                    .into(),
            })
            .collect(),
        comments,
    })
}

fn starts_with_author_mention(body: &str, author: &str) -> bool {
    body.trim_start()
        .strip_prefix('@')
        .and_then(|body| {
            body.split(|character: char| !character.is_ascii_alphanumeric() && character != '-')
                .next()
        })
        .is_some_and(|mention| mention.eq_ignore_ascii_case(author))
}

pub(super) fn quotes_comment(body: &str, parent: &str) -> bool {
    let mut quote = String::new();
    for line in body.trim_start().lines() {
        let Some(line) = line.strip_prefix('>') else {
            break;
        };
        quote.push_str(line.strip_prefix(' ').unwrap_or(line));
        quote.push('\n');
    }
    !quote.is_empty() && quote.trim_end() == parent.trim()
}

pub(super) fn is_inferred_comment_chain(thread: &str) -> bool {
    thread.starts_with("inferred-comment-chain-")
}

fn parse_pull_request_comment(
    comment: &Value,
    thread: Option<String>,
    resolved: bool,
) -> Result<PullRequestComment, String> {
    let author = comment
        .pointer("/author/login")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let current_line = comment.get("line").and_then(Value::as_u64);
    let original_line = comment.get("originalLine").and_then(Value::as_u64);
    let line = current_line.or(original_line);
    let diff_hunk = line.and_then(|line| {
        comment
            .get("diffHunk")
            .and_then(Value::as_str)
            .and_then(|diff_hunk| referenced_diff_context(diff_hunk, line, current_line.is_none()))
    });
    Ok(PullRequestComment {
        created_at: comment
            .get("submittedAt")
            .or_else(|| comment.get("createdAt"))
            .and_then(Value::as_str)
            .map(str::to_owned),
        review_state: comment
            .get("state")
            .and_then(Value::as_str)
            .map(str::to_owned),
        id: comment.get("id").and_then(Value::as_str).map(str::to_owned),
        url: comment
            .get("url")
            .and_then(Value::as_str)
            .map(str::to_owned),
        author: author.into(),
        body: string_field(comment, "body")?,
        thread,
        resolved,
        path: comment
            .get("path")
            .and_then(Value::as_str)
            .map(str::to_owned),
        line,
        diff_hunk,
    })
}

fn referenced_diff_context(diff_hunk: &str, target: u64, original: bool) -> Option<String> {
    let mut lines = diff_hunk.lines();
    let header = lines.next()?;
    let range = header
        .split_whitespace()
        .nth(if original { 1 } else { 2 })?;
    let mut line_number = range
        .trim_start_matches(&['+', '-'][..])
        .split(',')
        .next()?
        .parse::<u64>()
        .ok()?;
    let mut context = Vec::new();
    for line in lines {
        let marker = line.as_bytes().first().copied();
        let consumes_line = if original {
            matches!(marker, Some(b' ' | b'-'))
        } else {
            matches!(marker, Some(b' ' | b'+'))
        };
        if consumes_line && line_number == target {
            context.push(line);
            return Some(context.join("\n"));
        }
        if matches!(marker, Some(b' ' | b'+' | b'-')) {
            context.push(line);
            if context.len() > 5 {
                context.remove(0);
            }
        }
        if consumes_line {
            line_number += 1;
        }
    }
    None
}

pub(super) fn string_field(value: &Value, field: &str) -> Result<String, String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| format!("A GitHub pull request has no {field}"))
}
