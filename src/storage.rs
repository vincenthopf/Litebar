use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

pub const MAX_JOURNAL_BYTES: usize = 1024 * 1024;
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Pending(PathBuf);

impl Drop for Pending {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

pub fn store_journal(path: &Path, data: &[u8]) -> io::Result<()> {
    if data.len() > MAX_JOURNAL_BYTES || data.is_empty() || !path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Invalid journal path or size",
        ));
    }
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "Missing journal directory"))?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "Missing journal name"))?;
    let mut directory = fs::DirBuilder::new();
    directory.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        directory.mode(0o700);
    }
    directory.create(parent)?;
    let serial = SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let mut temporary = name.to_os_string();
    temporary.push(format!(
        ".pending-{}-{serial}-{timestamp}",
        std::process::id()
    ));
    let temporary = parent.join(temporary);
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    let pending = Pending(temporary);
    file.write_all(data)?;
    file.sync_all()?;
    drop(file);
    fs::rename(&pending.0, path)?;
    File::open(parent)?.sync_all()?;
    Ok(())
}
