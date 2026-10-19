//! Sudo output ownership selection.

use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
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

pub(crate) fn expected_uid() -> u32 {
    sudo_owner()
        .map(|(uid, _)| uid)
        .unwrap_or_else(|| unsafe { libc::geteuid() })
}

/// Chown a file that was just exclusively created by this process, if running via sudo.
pub(crate) fn chown_created_file(file: &File) -> io::Result<()> {
    if let Some((uid, gid)) = sudo_owner()
        && unsafe { libc::fchown(file.as_raw_fd(), uid as libc::uid_t, gid as libc::gid_t) } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Create a private directory without resolving a newly created entry after publication.
pub(crate) fn create_private_directory(path: &Path) -> io::Result<()> {
    let owner = sudo_owner()
        .or_else(|| (unsafe { libc::geteuid() } == 0).then(|| (0, unsafe { libc::getegid() })));
    let Some(owner) = owner else {
        let mut builder = DirBuilder::new();
        builder.mode(0o700);
        builder.create(path)?;
        // mkdir is filtered by umask. A non-root owner can restore access even
        // when mode 0000 prevents opening a descriptor. Never do this as root.
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        let path = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path contains NUL"))?;
        if unsafe {
            libc::fchmodat(
                libc::AT_FDCWD,
                path.as_ptr(),
                0o700,
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        return Ok(());
    };

    #[cfg(target_os = "macos")]
    {
        create_sudo_private_directory(path, owner, || {})
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = owner;
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "secure sudo directory ownership is supported only on macOS",
        ))
    }
}

/// Normalize an existing archive directory through a validated no-follow descriptor.
pub(crate) fn make_existing_directory_private(path: &Path) -> io::Result<()> {
    let directory = open_directory(path)?;
    let metadata = directory.metadata()?;
    if !metadata.is_dir() || metadata.uid() != expected_uid() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "directory is not owned by the expected user",
        ));
    }
    if metadata.permissions().mode() & 0o777 != 0o700 {
        directory.set_permissions(fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn open_directory(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC);
    options.open(path)
}

#[cfg(target_os = "macos")]
fn create_sudo_private_directory(
    path: &Path,
    (uid, gid): (u32, u32),
    before_publish: impl FnOnce(), // Test seam for deterministic directory substitution races.
) -> io::Result<()> {
    use std::ffi::CString;
    use std::os::fd::FromRawFd;
    use std::os::unix::ffi::OsStrExt;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_HOLDER: AtomicU64 = AtomicU64::new(0);
    fn cstring(bytes: &[u8]) -> io::Result<CString> {
        CString::new(bytes)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path contains NUL"))
    }

    fn open_at(parent: &File, name: &CString) -> io::Result<File> {
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }

    fn remove_directory_at(parent: &File, name: &CString) -> io::Result<()> {
        if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) } == 0 {
            Ok(())
        } else {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::NotFound {
                Ok(())
            } else {
                Err(error)
            }
        }
    }

    let staged_name = cstring(b"directory")?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path must name a directory"))?;
    let destination_name = cstring(name.as_bytes())?;
    let parent_path = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    // Existing parent aliases such as /tmp -> /private/tmp are valid; pin their
    // resolved directory before creating or handing off any new inode.
    let destination_parent = open_directory(&fs::canonicalize(parent_path)?)?;
    if !destination_parent.metadata()?.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotADirectory,
            "destination parent is not a directory",
        ));
    }

    // Do not use TMPDIR: only the system root-owned sticky directory is trusted here.
    let trusted_tmp = open_directory(Path::new("/private/tmp"))?;
    let tmp_metadata = trusted_tmp.metadata()?;
    if !tmp_metadata.is_dir() || tmp_metadata.uid() != 0 || tmp_metadata.mode() & 0o1000 == 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "/private/tmp is not a root-owned sticky directory",
        ));
    }

    let mut staging_holder = None;
    for _ in 0..128 {
        let number = NEXT_HOLDER.fetch_add(1, Ordering::Relaxed);
        let candidate =
            cstring(format!("pane-load-owner-{}-{number}", unsafe { libc::getpid() }).as_bytes())?;
        let status = unsafe { libc::mkdirat(trusted_tmp.as_raw_fd(), candidate.as_ptr(), 0o700) };
        if status == 0 {
            let holder = match open_at(&trusted_tmp, &candidate) {
                Ok(holder) => holder,
                Err(error) => {
                    let _ = remove_directory_at(&trusted_tmp, &candidate);
                    return Err(error);
                }
            };
            staging_holder = Some((candidate, holder));
            break;
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::AlreadyExists {
            return Err(error);
        }
    }
    let (holder_name, holder) = staging_holder.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::AlreadyExists,
            "could not reserve a private staging directory",
        )
    })?;
    let result = (|| {
        let holder_metadata = holder.metadata()?;
        if !holder_metadata.is_dir() || holder_metadata.uid() != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "staging holder is not a root-owned directory",
            ));
        }
        if unsafe { libc::fchmod(holder.as_raw_fd(), 0o700) } != 0 {
            return Err(io::Error::last_os_error());
        }
        if unsafe { libc::mkdirat(holder.as_raw_fd(), staged_name.as_ptr(), 0o700) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let staged = open_at(&holder, &staged_name)?;
        if unsafe { libc::fchmod(staged.as_raw_fd(), 0o700) } != 0 {
            return Err(io::Error::last_os_error());
        }
        if unsafe { libc::fchown(staged.as_raw_fd(), uid as libc::uid_t, gid as libc::gid_t) } != 0
        {
            return Err(io::Error::last_os_error());
        }
        before_publish();
        if unsafe {
            libc::renameatx_np(
                holder.as_raw_fd(),
                staged_name.as_ptr(),
                destination_parent.as_raw_fd(),
                destination_name.as_ptr(),
                libc::RENAME_EXCL,
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    })();

    if result.is_err() {
        let _ = remove_directory_at(&holder, &staged_name);
    }
    drop(holder);
    let cleanup = remove_directory_at(&trusted_tmp, &holder_name);
    match result {
        Err(error) => Err(error),
        Ok(()) => cleanup,
    }
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
        let parent = if cfg!(target_os = "macos") && super::sudo_owner().is_some() {
            PathBuf::from("/private/tmp")
        } else {
            std::env::temp_dir()
        };
        let path = parent.join(format!(
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
        assert_eq!(metadata.mode() & 0o077, 0);
        assert_eq!(metadata.mode() & 0o700, 0o700);

        let result = create_private_directory(&path);
        assert_eq!(
            result.unwrap_err().kind(),
            std::io::ErrorKind::AlreadyExists
        );
        fs::remove_dir_all(parent).unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn sudo_publication_pins_parent_and_never_chowns_an_existing_directory() {
        let Some(owner) = super::sudo_owner() else {
            return;
        };
        let parent = test_directory();
        let original = parent.join("original");
        let moved = parent.join("moved");
        let victim = parent.join("victim");
        fs::create_dir(&original).unwrap();
        fs::create_dir(&victim).unwrap();
        fs::create_dir(victim.join("child")).unwrap();
        fs::set_permissions(victim.join("child"), fs::Permissions::from_mode(0o755)).unwrap();
        super::create_sudo_private_directory(&original.join("child"), owner, || {
            fs::rename(&original, &moved).unwrap();
            std::os::unix::fs::symlink(&victim, &original).unwrap();
        })
        .unwrap();
        assert_eq!(fs::metadata(moved.join("child")).unwrap().uid(), owner.0);
        let untouched = fs::metadata(victim.join("child")).unwrap();
        assert_eq!(untouched.uid(), 0);
        assert_eq!(untouched.mode() & 0o777, 0o755);

        // A real directory substituted at the destination is not replaced or chowned.
        let occupied = moved.join("occupied");
        let result = super::create_sudo_private_directory(&occupied, owner, || {
            fs::create_dir(&occupied).unwrap();
            fs::set_permissions(&occupied, fs::Permissions::from_mode(0o755)).unwrap();
        });
        assert_eq!(
            result.unwrap_err().kind(),
            std::io::ErrorKind::AlreadyExists
        );
        let untouched = fs::metadata(&occupied).unwrap();
        assert_eq!(untouched.uid(), 0);
        assert_eq!(untouched.mode() & 0o777, 0o755);
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
        assert_eq!(fs::symlink_metadata(&target).unwrap().uid(), unsafe {
            libc::geteuid()
        });
        fs::remove_dir_all(parent).unwrap();
    }
}
