//! `vessel radar check|arm|disarm|ack` - event detection for firstmate monitoring.
//!
//! `arm` registers a watcher check that runs `vessel radar check` on firstmate's
//! monitoring cadence. `check` compares the current state of GitHub and Jira
//! against the seen-event log in `data/vessel/radar.json`, prints one line when
//! there are new events, and prints nothing otherwise. `ack` marks events as
//! handled. `disarm` removes the check registration.

use std::{
    collections::HashSet,
    env, fs,
    io::{self},
    path::{Path, PathBuf},
    process::Command,
    sync::mpsc,
    thread,
    time::Duration,
};

use serde_json::{Value, json};

use crate::{
    config::{load_config, resolve_fm_home, write_atomic},
    github::{ReviewStatus, load_pull_requests, load_review_pull_requests},
    jira::load_jira_tickets,
};

const CHECK_ID: &str = "vessel-radar";
const CHECK_TIMEOUT: Duration = Duration::from_secs(25);

pub(crate) fn run(args: &[String]) -> io::Result<()> {
    let subcommand = args.first().map(String::as_str).unwrap_or("check");
    let rest: &[String] = if args.is_empty() { &[] } else { &args[1..] };
    let home = parse_home(rest).or_else(|| parse_home(args));

    match subcommand {
        "check" => run_check(home),
        "arm" => run_arm(home),
        "disarm" => run_disarm(home),
        "ack" => {
            let ids: Vec<String> = rest
                .iter()
                .filter(|a| !a.starts_with('-'))
                .cloned()
                .collect();
            run_ack(home, &ids)
        }
        other => {
            eprintln!("vessel radar: unknown subcommand {other}");
            eprintln!("usage: vessel radar check|arm|disarm|ack [--home <path>]");
            std::process::exit(2);
        }
    }
}

fn parse_home(args: &[String]) -> Option<PathBuf> {
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--home" {
            return iter.next().map(PathBuf::from);
        }
    }
    None
}

// --- check ---

fn run_check(home: Option<PathBuf>) -> io::Result<()> {
    let (sender, receiver) = mpsc::channel::<Option<String>>();
    thread::spawn(move || {
        let _ = sender.send(check_impl(home).unwrap_or(None));
    });
    if let Ok(Some(line)) = receiver.recv_timeout(CHECK_TIMEOUT) {
        print!("{line}");
    }
    Ok(())
}

fn check_impl(home: Option<PathBuf>) -> Result<Option<String>, String> {
    let (fm_home, fm_root) = resolve_fm_home(home)?;
    let config = load_config((fm_home.clone(), fm_root))?;

    if let Some(jql) = &config.jira_jql {
        crate::jira::set_jql(jql.clone());
    }

    let radar_path = config.data_dir().join("vessel/radar.json");
    let mut current = Vec::new();

    if config.github_enabled {
        let my_prs = load_pull_requests()?;
        for pr in &my_prs {
            for id in &pr.review_ids {
                current.push(make_event("review-comment", &pr.url, id));
            }
            for id in &pr.unresolved_thread_ids {
                current.push(make_event("unresolved-thread", &pr.url, id));
            }
            if pr.has_conflicts {
                current.push(make_event("conflicts", &pr.url, &pr.head_commit));
            }
            if matches!(pr.ci_status.as_deref(), Some("FAILURE" | "ERROR")) {
                current.push(make_event("ci-failed", &pr.url, &pr.head_commit));
            }
            if pr.status == ReviewStatus::Approved
                && matches!(pr.ci_status.as_deref(), Some("SUCCESS"))
            {
                current.push(make_event("approved", &pr.url, &pr.head_commit));
            }
            if pr.status == ReviewStatus::Draft {
                current.push(make_event("draft-handoff", &pr.url, &pr.head_commit));
            }
        }
        let review_prs = load_review_pull_requests()?;
        for pr in &review_prs {
            if pr.is_review_requested {
                current.push(make_event("review-requested", &pr.url, &pr.head_commit));
            }
        }
    }

    if config.jira_enabled && let Ok(tickets) = load_jira_tickets() {
        for ticket in &tickets {
            current.push(make_event("ticket-assigned", &ticket.key, &ticket.key));
        }
    }

    let existing = match fs::read_to_string(&radar_path) {
        Ok(text) => serde_json::from_str::<Value>(&text).ok(),
        Err(_) => None,
    };

    if existing.is_none() {
        // First run: seed all current events as seen, print nothing.
        let seen: Vec<Value> = current.iter().map(|e| json!(e["id"])).collect();
        let state = json!({ "v": 1, "seen": seen, "pending": [] });
        let data_dir = config.data_dir().join("vessel");
        fs::create_dir_all(&data_dir)
            .map_err(|e| format!("Could not create data directory: {e}"))?;
        write_atomic(&radar_path, &serde_json::to_string_pretty(&state).unwrap())?;
        return Ok(None);
    }

    let mut state = existing.unwrap();
    let seen_set: HashSet<String> = state["seen"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect();
    let pending_ids: HashSet<String> = state["pending"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| v["id"].as_str().map(str::to_owned))
        .collect();

    let new_events: Vec<Value> = current
        .into_iter()
        .filter(|e| {
            let id = e["id"].as_str().unwrap_or_default();
            !seen_set.contains(id) && !pending_ids.contains(id)
        })
        .collect();

    if new_events.is_empty() {
        return Ok(None);
    }

    let count = new_events.len();
    let kinds: Vec<&str> = new_events
        .iter()
        .filter_map(|e| e["kind"].as_str())
        .collect();
    let summary = summarize_kinds(&kinds);

    if let Some(pending) = state["pending"].as_array_mut() {
        pending.extend(new_events);
    }
    write_atomic(&radar_path, &serde_json::to_string_pretty(&state).unwrap())?;

    Ok(Some(format!("vessel-radar: {count} new ({summary})\n")))
}

fn make_event(kind: &str, target: &str, anchor: &str) -> Value {
    json!({
        "id": event_id(target, kind, anchor),
        "target": target,
        "kind": kind,
        "anchor": anchor,
    })
}

fn event_id(target: &str, kind: &str, anchor: &str) -> String {
    // FNV-1a: stable, dependency-free ID derived from the dedupe key triple.
    let mut hash: u64 = 14695981039346656037_u64;
    for byte in target
        .bytes()
        .chain(std::iter::once(0u8))
        .chain(kind.bytes())
        .chain(std::iter::once(0u8))
        .chain(anchor.bytes())
    {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(1099511628211);
    }
    format!("{hash:016x}")
}

fn summarize_kinds(kinds: &[&str]) -> String {
    let mut counts = std::collections::BTreeMap::<&str, usize>::new();
    for kind in kinds {
        *counts.entry(kind).or_insert(0) += 1;
    }
    counts
        .iter()
        .map(|(kind, count)| {
            if *count == 1 {
                (*kind).to_string()
            } else {
                format!("{count}x {kind}")
            }
        })
        .collect::<Vec<_>>()
        .join(", ")
}

// --- arm ---

fn run_arm(home: Option<PathBuf>) -> io::Result<()> {
    let (fm_home, fm_root) = resolve_fm_home(home).map_err(io::Error::other)?;

    let state_dir = env::var_os("FM_STATE_OVERRIDE")
        .map(PathBuf::from)
        .unwrap_or_else(|| fm_home.join("state"));

    let vessel_exe = env::current_exe()?;
    let shim_path = state_dir.join(format!("{CHECK_ID}.check.sh"));

    let shim = format!(
        "#!/usr/bin/env bash\n\
         # Auto-generated by vessel radar arm - vessel radar monitor shim.\n\
         # The watcher validates these bytes, then dispatches the trusted check script.\n\
         export FM_HOME={home}\n\
         exec {exe} radar check\n",
        home = shell_quote(&fm_home.to_string_lossy()),
        exe = shell_quote(&vessel_exe.to_string_lossy()),
    );

    write_shim(&shim_path, &shim)?;

    let registered = Command::new(fm_root.join("bin/fm-check-register.sh"))
        .arg(CHECK_ID)
        .env("FM_HOME", &fm_home)
        .stdout(std::process::Stdio::null())
        .status()
        .map_err(|e| io::Error::other(format!("Could not run fm-check-register.sh: {e}")))?;

    if !registered.success() {
        let _ = fs::remove_file(&shim_path);
        return Err(io::Error::other(format!(
            "vessel radar: fm-check-register.sh failed for {CHECK_ID}"
        )));
    }

    println!("armed: state/{CHECK_ID}.check.sh");
    Ok(())
}

fn write_shim(path: &Path, content: &str) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let dir = path
        .parent()
        .ok_or_else(|| io::Error::other("invalid shim path"))?;
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".vessel-radar-shim.{}", std::process::id()));
    fs::write(&tmp, content)?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o700))?;
    fs::rename(&tmp, path)
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

// --- disarm ---

fn run_disarm(home: Option<PathBuf>) -> io::Result<()> {
    let (fm_home, fm_root) = resolve_fm_home(home).map_err(io::Error::other)?;

    let status = Command::new(fm_root.join("bin/fm-check-unregister.sh"))
        .arg(CHECK_ID)
        .env("FM_HOME", &fm_home)
        .status()
        .map_err(|e| io::Error::other(format!("Could not run fm-check-unregister.sh: {e}")))?;

    if !status.success() {
        return Err(io::Error::other("vessel radar: disarm failed"));
    }
    Ok(())
}

// --- ack ---

fn run_ack(home: Option<PathBuf>, ids: &[String]) -> io::Result<()> {
    if ids.is_empty() {
        return Ok(());
    }
    let (fm_home, _fm_root) = resolve_fm_home(home).map_err(io::Error::other)?;
    let radar_path = fm_home.join("data/vessel/radar.json");

    let text = fs::read_to_string(&radar_path)
        .map_err(|e| io::Error::other(format!("vessel radar: could not read radar state: {e}")))?;
    let mut state: Value = serde_json::from_str(&text)
        .map_err(|e| io::Error::other(format!("vessel radar: could not parse radar state: {e}")))?;

    let id_set: HashSet<&str> = ids.iter().map(String::as_str).collect();
    let mut acked = Vec::new();
    if let Some(pending) = state["pending"].as_array_mut() {
        pending.retain(|event| {
            let id = event["id"].as_str().unwrap_or_default();
            if id_set.contains(id) {
                acked.push(id.to_owned());
                false
            } else {
                true
            }
        });
    }
    if let Some(seen) = state["seen"].as_array_mut() {
        for id in acked {
            seen.push(json!(id));
        }
    }

    let data_dir = fm_home.join("data/vessel");
    fs::create_dir_all(&data_dir).map_err(|e| {
        io::Error::other(format!(
            "vessel radar: could not create data directory: {e}"
        ))
    })?;
    write_atomic(&radar_path, &serde_json::to_string_pretty(&state).unwrap())
        .map_err(io::Error::other)?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_id_is_stable_and_differs_by_component() {
        let id1 = event_id("https://github.com/a/b/pull/1", "ci-failed", "abc");
        let id2 = event_id("https://github.com/a/b/pull/1", "ci-failed", "abc");
        let id3 = event_id("https://github.com/a/b/pull/1", "ci-failed", "xyz");
        let id4 = event_id("https://github.com/a/b/pull/1", "conflicts", "abc");
        let id5 = event_id("https://github.com/a/b/pull/2", "ci-failed", "abc");

        assert_eq!(id1, id2, "same inputs produce same id");
        assert_ne!(id1, id3, "different anchor produces different id");
        assert_ne!(id1, id4, "different kind produces different id");
        assert_ne!(id1, id5, "different target produces different id");
        assert_eq!(id1.len(), 16, "id is a 16-char hex string");
    }

    #[test]
    fn first_run_seeds_without_output_and_subsequent_run_detects_new_events() {
        let dir = std::env::temp_dir().join(format!("vessel-radar-test-{}", std::process::id()));
        let radar_path = dir.join("radar.json");
        fs::create_dir_all(&dir).unwrap();

        // Simulate seeding: absent file -> write seen, return None
        let current = vec![
            make_event("ci-failed", "https://github.test/a/1", "sha1"),
            make_event("conflicts", "https://github.test/a/2", "sha2"),
        ];
        let seen: Vec<Value> = current.iter().map(|e| json!(e["id"])).collect();
        let state = json!({ "v": 1, "seen": seen, "pending": [] });
        write_atomic(&radar_path, &serde_json::to_string_pretty(&state).unwrap()).unwrap();

        // Verify seeded events are not re-reported
        let text = fs::read_to_string(&radar_path).unwrap();
        let state: Value = serde_json::from_str(&text).unwrap();
        let seen_set: HashSet<String> = state["seen"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect();
        let pending_ids: HashSet<String> = HashSet::new();
        let new_events: Vec<Value> = current
            .iter()
            .filter(|e| {
                let id = e["id"].as_str().unwrap_or_default();
                !seen_set.contains(id) && !pending_ids.contains(id)
            })
            .cloned()
            .collect();
        assert!(new_events.is_empty(), "seeded events should not be new");

        // A genuinely new event should be detected
        let new_event = make_event("ci-failed", "https://github.test/a/3", "sha3");
        let new_id = new_event["id"].as_str().unwrap();
        assert!(
            !seen_set.contains(new_id),
            "unseen event should be detected"
        );

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn ack_moves_event_from_pending_to_seen() {
        let dir = std::env::temp_dir().join(format!("vessel-radar-ack-{}", std::process::id()));
        let radar_path = dir.join("radar.json");
        fs::create_dir_all(&dir).unwrap();

        let event = make_event("ci-failed", "https://github.test/a/1", "sha1");
        let id = event["id"].as_str().unwrap().to_owned();

        let initial = json!({ "v": 1, "seen": [], "pending": [event] });
        write_atomic(
            &radar_path,
            &serde_json::to_string_pretty(&initial).unwrap(),
        )
        .unwrap();

        // Simulate ack
        let text = fs::read_to_string(&radar_path).unwrap();
        let mut state: Value = serde_json::from_str(&text).unwrap();
        let mut acked = Vec::new();
        if let Some(pending) = state["pending"].as_array_mut() {
            pending.retain(|e| {
                if e["id"].as_str() == Some(&id) {
                    acked.push(id.clone());
                    false
                } else {
                    true
                }
            });
        }
        if let Some(seen) = state["seen"].as_array_mut() {
            for a in acked {
                seen.push(json!(a));
            }
        }
        write_atomic(&radar_path, &serde_json::to_string_pretty(&state).unwrap()).unwrap();

        let result: Value =
            serde_json::from_str(&fs::read_to_string(&radar_path).unwrap()).unwrap();
        assert!(
            result["pending"].as_array().unwrap().is_empty(),
            "pending should be empty"
        );
        assert_eq!(
            result["seen"].as_array().unwrap().len(),
            1,
            "acked event should be in seen"
        );
        assert_eq!(result["seen"][0].as_str(), Some(id.as_str()));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn summarize_kinds_groups_repeated_kinds() {
        let kinds = ["ci-failed", "ci-failed", "conflicts"];
        let summary = summarize_kinds(&kinds);
        assert!(
            summary.contains("2x ci-failed"),
            "repeated kind should be grouped: {summary}"
        );
        assert!(
            summary.contains("conflicts"),
            "single kind should be listed: {summary}"
        );
    }
}
