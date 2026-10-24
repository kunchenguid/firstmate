//! Public checkpoint/validate/replay behavior and deliberately hostile inputs.
//! All fixtures stay in private temporary directories; no live session is touched.
use anyhow::Result;
use fm_context_continuity::*;
use rusqlite::Connection;
use std::{
    fs,
    io::{BufRead, BufReader},
    os::unix::fs::{MetadataExt, PermissionsExt, symlink},
    path::PathBuf,
    process::{Command, Stdio},
    sync::mpsc,
    time::Duration,
};
use tempfile::TempDir;

struct Fixture {
    _temp: TempDir,
    root: PathBuf,
    store: PathBuf,
    cp: Checkpoint,
}
impl Fixture {
    fn new() -> Result<Self> {
        let temp = tempfile::tempdir()?;
        let root = fs::canonicalize(temp.path())?;
        fs::write(
            root.join("handoff.md"),
            "Intent: finish scoped work. Next: verify result.",
        )?;
        let identity = Identity {
            host: "orac-fixture".into(),
            root: root.clone(),
            backend: "herdr".into(),
            session: "fm-lab-fixture".into(),
            pane: "w1:p1".into(),
            terminal: "term_fixture1".into(),
            thread: "thread-a".into(),
            model: "gpt-6-astra".into(),
        };
        let cp = Checkpoint {
            version: 1,
            id: "checkpoint-1".into(),
            created_at: now()?,
            expires_at: now()? + 3600,
            identity,
            intent: "Finish requested change".into(),
            scope: "Only isolated fixture".into(),
            completed: vec!["checkpoint implemented".into()],
            decisions: vec!["No live restart".into()],
            next_action: "Validate evidence".into(),
            obligations: vec![Obligation {
                id: "delivery".into(),
                state: "open".into(),
                description: "Deliver verified work".into(),
                owner: "supervisor".into(),
            }],
            effects: vec![Effect {
                id: "publish-fixture".into(),
                intent_sha256: digest(b"publish-once"),
                state: "prepared".into(),
                receipt_sha256: None,
            }],
            sources: vec![Source {
                path: "handoff.md".into(),
                sha256: digest(&fs::read(root.join("handoff.md"))?),
            }],
            navigation: vec![],
            legacy: None,
            reviewed_for_secrets: true,
        };
        let store = root.join("store");
        let mut db = Store::open(&store, true)?;
        db.migrate(&root.join("v1-backup.sqlite3"))?;
        Ok(Self {
            _temp: temp,
            root,
            store,
            cp,
        })
    }
    fn open(&self) -> Result<Store> {
        Store::open(&self.store, false)
    }
    fn target(&self) -> Identity {
        let mut i = self.cp.identity.clone();
        i.thread = "thread-b".into();
        i.pane = "w1:p2".into();
        i.terminal = "term_fixture2".into();
        i
    }
}

#[test]
fn checkpoint_replay_ack_roundtrip_and_obligations() -> Result<()> {
    let f = Fixture::new()?;
    let mut db = f.open()?;
    let first = db.capture(&f.cp, now()?)?;
    assert_eq!(first, db.capture(&f.cp, now()?)?);
    let r = db.replay(&f.cp.id, &f.cp.identity, &f.target(), now()?)?;
    let data: serde_json::Value = serde_json::from_str(
        r.body
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("missing body"))?,
    )?;
    assert_eq!(data["checkpoint"]["obligations"][0]["id"], "delivery");
    assert_eq!(data["checkpoint"]["effects"][0]["state"], "prepared");
    assert!(
        data["rule"]
            .as_str()
            .is_some_and(|s| s.contains("reconcile"))
    );
    assert_eq!(
        r.body,
        db.replay(&f.cp.id, &f.cp.identity, &f.target(), now()?)?
            .body
    );
    db.acknowledge(&f.cp.id, &f.target(), &r.sha256)?;
    db.acknowledge(&f.cp.id, &f.target(), &r.sha256)?;
    let repeated = db.replay(&f.cp.id, &f.cp.identity, &f.target(), now()?)?;
    assert_eq!(repeated.state, "acknowledged");
    assert!(repeated.body.is_none());
    Ok(())
}
#[test]
fn immutable_collision_and_wrong_ack_are_rejected() -> Result<()> {
    let mut f = Fixture::new()?;
    let mut db = f.open()?;
    db.capture(&f.cp, now()?)?;
    f.cp.intent = "Different work".into();
    assert!(db.capture(&f.cp, now()?).is_err());
    assert!(
        db.acknowledge(&f.cp.id, &f.target(), &digest(b"forged"))
            .is_err()
    );
    Ok(())
}
#[test]
fn stale_source_expiry_and_future_clock_refuse_replay() -> Result<()> {
    let mut f = Fixture::new()?;
    let mut db = f.open()?;
    db.capture(&f.cp, now()?)?;
    fs::write(
        f.root.join("handoff.md"),
        "changed authoritative instruction",
    )?;
    assert!(
        db.replay(&f.cp.id, &f.cp.identity, &f.target(), now()?)
            .is_err()
    );
    f.cp.sources[0].sha256 = digest(&fs::read(f.root.join("handoff.md"))?);
    assert!(f.cp.validate(f.cp.expires_at).is_err());
    f.cp.created_at = now()? + 20;
    assert!(f.cp.validate(now()?).is_err());
    Ok(())
}
#[test]
fn source_digest_and_stored_body_corruption_are_rejected() -> Result<()> {
    let f = Fixture::new()?;
    f.open()?.capture(&f.cp, now()?)?;
    let conn = Connection::open(f.store.join("journal.sqlite3"))?;
    conn.execute("UPDATE checkpoints SET body='{}'", [])?;
    drop(conn);
    assert!(
        f.open()?
            .validate(&f.cp.id, &f.cp.identity, now()?)
            .is_err()
    );
    Ok(())
}
#[test]
fn changed_identity_model_backend_and_thread_are_rejected() -> Result<()> {
    let f = Fixture::new()?;
    let mut db = f.open()?;
    db.capture(&f.cp, now()?)?;
    let mut changed = f.cp.identity.clone();
    changed.thread = "wrong-source".into();
    assert!(db.validate(&f.cp.id, &changed, now()?).is_err());
    for field in ["model", "host", "root", "backend", "pane"] {
        let mut target = f.target();
        match field {
            "model" => target.model = "gpt-6-sol".into(),
            "host" => target.host = "wrong".into(),
            "root" => target.root = PathBuf::from("/"),
            "backend" => target.backend = "zellij".into(),
            _ => target.pane = "terminal_1".into(),
        }
        assert!(
            db.replay(&f.cp.id, &f.cp.identity, &target, now()?)
                .is_err(),
            "{field}"
        );
    }
    Ok(())
}
#[test]
fn secret_and_traversal_controls_fail_without_writing() -> Result<()> {
    let f = Fixture::new()?;
    let mut cp = f.cp.clone();
    for text in [
        "ghp_sensitive",
        "Bearer sensitive",
        "password=sensitive",
        "-----BEGIN PRIVATE KEY-----",
    ] {
        cp.intent = text.into();
        assert!(f.open()?.capture(&cp, now()?).is_err());
    }
    cp = f.cp.clone();
    cp.reviewed_for_secrets = false;
    assert!(cp.validate(now()?).is_err());
    cp = f.cp.clone();
    cp.sources[0].path = "../escape.md".into();
    assert!(cp.validate(now()?).is_err());
    cp.sources[0].path = ".env".into();
    assert!(cp.validate(now()?).is_err());
    symlink(f.root.join("handoff.md"), f.root.join("alias.md"))?;
    cp.sources[0].path = "alias.md".into();
    assert!(cp.validate(now()?).is_err());
    Ok(())
}
#[test]
fn bounds_fail_whole_instead_of_losing_obligations() -> Result<()> {
    let f = Fixture::new()?;
    let mut cp = f.cp.clone();
    cp.intent = "x".repeat(MAX_REPLAY);
    assert!(cp.validate(now()?).is_err());
    fs::write(f.root.join("large.md"), vec![b'x'; 1_048_577])?;
    assert!(read_bounded(&f.root.join("large.md"), 1_048_576).is_err());
    cp = f.cp.clone();
    cp.obligations.push(cp.obligations[0].clone());
    assert!(cp.validate(now()?).is_err());
    Ok(())
}
#[test]
fn concurrent_writers_do_not_steal_lock_and_retry_succeeds() -> Result<()> {
    let f = Fixture::new()?;
    let mut first = f.open()?;
    assert!(f.open().is_err());
    let status = Command::new(env!("CARGO_BIN_EXE_fm-context-continuity"))
        .args([
            "init",
            f.store.to_str().ok_or_else(|| anyhow::anyhow!("path"))?,
        ])
        .stderr(Stdio::null())
        .status()?;
    assert!(!status.success());
    first.capture(&f.cp, now()?)?;
    drop(first);
    assert!(f.open()?.validate(&f.cp.id, &f.cp.identity, now()?).is_ok());
    Ok(())
}
#[test]
fn effect_receipts_are_monotonic_and_duplicate_intents_do_not_execute() -> Result<()> {
    let f = Fixture::new()?;
    let mut db = f.open()?;
    db.capture(&f.cp, now()?)?;
    let mut effect = f.cp.effects[0].clone();
    effect.state = "uncertain".into();
    db.effect(&effect)?;
    effect.state = "confirmed".into();
    effect.receipt_sha256 = Some(digest(b"service-receipt"));
    db.effect(&effect)?;
    db.effect(&effect)?;
    assert!(!f.root.join("external-side-effect").exists());
    assert!(db.effect(&f.cp.effects[0]).is_err());
    effect.intent_sha256 = digest(b"different-intent");
    assert!(db.effect(&effect).is_err());
    let r = db.replay(&f.cp.id, &f.cp.identity, &f.target(), now()?)?;
    assert!(r.body.is_some_and(|b| b.contains("confirmed")));
    Ok(())
}
#[test]
fn changing_effect_after_prepare_requires_new_checkpoint() -> Result<()> {
    let f = Fixture::new()?;
    let mut db = f.open()?;
    db.capture(&f.cp, now()?)?;
    db.replay(&f.cp.id, &f.cp.identity, &f.target(), now()?)?;
    let mut effect = f.cp.effects[0].clone();
    effect.state = "uncertain".into();
    db.effect(&effect)?;
    assert!(
        db.replay(&f.cp.id, &f.cp.identity, &f.target(), now()?)
            .is_err()
    );
    Ok(())
}
#[test]
fn sqlite_backup_restore_and_migration_are_non_destructive() -> Result<()> {
    let f = Fixture::new()?;
    let mut db = f.open()?;
    db.capture(&f.cp, now()?)?;
    let backup = f.root.join("backup.sqlite3");
    db.backup(&backup)?;
    assert!(db.backup(&backup).is_err());
    let restored = f.root.join("restored");
    Store::restore(&backup, &restored)?;
    assert!(Store::restore(&backup, &restored).is_err());
    let restored_db = Store::open(&restored, false)?;
    assert!(
        restored_db
            .validate(&f.cp.id, &f.cp.identity, now()?)
            .is_ok()
    );
    let old = f.root.join("old");
    Store::restore(&f.root.join("v1-backup.sqlite3"), &old)?;
    let mut old_db = Store::open(&old, false)?;
    assert_eq!(old_db.version()?, 1);
    assert!(old_db.capture(&f.cp, now()?).is_err());
    old_db.migrate(&f.root.join("second-v1.sqlite3"))?;
    old_db.migrate(&f.root.join("unused.sqlite3"))?;
    assert!(!f.root.join("unused.sqlite3").exists());
    assert_eq!(old_db.version()?, 2);
    Ok(())
}
#[test]
fn cli_backup_and_migrate_accept_bare_relative_destination() -> Result<()> {
    let f = Fixture::new()?;
    f.open()?.capture(&f.cp, now()?)?;
    let run = |args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_fm-context-continuity"))
            .current_dir(&f.root)
            .args(args)
            .output()
    };
    let out = run(&["backup", "store", "bare.sqlite3"])?;
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let saved = f.root.join("bare.sqlite3");
    assert_eq!(fs::metadata(&saved)?.mode() & 0o777, 0o600);
    Store::restore(&saved, &f.root.join("from-bare"))?;
    assert!(
        Store::open(&f.root.join("from-bare"), false)?
            .validate(&f.cp.id, &f.cp.identity, now()?)
            .is_ok()
    );
    assert!(!run(&["backup", "store", "bare.sqlite3"])?.status.success());
    Store::open(&f.root.join("legacy-store"), true)?;
    let out = run(&["migrate", "legacy-store", "pre-v2.sqlite3"])?;
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(f.root.join("pre-v2.sqlite3").is_file());
    assert_eq!(
        Store::open(&f.root.join("legacy-store"), false)?.version()?,
        2
    );
    Ok(())
}
#[test]
fn unknown_schema_foreign_db_and_unsafe_store_refuse() -> Result<()> {
    let f = Fixture::new()?;
    let conn = Connection::open(f.store.join("journal.sqlite3"))?;
    conn.pragma_update(None, "user_version", 999)?;
    drop(conn);
    assert!(f.open().is_err());
    fs::set_permissions(&f.store, fs::Permissions::from_mode(0o755))?;
    assert!(f.open().is_err());
    Ok(())
}
#[test]
fn legacy_bridge_is_bounded_consent_preserving_and_provenance_only() -> Result<()> {
    let f = Fixture::new()?;
    let legacy = f.root.join("legacy.sqlite3");
    let conn = Connection::open(&legacy)?;
    conn.execute_batch("CREATE TABLE session_checkpoint(id INTEGER PRIMARY KEY,label TEXT,timestamp_utc TEXT,source_file TEXT,consent TEXT,resume_instructions TEXT,pane_id TEXT); INSERT INTO session_checkpoint VALUES(1,'old','2026-08-31','old-note.md','Emit','DO NOT COPY THIS SECRET','terminal_12');")?;
    let pointer = Legacy::inspect(&legacy, 1)?;
    let serialized = serde_json::to_string(&pointer)?;
    assert!(!serialized.contains("SECRET") && !serialized.contains("terminal_12"));
    let mut cp = f.cp.clone();
    cp.legacy = Some(pointer);
    cp.validate(now()?)?;
    for consent in ["Store", "Forget"] {
        conn.execute("UPDATE session_checkpoint SET consent=?1", [consent])?;
        assert!(Legacy::inspect(&legacy, 1).is_err());
        assert!(cp.validate(now()?).is_err());
    }
    conn.execute(
        "UPDATE session_checkpoint SET consent='Emit',label='changed'",
        [],
    )?;
    assert!(cp.validate(now()?).is_err());
    Ok(())
}
#[test]
fn telemetry_never_confuses_cumulative_with_active_context() -> Result<()> {
    let f = Fixture::new()?;
    let mut t = Telemetry {
        identity: f.cp.identity.clone(),
        observed_at: now()?,
        semantics: "active_context".into(),
        tokens: Some(229_999),
        runtime_version: "fixture".into(),
        compact_supported: true,
    };
    assert_eq!(
        assess(&t, &f.cp.identity, now()?)?["action"],
        "checkpoint_now"
    );
    t.tokens = Some(230_000);
    assert_eq!(
        assess(&t, &f.cp.identity, now()?)?["action"],
        "checkpoint_then_request_compaction"
    );
    t.compact_supported = false;
    assert_eq!(
        assess(&t, &f.cp.identity, now()?)?["action"],
        "checkpoint_then_fresh_thread_required"
    );
    t.semantics = "cumulative".into();
    t.tokens = Some(900_000);
    assert_eq!(assess(&t, &f.cp.identity, now()?)?["exact_signal"], false);
    assert_eq!(
        assess(&t, &f.cp.identity, now()?)?["action"],
        "telemetry_gap_checkpoint_at_safe_boundary"
    );
    t.semantics = "last_request".into();
    assert_eq!(assess(&t, &f.cp.identity, now()?)?["exact_signal"], false);
    t.tokens = None;
    assert_eq!(
        assess(&t, &f.cp.identity, now()?)?["compaction_executed"],
        false
    );
    t.observed_at = now()?.saturating_sub(61);
    assert!(assess(&t, &f.cp.identity, now()?).is_err());
    Ok(())
}
#[test]
fn crash_child() -> Result<()> {
    let Ok(path) = std::env::var("FM_CONTINUITY_CRASH_DB") else {
        return Ok(());
    };
    let conn = Connection::open(&path)?;
    conn.execute_batch("BEGIN IMMEDIATE; INSERT INTO checkpoints VALUES('crash','{}','bad');")?;
    println!("FM_CONTINUITY_CRASH_READY");
    std::thread::sleep(Duration::from_secs(30));
    anyhow::bail!("crash fixture was not killed")
}
#[test]
fn actual_process_crash_rolls_back_and_lock_is_recoverable() -> Result<()> {
    let f = Fixture::new()?;
    let path = f.store.join("journal.sqlite3");
    let mut child = Command::new(std::env::current_exe()?)
        .args(["--exact", "crash_child", "--nocapture"])
        .env("FM_CONTINUITY_CRASH_DB", &path)
        .stdout(Stdio::piped())
        .spawn()?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow::anyhow!("child stdout missing"))?;
    let (ready, signal) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if line.contains("FM_CONTINUITY_CRASH_READY") {
                let _ = ready.send(());
            }
        }
    });
    let observed = signal.recv_timeout(Duration::from_secs(60));
    let exited_early = child.try_wait()?;
    child.kill()?;
    child.wait()?;
    match observed {
        Ok(()) => {}
        Err(mpsc::RecvTimeoutError::Timeout) => {
            anyhow::bail!("crash child held no uncommitted write within 60 seconds")
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            anyhow::bail!("crash child exited before its uncommitted write: {exited_early:?}")
        }
    }
    let mut db = f.open()?;
    assert!(db.validate("crash", &f.cp.identity, now()?).is_err());
    db.capture(&f.cp, now()?)?;
    assert!(db.validate(&f.cp.id, &f.cp.identity, now()?).is_ok());
    Ok(())
}

#[test]
fn cli_roundtrip_uses_public_executable() -> Result<()> {
    let f = Fixture::new()?;
    let cp = f.root.join("input.json");
    fs::write(&cp, serde_json::to_vec(&f.cp)?)?;
    let out = Command::new(env!("CARGO_BIN_EXE_fm-context-continuity"))
        .arg("checkpoint")
        .arg(&f.store)
        .arg(&cp)
        .output()?;
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let value: serde_json::Value = serde_json::from_slice(&out.stdout)?;
    assert_eq!(value["id"], f.cp.id);
    Ok(())
}

#[test]
fn replay_and_receipt_corruption_negative_controls() -> Result<()> {
    let f = Fixture::new()?;
    f.open()?.capture(&f.cp, now()?)?;
    f.open()?
        .replay(&f.cp.id, &f.cp.identity, &f.target(), now()?)?;
    let conn = Connection::open(f.store.join("journal.sqlite3"))?;
    conn.execute("UPDATE replays SET body='{}'", [])?;
    assert!(
        f.open()?
            .replay(&f.cp.id, &f.cp.identity, &f.target(), now()?)
            .is_err()
    );
    conn.execute("DELETE FROM replays", [])?;
    conn.execute(
        "UPDATE effects SET body=replace(body,'prepared','uncertain')",
        [],
    )?;
    assert!(
        f.open()?
            .replay(&f.cp.id, &f.cp.identity, &f.target(), now()?)
            .is_err()
    );
    Ok(())
}

#[test]
fn checkpoint_retry_does_not_regress_a_later_receipt() -> Result<()> {
    let f = Fixture::new()?;
    let mut db = f.open()?;
    let hash = db.capture(&f.cp, now()?)?;
    let mut effect = f.cp.effects[0].clone();
    effect.state = "confirmed".into();
    effect.receipt_sha256 = Some(digest(b"receipt"));
    db.effect(&effect)?;
    assert_eq!(db.capture(&f.cp, now()?)?, hash);
    assert!(
        db.replay(&f.cp.id, &f.cp.identity, &f.target(), now()?)?
            .body
            .is_some_and(|v| v.contains("confirmed"))
    );
    Ok(())
}

#[test]
fn launch_dry_run_pins_full_context_policy_and_never_starts_codex() -> Result<()> {
    let f = Fixture::new()?;
    let output = Command::new(env!("CARGO_BIN_EXE_fm-context-continuity"))
        .args(["launch", "--dry-run", "--cwd"])
        .arg(&f.root)
        .env("PATH", "")
        .output()?;
    assert!(output.status.success());
    let value: serde_json::Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(value["activated"], false);
    let args = value["args"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("args missing"))?;
    assert!(args.contains(&serde_json::json!("gpt-6-astra")));
    assert!(args.contains(&serde_json::json!("model_auto_compact_token_limit=230000")));
    assert!(args.contains(&serde_json::json!(
        "model_auto_compact_token_limit_scope=\"total\""
    )));
    Ok(())
}

#[test]
fn launch_dry_run_passes_dash_led_prompt_after_option_terminator() -> Result<()> {
    let f = Fixture::new()?;
    let prompt = f.root.join("prompt.md");
    let text = "---\n- resume from checkpoint\n";
    fs::write(&prompt, text)?;
    let output = Command::new(env!("CARGO_BIN_EXE_fm-context-continuity"))
        .args(["launch", "--dry-run", "--cwd"])
        .arg(&f.root)
        .arg("--prompt-file")
        .arg(&prompt)
        .env("PATH", "")
        .output()?;
    assert!(output.status.success());
    let value: serde_json::Value = serde_json::from_slice(&output.stdout)?;
    let args = value["args"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("args missing"))?;
    let tail = &args[args.len() - 2..];
    assert_eq!(tail, [serde_json::json!("--"), serde_json::json!(text)]);
    Ok(())
}

fn config_cli(args: &[&std::ffi::OsStr]) -> Result<Result<serde_json::Value, String>> {
    let output = Command::new(env!("CARGO_BIN_EXE_fm-context-continuity"))
        .args(args)
        .output()?;
    Ok(if output.status.success() {
        Ok(serde_json::from_slice(&output.stdout)?)
    } else {
        Err(String::from_utf8(output.stderr)?)
    })
}

fn adopt(
    target: &std::path::Path,
    backup: &std::path::Path,
    expected: &str,
    apply: bool,
) -> Result<Result<serde_json::Value, String>> {
    let mut args = vec![
        "config-adopt".as_ref(),
        target.as_os_str(),
        backup.as_os_str(),
        expected.as_ref(),
    ];
    if apply {
        args.push("--apply".as_ref());
    }
    config_cli(&args)
}

fn rollback(
    target: &std::path::Path,
    backup: &std::path::Path,
    current: &str,
    original: &str,
    apply: bool,
) -> Result<Result<serde_json::Value, String>> {
    let mut args = vec![
        "config-rollback".as_ref(),
        target.as_os_str(),
        backup.as_os_str(),
        current.as_ref(),
        original.as_ref(),
    ];
    if apply {
        args.push("--apply".as_ref());
    }
    config_cli(&args)
}

#[test]
fn native_config_adoption_and_rollback_preserve_every_other_byte() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let target = temp.path().join("config.toml");
    let backup = temp.path().join("before.toml");
    let original = "# keep comment\nmodel = \"gpt-6-astra\"\nmodel_reasoning_effort = \"high\"\n[mcp_servers.fixture]\nfixture_value = \"sensitive-test-value\"\n";
    fs::write(&target, original)?;
    fs::set_permissions(&target, fs::Permissions::from_mode(0o600))?;
    let before = digest(original.as_bytes());
    let plan = adopt(&target, &backup, &before, false)?.map_err(anyhow::Error::msg)?;
    assert_eq!(plan["applied"], false);
    assert!(!backup.exists());
    assert_eq!(fs::read_to_string(&target)?, original);
    let applied = adopt(&target, &backup, &before, true)?.map_err(anyhow::Error::msg)?;
    assert_eq!(applied["applied"], true);
    assert!(!applied.to_string().contains("sensitive-test-value"));
    let updated = fs::read_to_string(&target)?;
    assert!(updated.ends_with(original));
    let parsed: toml::Value = updated.parse()?;
    assert_eq!(
        parsed["model_auto_compact_token_limit"].as_integer(),
        Some(230000)
    );
    assert_eq!(
        parsed["model_auto_compact_token_limit_scope"].as_str(),
        Some("total")
    );
    assert_eq!(fs::read_to_string(&backup)?, original);
    assert_eq!(fs::metadata(&backup)?.permissions().mode() & 0o777, 0o600);
    let after = digest(updated.as_bytes());
    assert_eq!(plan["after_sha256"], after);
    assert_eq!(
        rollback(&target, &backup, &after, &before, false)?.map_err(anyhow::Error::msg)?["applied"],
        false
    );
    assert_eq!(fs::read_to_string(&target)?, updated);
    let wrong = rollback(&target, &backup, &after, &digest(b"wrong"), true)?;
    assert!(wrong.is_err_and(|e| e.contains("backup digest mismatch")));
    fs::write(&target, format!("{updated}\n# later unrelated change\n"))?;
    let changed = fs::read(&target)?;
    let stale = rollback(&target, &backup, &after, &before, true)?;
    assert!(stale.is_err_and(|e| e.contains("preimage hash changed")));
    let later = rollback(&target, &backup, &digest(&changed), &before, true)?;
    assert!(later.is_err_and(|e| e.contains("later settings")));
    assert_eq!(fs::read(&target)?, changed);
    fs::write(&target, &updated)?;
    rollback(&target, &backup, &after, &before, true)?.map_err(anyhow::Error::msg)?;
    assert_eq!(fs::read_to_string(&target)?, original);
    Ok(())
}

#[test]
fn native_config_refuses_conflicts_stale_bytes_and_lock_contention() -> Result<()> {
    use fs2::FileExt;
    let temp = tempfile::tempdir()?;
    let target = temp.path().join("config.toml");
    let backup = temp.path().join("before.toml");
    for original in [
        "model='gpt-6-sol'\n",
        "model='gpt-6-astra'\nmodel_auto_compact_token_limit=123\n",
        "model='gpt-6-astra'\nmodel_auto_compact_token_limit_scope='total'\n",
        "model='gpt-6-astra'\nprofile='chosen'\n",
        "model='gpt-6-astra'\n[profiles.existing]\nmodel='gpt-6-sol'\n",
        "sensitive-test-value=NOT_TOML\n",
    ] {
        fs::write(&target, original)?;
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600))?;
        let result = adopt(&target, &backup, &digest(original.as_bytes()), true)?;
        assert!(result.is_err_and(|e| !e.contains("sensitive-test-value") && !e.contains("busy")));
        assert_eq!(fs::read_to_string(&target)?, original);
        assert!(!backup.exists());
    }
    let original = "model='gpt-6-astra'\n";
    fs::write(&target, original)?;
    let stale = adopt(&target, &backup, &digest(b"stale"), true)?;
    assert!(stale.is_err_and(|e| e.contains("preimage hash changed")));
    fs::write(&backup, "older recovery point")?;
    let kept = adopt(&target, &backup, &digest(original.as_bytes()), true)?;
    assert!(kept.is_err_and(|e| e.contains("backup already exists")));
    assert_eq!(fs::read_to_string(&backup)?, "older recovery point");
    fs::remove_file(&backup)?;
    let owner = fs::File::open(&target)?;
    owner.lock_exclusive()?;
    let busy = adopt(&target, &backup, &digest(original.as_bytes()), true)?;
    assert!(busy.is_err_and(|e| e.contains("config busy")));
    assert!(!backup.exists());
    assert_eq!(fs::read_to_string(&target)?, original);
    Ok(())
}

#[test]
fn native_config_cli_refuses_links_and_keeps_dry_run_nonmutating() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let target = temp.path().join("config.toml");
    let backup = temp.path().join("before.toml");
    let original = "model='gpt-6-astra'\n";
    fs::write(&target, original)?;
    fs::set_permissions(&target, fs::Permissions::from_mode(0o600))?;
    let output = Command::new(env!("CARGO_BIN_EXE_fm-context-continuity"))
        .arg("config-adopt")
        .arg(&target)
        .arg(&backup)
        .arg(digest(original.as_bytes()))
        .output()?;
    assert!(output.status.success());
    let receipt: serde_json::Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(receipt["applied"], false);
    assert!(!backup.exists());
    fs::rename(&target, temp.path().join("original.toml"))?;
    symlink(temp.path().join("original.toml"), &target)?;
    let linked = adopt(&target, &backup, &digest(original.as_bytes()), true)?;
    assert!(linked.is_err_and(|e| e.contains("without links")));
    assert!(!backup.exists());
    Ok(())
}
