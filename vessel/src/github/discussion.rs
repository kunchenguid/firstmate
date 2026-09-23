use std::process::Command;

use serde_json::{Value, json};

use super::{PullRequestDetail, detail::parse_pull_request_detail};

#[cfg(test)]
mod tests;

const COMMENT_FIELDS: &str = "id url author { login } body createdAt";
const REVIEW_FIELDS: &str = "id url author { login } body submittedAt state";
const INLINE_FIELDS: &str =
    "id url author { login } body createdAt path line originalLine diffHunk";
const PAGE_INFO: &str = "pageInfo { hasNextPage endCursor }";

pub(crate) fn load_pull_request_detail(
    repository: &str,
    number: u64,
) -> Result<PullRequestDetail, String> {
    load_detail(repository, number, &mut graphql)
}

fn graphql(query: &str, variables: Value) -> Result<Value, String> {
    let mut command = Command::new("gh");
    command.args(["api", "graphql", "-f", &format!("query={query}")]);
    for (key, value) in variables.as_object().unwrap() {
        if let Some(value) = value.as_str() {
            command.args(["-f", &format!("{key}={value}")]);
        } else {
            command.args(["-F", &format!("{key}={value}")]);
        }
    }
    let output = command
        .output()
        .map_err(|error| format!("Could not run gh: {error}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("Could not parse GitHub pull request: {error}"))
}

fn load_detail(
    repository: &str,
    number: u64,
    request: &mut impl FnMut(&str, Value) -> Result<Value, String>,
) -> Result<PullRequestDetail, String> {
    let (owner, name) = repository
        .split_once('/')
        .ok_or_else(|| format!("Invalid GitHub repository: {repository}"))?;
    let thread_fields =
        format!("id isResolved comments(first: 100) {{ nodes {{ {INLINE_FIELDS} }} {PAGE_INFO} }}");
    let query = format!(
        r#"query($owner: String!, $name: String!, $number: Int!) {{
        repository(owner: $owner, name: $name) {{
            pullRequest(number: $number) {{
                id title body isDraft reviewDecision mergeable mergeStateStatus
                author {{ login }}
                latestCommit: commits(last: 1) {{ nodes {{ commit {{ oid statusCheckRollup {{ state }} }} }} }}
                latestOpinionatedReviews(first: 100) {{ nodes {{ author {{ login }} state }} }}
                comments(first: 100) {{ nodes {{ {COMMENT_FIELDS} }} {PAGE_INFO} }}
                reviews(first: 100) {{ nodes {{ {REVIEW_FIELDS} }} {PAGE_INFO} }}
                reviewThreads(first: 100) {{ nodes {{ {thread_fields} }} {PAGE_INFO} }}
            }}
        }}
    }}"#
    );
    let mut response = request(
        &query,
        json!({"owner": owner, "name": name, "number": number}),
    )?;
    check_errors(&response)?;
    let pr = response
        .pointer_mut("/data/repository/pullRequest")
        .filter(|pr| pr.is_object())
        .ok_or_else(|| "GitHub returned no pull request detail".to_string())?;
    let id = super::detail::string_field(pr, "id")?;
    for (field, fields) in [
        ("comments", COMMENT_FIELDS),
        ("reviews", REVIEW_FIELDS),
        ("reviewThreads", thread_fields.as_str()),
    ] {
        complete_connection(&id, "PullRequest", field, fields, &mut pr[field], request)?;
    }
    for thread in pr["reviewThreads"]["nodes"].as_array_mut().unwrap() {
        let id = super::detail::string_field(thread, "id")?;
        complete_connection(
            &id,
            "PullRequestReviewThread",
            "comments",
            INLINE_FIELDS,
            &mut thread["comments"],
            request,
        )?;
    }
    parse_pull_request_detail(&serde_json::to_vec(&response).map_err(|error| error.to_string())?)
}

fn complete_connection(
    id: &str,
    node_type: &str,
    field: &str,
    fields: &str,
    connection: &mut Value,
    request: &mut impl FnMut(&str, Value) -> Result<Value, String>,
) -> Result<(), String> {
    let query = format!(
        r#"query($id: ID!, $endCursor: String!) {{
        node(id: $id) {{ ... on {node_type} {{
            {field}(first: 100, after: $endCursor) {{ nodes {{ {fields} }} {PAGE_INFO} }}
        }} }}
    }}"#
    );
    let mut page = connection.take();
    let mut nodes = Vec::new();
    let mut seen_cursors = std::collections::BTreeSet::new();
    loop {
        let page_nodes = page
            .get_mut("nodes")
            .and_then(Value::as_array_mut)
            .ok_or_else(|| format!("GitHub returned invalid {field}"))?;
        nodes.append(page_nodes);
        let has_next = page
            .pointer("/pageInfo/hasNextPage")
            .and_then(Value::as_bool)
            .ok_or_else(|| format!("GitHub returned no pagination information for {field}"))?;
        if !has_next {
            page["nodes"] = Value::Array(nodes);
            *connection = page;
            return Ok(());
        }
        let cursor = page
            .pointer("/pageInfo/endCursor")
            .and_then(Value::as_str)
            .filter(|cursor| !cursor.is_empty())
            .ok_or_else(|| format!("GitHub returned no next cursor for {field}"))?;
        if !seen_cursors.insert(cursor.to_owned()) {
            return Err(format!("GitHub repeated a pagination cursor for {field}"));
        }
        let mut response = request(&query, json!({"id": id, "endCursor": cursor}))?;
        check_errors(&response)?;
        page = response
            .pointer_mut(&format!("/data/node/{field}"))
            .ok_or_else(|| format!("GitHub returned no {field} page"))?
            .take();
    }
}

fn check_errors(response: &Value) -> Result<(), String> {
    if let Some(errors) = response.get("errors").and_then(Value::as_array)
        && !errors.is_empty()
    {
        return Err(format!(
            "GitHub could not load the full discussion: {}",
            errors
                .iter()
                .filter_map(|error| error.get("message").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("; ")
        ));
    }
    Ok(())
}
