use super::*;

fn page(nodes: Vec<Value>, cursor: Option<&str>) -> Value {
    json!({"nodes": nodes, "pageInfo": {"hasNextPage": cursor.is_some(), "endCursor": cursor}})
}

fn comment(id: &str) -> Value {
    json!({"id": id, "author": {"login": "reviewer"}, "body": id})
}

fn thread(id: &str, comments: Value) -> Value {
    json!({"id": id, "isResolved": false, "comments": comments})
}

#[test]
fn loads_every_page_of_comments_reviews_threads_and_nested_replies() {
    let comments = (0..100).map(|n| comment(&format!("issue-{n}"))).collect();
    let reviews = (0..100)
        .map(|n| {
            let mut review = comment(&format!("review-{n}"));
            review["state"] = json!("COMMENTED");
            review
        })
        .collect();
    let mut threads = vec![thread(
        "thread-0",
        page(
            (0..100).map(|n| comment(&format!("reply-{n}"))).collect(),
            Some("replies-next"),
        ),
    )];
    threads.extend((1..100).map(|n| {
        thread(
            &format!("thread-{n}"),
            page(vec![comment(&format!("inline-{n}"))], None),
        )
    }));
    let first = json!({"data": {"repository": {"pullRequest": {
        "id": "pr-1", "title": "Large discussion", "body": "Description",
        "comments": page(comments, Some("issues-next")),
        "reviews": page(reviews, Some("reviews-next")),
        "reviewThreads": page(threads, Some("threads-next"))
    }}}});
    let detail = load_detail("org/repo", 42, &mut |_, variables| {
        let (field, next) = match variables["endCursor"].as_str() {
            None => return Ok(first.clone()),
            Some("issues-next") => ("comments", page(vec![comment("last-issue")], None)),
            Some("reviews-next") => (
                "reviews",
                page(
                    vec![json!({"id": "last-review", "body": "Final review", "state": "APPROVED"})],
                    None,
                ),
            ),
            Some("threads-next") => (
                "reviewThreads",
                page(
                    vec![thread(
                        "last-thread",
                        page(vec![comment("last-thread-root")], Some("last-thread-next")),
                    )],
                    None,
                ),
            ),
            Some("replies-next") => ("comments", page(vec![comment("last-reply")], None)),
            Some("last-thread-next") => {
                ("comments", page(vec![comment("last-thread-reply")], None))
            }
            other => panic!("Unexpected cursor: {other:?}"),
        };
        Ok(json!({"data": {"node": {field: next}}}))
    })
    .unwrap();
    assert_eq!(detail.comments.len(), 404);
    for body in [
        "last-issue",
        "Final review",
        "last-thread-root",
        "last-reply",
        "last-thread-reply",
    ] {
        assert_eq!(
            detail
                .comments
                .iter()
                .filter(|comment| comment.body == body)
                .count(),
            1,
            "{body}"
        );
    }
    let last_reply = detail
        .comments
        .iter()
        .find(|comment| comment.body == "last-reply")
        .unwrap();
    assert_eq!(last_reply.thread.as_deref(), Some("thread-0"));
    assert_eq!(
        detail
            .comments
            .iter()
            .filter(|comment| comment.thread.as_deref() == Some("thread-0"))
            .count(),
        101
    );
    assert_eq!(
        detail
            .comments
            .iter()
            .find(|comment| comment.body == "Final review")
            .unwrap()
            .review_state
            .as_deref(),
        Some("APPROVED")
    );
}

#[test]
fn reports_partial_responses_and_failed_pages_instead_of_silently_truncating() {
    let error = load_detail("org/repo", 42, &mut |_, _| Ok(json!({
        "data": {"repository": {"pullRequest": null}}, "errors": [{"message": "Rate limit exceeded"}]
    }))).unwrap_err();
    assert!(error.contains("Rate limit exceeded"));
    for next in [
        Err("Connection lost".to_string()),
        Ok(json!({"data": {"node": {"comments": page(vec![comment("reply")], Some("next"))}}})),
    ] {
        let error = load_detail("org/repo", 42, &mut |_, variables| {
            if variables["endCursor"].is_string() {
                return next.clone();
            }
            Ok(json!({"data": {"repository": {"pullRequest": {
                "id": "pr-1", "comments": page(vec![comment("first")], Some("next"))
            }}}}))
        })
        .unwrap_err();
        assert!(
            error.contains("Connection lost") || error.contains("repeated a pagination cursor"),
            "{error}"
        );
    }
}
