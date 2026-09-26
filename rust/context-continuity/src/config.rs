//! Explicit owner-coordinated native configuration adoption. No implicit home lookup.
//! Backup bytes stay adjacent to their owner; receipts contain hashes, never config text.
use crate::{MAX_INPUT, digest, read_bounded};
use anyhow::{Context, Result, ensure};
use fs2::FileExt;
use serde_json::{Value, json};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
};

const PREFIX: &str = "# Astra continuity policy, effective 2026-09-24; applies to new native Codex sessions.\nmodel_auto_compact_token_limit = 230000\nmodel_auto_compact_token_limit_scope = \"total\"\n\n";

fn private_file(path: &Path) -> Result<fs::Metadata> {
    let meta = fs::symlink_metadata(path)?;
    ensure!(
        meta.is_file()
            && !meta.file_type().is_symlink()
            && meta.nlink() == 1
            && meta.mode() & 0o077 == 0,
        "config/backup must be a private regular file without links"
    );
    Ok(meta)
}

fn locked_preimage(target: &Path, expected: &str) -> Result<(File, Vec<u8>)> {
    ensure!(
        target.is_absolute() && target.file_name().is_some_and(|n| n == "config.toml"),
        "explicit absolute config.toml target required"
    );
    private_file(target)?;
    let file = File::open(target)?;
    file.try_lock_exclusive()
        .context("config busy; coordinate with its owner")?;
    let bytes = read_bounded(target, MAX_INPUT)?;
    verify_preimage(target, &file, &bytes)?;
    ensure!(
        digest(&bytes) == expected,
        "config preimage hash changed; nothing replaced"
    );
    Ok((file, bytes))
}

fn verify_preimage(target: &Path, locked: &File, original: &[u8]) -> Result<()> {
    let current = private_file(target)?;
    let opened = locked.metadata()?;
    ensure!(
        current.dev() == opened.dev()
            && current.ino() == opened.ino()
            && read_bounded(target, MAX_INPUT)? == original,
        "config changed during preparation; preserve backup and re-inspect"
    );
    Ok(())
}

fn same_parent(target: &Path, backup: &Path) -> Result<()> {
    ensure!(
        backup.is_absolute() && backup != target,
        "explicit separate backup path required"
    );
    ensure!(
        fs::canonicalize(target.parent().context("target parent missing")?)?
            == fs::canonicalize(backup.parent().context("backup parent missing")?)?,
        "full config backup must remain beside its private owner"
    );
    Ok(())
}

fn replace(target: &Path, locked: &File, before: &[u8], after: &[u8]) -> Result<()> {
    let parent = target.parent().context("target parent missing")?;
    let mut next = tempfile::NamedTempFile::new_in(parent)?;
    next.as_file()
        .set_permissions(locked.metadata()?.permissions())?;
    next.write_all(after)?;
    next.as_file().sync_all()?;
    // Serialize cooperating writers and compare both bytes and inode immediately before rename.
    // Native writers do not promise to honor flock: the owner must coordinate this short operation.
    verify_preimage(target, locked, before)?;
    next.persist(target).map_err(|e| e.error)?;
    File::open(parent)?.sync_all()?;
    ensure!(
        read_bounded(target, MAX_INPUT)? == after,
        "post-install readback changed; inspect backup before rollback"
    );
    Ok(())
}

pub fn adopt(target: &Path, backup: &Path, expected: &str, apply: bool) -> Result<Value> {
    let (locked, before) = locked_preimage(target, expected)?;
    same_parent(target, backup)?;
    let text = std::str::from_utf8(&before).context("config is not UTF-8")?;
    // Suppress parser excerpts: invalid source lines could contain credentials.
    let parsed: toml::Value = text
        .parse()
        .map_err(|_| anyhow::anyhow!("invalid TOML; inspect with the config owner"))?;
    ensure!(
        parsed.get("model").and_then(toml::Value::as_str) == Some("gpt-6-astra"),
        "default model is not Astra"
    );
    for key in [
        "model_auto_compact_token_limit",
        "model_auto_compact_token_limit_scope",
        "profile",
        "profiles",
    ] {
        ensure!(
            parsed.get(key).is_none(),
            "existing threshold/profile policy; refuse replacement"
        );
    }
    ensure!(!backup.try_exists()?, "backup already exists; preserve it");
    let after = [PREFIX.as_bytes(), &before].concat();
    ensure!(after.len() <= MAX_INPUT, "updated config exceeds bound");
    if apply {
        let mut saved = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(backup)?;
        saved.write_all(&before)?;
        saved.sync_all()?;
        File::open(backup.parent().context("backup parent missing")?)?.sync_all()?;
        ensure!(
            read_bounded(backup, MAX_INPUT)? == before,
            "backup verification failed"
        );
        replace(target, &locked, &before, &after)?;
    }
    Ok(
        json!({"operation":"native-global-policy", "target":target,"backup":backup,"before_sha256":digest(&before),"after_sha256":digest(&after),"other_bytes_unchanged":true,"model":"gpt-6-astra","threshold":230000,"scope":"total","applied":apply,"running_sessions_reset":false}),
    )
}

pub fn rollback(
    target: &Path,
    backup: &Path,
    expected_current: &str,
    expected_backup: &str,
    apply: bool,
) -> Result<Value> {
    let (locked, current) = locked_preimage(target, expected_current)?;
    same_parent(target, backup)?;
    private_file(backup)?;
    let original = read_bounded(backup, MAX_INPUT)?;
    ensure!(
        digest(&original) == expected_backup,
        "backup digest mismatch"
    );
    ensure!(
        current.strip_prefix(PREFIX.as_bytes()) == Some(original.as_slice()),
        "later settings or unrelated backup; reconcile instead of overwriting"
    );
    if apply {
        replace(target, &locked, &current, &original)?;
    }
    Ok(
        json!({"operation":"native-global-policy-rollback","target":target,"backup":backup,"before_sha256":digest(&current),"after_sha256":digest(&original),"applied":apply,"running_sessions_reset":false}),
    )
}
