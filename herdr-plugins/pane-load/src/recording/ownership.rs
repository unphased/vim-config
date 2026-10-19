//! Sudo output ownership: when run as root via sudo (a development convenience),
//! everything the recorder creates is handed to the invoking user right after
//! creation. The eventual launchd daemon does not go through sudo.

use std::fs::{DirBuilder, File};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::Path;

/// Select the invoking user's owner only when running as root through sudo.
fn sudo_output_owner(
    effective_uid: u32,
    sudo_uid: Option<&str>,
    sudo_gid: Option<&str>,
) -> Option<(u32, u32)> {
    if effective_uid != 0 {
        return None;
    }
    let uid = parse_sudo_id(sudo_uid?)?;
    let gid = parse_sudo_id(sudo_gid?)?;
    Some((uid, gid))
}

fn parse_sudo_id(value: &str) -> Option<u32> {
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    value.parse().ok().filter(|id| *id != u32::MAX)
}

fn sudo_owner() -> Option<(u32, u32)> {
    let effective_uid = unsafe { libc::geteuid() };
    let uid = std::env::var("SUDO_UID").ok();
    let gid = std::env::var("SUDO_GID").ok();
    sudo_output_owner(effective_uid, uid.as_deref(), gid.as_deref())
}

/// The owner that recorder outputs must have: the sudo invoker, else ourselves.
pub(crate) fn expected_uid() -> u32 {
    sudo_owner()
        .map(|(uid, _)| uid)
        .unwrap_or_else(|| unsafe { libc::geteuid() })
}

/// Chown a file this process just created, if running via sudo.
pub(crate) fn chown_created_file(file: &File) -> io::Result<()> {
    if let Some((uid, gid)) = sudo_owner()
        && unsafe { libc::fchown(file.as_raw_fd(), uid as libc::uid_t, gid as libc::gid_t) } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Create a new 0700 directory (never an existing entry or symlink), owned by
/// the sudo invoker when running via sudo.
pub(crate) fn create_private_directory(path: &Path) -> io::Result<()> {
    DirBuilder::new().mode(0o700).create(path)?;
    // mkdir is filtered by umask; set the mode explicitly.
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    if let Some((uid, gid)) = sudo_owner() {
        std::os::unix::fs::lchown(path, Some(uid), Some(gid))?;
    }
    Ok(())
}

/// Make an existing directory 0700 after checking it is a real directory owned
/// by the expected user.
pub(crate) fn make_existing_directory_private(path: &Path) -> io::Result<()> {
    let metadata = std::fs::symlink_metadata(path)?;
    if !metadata.is_dir() || metadata.uid() != expected_uid() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "directory is not owned by the expected user",
        ));
    }
    if metadata.permissions().mode() & 0o777 != 0o700 {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        create_private_directory, expected_uid, make_existing_directory_private, sudo_output_owner,
    };
    use std::fs;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_TEST_PATH: AtomicU64 = AtomicU64::new(0);

    fn test_directory() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "pane-load-ownership-test-{}-{}",
            std::process::id(),
            NEXT_TEST_PATH.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        path
    }

    #[test]
    fn root_with_valid_sudo_identity_uses_invoking_uid_and_gid() {
        assert_eq!(
            sudo_output_owner(0, Some("501"), Some("20")),
            Some((501, 20))
        );
    }

    #[test]
    fn non_root_process_does_not_use_sudo_environment() {
        assert_eq!(sudo_output_owner(501, Some("502"), Some("20")), None);
    }

    #[test]
    fn missing_or_invalid_sudo_identity_is_ignored() {
        for (uid, gid) in [
            (None, Some("20")),
            (Some("501"), None),
            (Some(""), Some("20")),
            (Some("501"), Some("")),
            (Some("not-a-uid"), Some("20")),
            (Some("501"), Some("not-a-gid")),
            (Some("4294967296"), Some("20")),
            (Some("501"), Some("4294967296")),
            (Some("-1"), Some("20")),
            (Some("501"), Some("-1")),
        ] {
            assert_eq!(sudo_output_owner(0, uid, gid), None, "{uid:?}/{gid:?}");
        }
    }

    #[test]
    fn u32_max_sentinel_is_never_selected_for_chown() {
        let sentinel = u32::MAX.to_string();
        assert_eq!(sudo_output_owner(0, Some(&sentinel), Some("20")), None);
        assert_eq!(sudo_output_owner(0, Some("501"), Some(&sentinel)), None);
    }

    #[test]
    fn created_directory_is_private_and_creation_never_replaces_an_entry() {
        let parent = test_directory();
        let path = parent.join("created");
        create_private_directory(&path).unwrap();
        let metadata = fs::symlink_metadata(&path).unwrap();
        assert!(metadata.is_dir());
        assert_eq!(metadata.uid(), expected_uid());
        assert_eq!(metadata.mode() & 0o777, 0o700);

        let result = create_private_directory(&path);
        assert_eq!(
            result.unwrap_err().kind(),
            std::io::ErrorKind::AlreadyExists
        );
        fs::remove_dir_all(parent).unwrap();
    }

    #[test]
    fn directory_creation_and_normalization_do_not_follow_symlinks() {
        let parent = test_directory();
        let target = parent.join("target");
        fs::create_dir(&target).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o755)).unwrap();
        let link = parent.join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();

        assert!(create_private_directory(&link).is_err());
        assert!(make_existing_directory_private(&link).is_err());
        assert_eq!(fs::symlink_metadata(&target).unwrap().mode() & 0o777, 0o755);
        fs::remove_dir_all(parent).unwrap();
    }
}
