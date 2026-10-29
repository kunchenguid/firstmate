//! `fm-context-continuity --help` owns executable usage.
use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use fm_context_continuity::{
    Checkpoint, Effect, Identity, Legacy, Store, Telemetry, assess, digest, now, read_bounded,
    read_json,
};
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    version,
    about = "Integrity-checked, bounded Astra checkpoints; never executes saved actions or resets a live agent"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    /// Plan native GLOBAL defaults, refusing existing policy; --apply requires owner-coordinated adoption.
    ConfigAdopt {
        target: PathBuf,
        backup: PathBuf,
        expected_preimage_sha256: String,
        #[arg(long)]
        apply: bool,
    },
    /// Restore the exact pre-adoption config only if no later setting changed; dry-run unless --apply.
    ConfigRollback {
        target: PathBuf,
        backup: PathBuf,
        expected_current_sha256: String,
        expected_backup_sha256: String,
        #[arg(long)]
        apply: bool,
    },
    /// Create a private journal and migrate to the current schema (backup is reserved).
    Init { store: PathBuf },
    /// Upgrade an older journal after writing a new, exclusive SQLite backup.
    Migrate { store: PathBuf, backup: PathBuf },
    /// Capture an explicitly reviewed JSON checkpoint; retry is idempotent by immutable ID.
    Checkpoint { store: PathBuf, input: PathBuf },
    /// Emit a bounded draft JSON for editing; empty intent/scope/action and secret review prevent capture until completed.
    Draft {
        identity: PathBuf,
        handoff: PathBuf,
        id: String,
    },
    /// Validate integrity, identity, expiration, consent and source freshness without replay.
    Validate {
        store: PathBuf,
        id: String,
        identity: PathBuf,
    },
    /// Prepare bounded data for one destination; retries return identical unacknowledged data.
    Replay {
        store: PathBuf,
        id: String,
        identity: PathBuf,
        target: PathBuf,
    },
    /// Acknowledge readback using the exact prepared replay digest (not side-effect completion).
    Ack {
        store: PathBuf,
        id: String,
        target: PathBuf,
        sha256: String,
    },
    /// Persist or reconcile an effect intent/receipt; never performs that effect.
    Effect { store: PathBuf, input: PathBuf },
    /// Back up through SQLite, refusing to replace an existing file.
    Backup {
        store: PathBuf,
        destination: PathBuf,
    },
    /// Restore into an unused private directory; never replaces the active journal.
    Restore {
        backup: PathBuf,
        destination: PathBuf,
    },
    /// Bind one legacy Emit checkpoint's provenance; emits no old prose or endpoint IDs.
    Legacy { database: PathBuf, row_id: i64 },
    /// Classify an explicit telemetry observation; does not execute compaction.
    Assess { input: PathBuf, identity: PathBuf },
    /// Hash a bounded regular source for a reviewed checkpoint manifest.
    Hash { path: PathBuf },
    /// Capture native Herdr environment identity from INSIDE the intended pane.
    Identity {
        #[arg(long)]
        host: String,
        #[arg(long)]
        root: PathBuf,
        #[arg(long)]
        thread: String,
        #[arg(
            long,
            help = "terminal_id from the same pane's current native API response"
        )]
        terminal: String,
        #[arg(long, default_value = "gpt-6-astra")]
        model: String,
    },
    /// Launch a NEW Astra CLI session with the native compaction policy; never resumes or kills a session.
    Launch {
        #[arg(long)]
        cwd: PathBuf,
        #[arg(long)]
        prompt_file: Option<PathBuf>,
        #[arg(long)]
        dry_run: bool,
    },
}
fn emit(value: impl serde::Serialize) -> Result<()> {
    println!("{}", serde_json::to_string(&value)?);
    Ok(())
}
fn run() -> Result<()> {
    match Cli::parse().command {
        Command::ConfigAdopt {
            target,
            backup,
            expected_preimage_sha256,
            apply,
        } => emit(fm_context_continuity::config::adopt(
            &target,
            &backup,
            &expected_preimage_sha256,
            apply,
        )?),
        Command::ConfigRollback {
            target,
            backup,
            expected_current_sha256,
            expected_backup_sha256,
            apply,
        } => emit(fm_context_continuity::config::rollback(
            &target,
            &backup,
            &expected_current_sha256,
            &expected_backup_sha256,
            apply,
        )?),
        Command::Init { store } => {
            let mut db = Store::open(&store, true)?;
            db.migrate(&store.join("before-v2.sqlite3"))?;
            emit(serde_json::json!({"schema":db.version()?}))
        }
        Command::Migrate { store, backup } => {
            let mut db = Store::open(&store, false)?;
            db.migrate(&backup)?;
            emit(serde_json::json!({"schema":db.version()?}))
        }
        Command::Checkpoint { store, input } => {
            let cp: Checkpoint = read_json(&input)?;
            let sha = Store::open(&store, false)?.capture(&cp, now()?)?;
            emit(serde_json::json!({"id":cp.id,"sha256":sha}))
        }
        Command::Draft {
            identity,
            handoff,
            id,
        } => {
            let identity: Identity = read_json(&identity)?;
            identity.validate()?;
            let handoff = std::fs::canonicalize(handoff)?;
            let path = handoff
                .strip_prefix(&identity.root)
                .context("handoff must be within the selected root")?
                .to_path_buf();
            let sha256 = digest(&read_bounded(&handoff, 1_048_576)?);
            let timestamp = now()?;
            emit(Checkpoint {
                version: 1,
                id,
                created_at: timestamp,
                expires_at: timestamp + 3600,
                identity,
                intent: String::new(),
                scope: String::new(),
                completed: vec![],
                decisions: vec![],
                next_action: String::new(),
                obligations: vec![],
                effects: vec![],
                sources: vec![fm_context_continuity::Source { path, sha256 }],
                navigation: vec![],
                legacy: None,
                reviewed_for_secrets: false,
            })
        }
        Command::Validate {
            store,
            id,
            identity,
        } => {
            Store::open(&store, false)?.validate(&id, &read_json(&identity)?, now()?)?;
            emit(serde_json::json!({"id":id,"valid":true}))
        }
        Command::Replay {
            store,
            id,
            identity,
            target,
        } => emit(Store::open(&store, false)?.replay(
            &id,
            &read_json(&identity)?,
            &read_json(&target)?,
            now()?,
        )?),
        Command::Ack {
            store,
            id,
            target,
            sha256,
        } => {
            Store::open(&store, false)?.acknowledge(&id, &read_json(&target)?, &sha256)?;
            emit(serde_json::json!({"acknowledged":true}))
        }
        Command::Effect { store, input } => {
            let effect: Effect = read_json(&input)?;
            Store::open(&store, false)?.effect(&effect)?;
            emit(serde_json::json!({"recorded":true,"executed":false}))
        }
        Command::Backup { store, destination } => {
            Store::open(&store, false)?.backup(&destination)?;
            emit(serde_json::json!({"backup":destination}))
        }
        Command::Restore {
            backup,
            destination,
        } => {
            Store::restore(&backup, &destination)?;
            emit(serde_json::json!({"restored":destination,"activated":false}))
        }
        Command::Legacy { database, row_id } => emit(Legacy::inspect(&database, row_id)?),
        Command::Assess { input, identity } => {
            let t: Telemetry = read_json(&input)?;
            emit(assess(&t, &read_json(&identity)?, now()?)?)
        }
        Command::Hash { path } => {
            emit(serde_json::json!({"path":path,"sha256":digest(&read_bounded(&path,1_048_576)?)}))
        }
        Command::Identity {
            host,
            root,
            thread,
            terminal,
            model,
        } => {
            let session = std::env::var("HERDR_SESSION")
                .context("HERDR_SESSION absent; run inside the intended native pane")?;
            let pane = std::env::var("HERDR_PANE_ID")
                .context("HERDR_PANE_ID absent; do not substitute a Zellij index")?;
            let identity = Identity {
                host,
                root: std::fs::canonicalize(root)?,
                thread,
                terminal,
                model,
                backend: "herdr".into(),
                session,
                pane,
            };
            identity.validate()?;
            emit(identity)
        }
        Command::Launch {
            cwd,
            prompt_file,
            dry_run,
        } => {
            let cwd = std::fs::canonicalize(cwd)?;
            let mut args = vec![
                "--model".to_owned(),
                "gpt-6-astra".into(),
                "-c".into(),
                format!(
                    "model_auto_compact_token_limit={}",
                    fm_context_continuity::THRESHOLD
                ),
                "-c".into(),
                "model_auto_compact_token_limit_scope=\"total\"".into(),
                "--cd".into(),
                cwd.to_string_lossy().into_owned(),
            ];
            if let Some(file) = prompt_file {
                args.push("--".into());
                args.push(String::from_utf8(read_bounded(
                    &file,
                    fm_context_continuity::MAX_REPLAY,
                )?)?);
            }
            if dry_run {
                return emit(serde_json::json!({"program":"codex","args":args,"activated":false}));
            }
            let status = std::process::Command::new("codex")
                .args(args)
                .status()
                .context(
                    "launch Codex; requires a version supporting full-context compaction scope",
                )?;
            anyhow::ensure!(status.success(), "Codex exited unsuccessfully: {status}");
            Ok(())
        }
    }
}
fn main() {
    if let Err(error) = run() {
        eprintln!("continuity: {error:#}");
        std::process::exit(1);
    }
}
