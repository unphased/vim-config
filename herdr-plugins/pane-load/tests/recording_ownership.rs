use herdr_pane_load::recording::{Context, Profile, Timebase, encode_block};
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::CommandExt;
use std::process::Command;

#[test]
fn block_export_directory_remains_usable_with_restrictive_umask() {
    let root = std::env::temp_dir().join(format!("pl-owner-umask-{}", std::process::id()));
    std::fs::create_dir(&root).unwrap();
    let input = root.join("fixture.pst");
    let output = root.join("export");
    let context = Context::new(Timebase {
        numer: 125,
        denom: 3,
    });
    std::fs::write(
        &input,
        encode_block(&context, &[], Profile::Adaptive).unwrap(),
    )
    .unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_pane-load"));
    command
        .args(["recording", "inspect", "--input"])
        .arg(&input)
        .arg("--blocks-out")
        .arg(&output);
    // SAFETY: umask is async-signal-safe and is changed only in the child before exec.
    unsafe {
        command.pre_exec(|| {
            libc::umask(0o777);
            Ok(())
        });
    }
    let result = command.output().unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let permissions = std::fs::metadata(&output).unwrap().mode() & 0o777;
    // Restore access even on failure so this test never leaves an inaccessible tree.
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&output, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(permissions, 0o700);
}
