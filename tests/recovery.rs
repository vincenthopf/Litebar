use litebar_core::recovery::*;
use litebar_core::storage::{store_journal, MAX_JOURNAL_BYTES};
use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};

#[test]
fn popup_remains_open_when_its_app_is_not_active() {
    assert!(interface_is_showing(true, true, Some(false)));
    assert!(!interface_is_showing(false, true, Some(true)));
}

#[test]
fn ordinary_windows_stop_blocking_when_the_owner_deactivates() {
    assert!(!interface_is_showing(true, false, Some(false)));
    assert!(interface_is_showing(true, false, Some(true)));
    assert!(interface_is_showing(true, false, None));
}

#[test]
fn identity_resolution_never_guesses_among_duplicate_items() {
    assert_eq!(resolve_window(10, &[20, 30]), None);
    assert_eq!(resolve_window(10, &[20, 10, 30]), Some(10));
    assert_eq!(resolve_window(10, &[20]), Some(20));
    assert_eq!(resolve_window(10, &[]), None);
    assert_eq!(resolve_window(0, &[0]), None);
}

#[test]
fn manual_retry_does_not_cross_desktops() {
    assert!(restoration_allowed(5, 5, 2, false));
    assert!(!restoration_allowed(5, 5, 3, false));
    assert!(restoration_allowed(5, 5, 3, true));
    assert!(!restoration_allowed(5, 6, 0, true));
    assert!(!restoration_allowed(0, 0, 0, true));
}

struct TestDirectory(std::path::PathBuf);
impl TestDirectory {
    fn new() -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "litebar-journal-{}-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn journal_is_published_atomically_and_bounded_before_io() {
    let directory = TestDirectory::new();
    let path = directory.0.join("recovery.plist");
    store_journal(&path, b"first").unwrap();
    store_journal(&path, b"second").unwrap();
    assert_eq!(fs::read(&path).unwrap(), b"second");
    assert!(store_journal(&path, &vec![0; MAX_JOURNAL_BYTES + 1]).is_err());
    assert!(store_journal(&path, b"").is_err());
    assert_eq!(fs::read(&path).unwrap(), b"second");
    assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}

#[test]
fn failed_journal_publish_preserves_destination_and_cleans_temporary_file() {
    let directory = TestDirectory::new();
    let path = directory.0.join("existing-directory");
    fs::create_dir(&path).unwrap();
    assert!(store_journal(&path, b"contents").is_err());
    assert!(path.is_dir());
    assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
    assert!(store_journal(std::path::Path::new("relative.plist"), b"contents").is_err());
}
