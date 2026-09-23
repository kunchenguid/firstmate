use super::*;
use serde_json::json;

fn response(draft: bool, reviews: Value, requests: &[&str]) -> Vec<u8> {
    serde_json::to_vec(&json!([{"data": {
        "viewer": {"login": "me"},
        "search": {"nodes": [{
            "number": 42, "title": "Review this", "url": "https://github.test/org/app/42",
            "repository": {"nameWithOwner": "org/app"}, "isDraft": draft,
            "latestOpinionatedReviews": {"nodes": reviews},
            "reviewRequests": {"nodes": requests.iter().map(|login| {
                json!({"requestedReviewer": {"login": login}})
            }).collect::<Vec<_>>()}
        }]}
    }}]))
    .unwrap()
}

#[test]
fn own_pull_requests_need_attention_for_drafts_and_changes_awaiting_a_response() {
    let review = |author, state| json!({"author": {"login": author}, "state": state});
    let changes = review("alice", "CHANGES_REQUESTED");
    let cases = [
        (true, json!([]), vec![], true),
        (false, json!([]), vec![], false),
        (false, json!([review("alice", "APPROVED")]), vec![], false),
        (false, json!([changes]), vec![], true),
        (false, json!([changes]), vec!["ALICE"], false),
        (false, json!([changes]), vec!["bob"], true),
        (true, json!([changes]), vec!["alice"], true),
        (
            false,
            json!([changes, review("bob", "CHANGES_REQUESTED")]),
            vec!["alice"],
            true,
        ),
        (
            false,
            json!([changes, review("bob", "CHANGES_REQUESTED")]),
            vec!["alice", "bob"],
            false,
        ),
        (
            false,
            json!([{"state": "CHANGES_REQUESTED"}]),
            vec!["alice"],
            true,
        ),
    ];
    for (draft, reviews, requests, expected) in cases {
        let response = response(draft, reviews, &requests);
        let mut pull_requests = BTreeMap::new();
        insert_pull_requests(&response, &mut pull_requests).unwrap();
        assert_eq!(
            pull_requests.values().next().unwrap().needs_attention,
            expected,
            "{}",
            String::from_utf8_lossy(&response)
        );
    }
}

#[test]
fn rerequests_preserve_the_total_decision_but_change_whose_attention_is_needed() {
    for (state, decision) in [
        ("APPROVED", ReviewDecision::Approved),
        ("CHANGES_REQUESTED", ReviewDecision::ChangesRequested),
    ] {
        let response = response(
            false,
            json!([{
                "author": {"login": "me"}, "state": state
            }]),
            &["me"],
        );
        let mut pull_requests = BTreeMap::new();
        insert_review_pull_requests(&response, &mut pull_requests, false).unwrap();
        assert_eq!(pull_requests.values().next().unwrap().my_status, decision);

        // Search results can overlap; a re-request must win in either order.
        for searches in [[true, false], [false, true]] {
            let mut pull_requests = BTreeMap::new();
            for requested in searches {
                insert_review_pull_requests(&response, &mut pull_requests, requested).unwrap();
            }
            let pull_request = pull_requests.values().next().unwrap();
            assert_eq!(pull_request.my_status, ReviewDecision::Waiting);
            assert_eq!(pull_request.total_status, decision);
        }

        if state == "CHANGES_REQUESTED" {
            let mut pull_requests = BTreeMap::new();
            insert_pull_requests(&response, &mut pull_requests).unwrap();
            let pull_request = pull_requests.values().next().unwrap();
            assert_eq!(pull_request.status, ReviewStatus::ChangesRequested);
            assert!(!pull_request.needs_attention);
        }
    }
}
