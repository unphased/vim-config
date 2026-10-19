//! Sudo output ownership selection.

/// Select the invoking user's owner only when running as root through sudo.
fn sudo_output_owner(
    effective_uid: u32,
    sudo_uid: Option<&str>,
    sudo_gid: Option<&str>,
) -> Option<(u32, u32)> {
    let _ = (effective_uid, sudo_uid, sudo_gid);
    None
}

#[cfg(test)]
mod tests {
    use super::sudo_output_owner;

    #[test]
    fn root_with_valid_sudo_identity_uses_invoking_uid_and_gid() {
        assert_eq!(sudo_output_owner(0, Some("501"), Some("20")), Some((501, 20)));
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
}
