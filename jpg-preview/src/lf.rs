use std::env;
use std::ffi::CString;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use crate::{emit_kitty as emit_protocol, PreparedImage, Timings};

const TIMEOUT: Duration = Duration::from_secs(5);
const RECEIPT_MAGIC: &[u8; 4] = b"LFR1";
const MAX_RECEIPT_BYTES: usize = 2048;
static NEXT_TRANSFER: AtomicU64 = AtomicU64::new(0);

pub fn emit_kitty(
    image: &PreparedImage,
    x: usize,
    y: usize,
    id: u32,
    timings: &mut Timings,
) -> io::Result<()> {
    let started = Instant::now();
    let mut protocol = Vec::new();
    emit_protocol(&mut protocol, image, x, y)?;
    timings.wire_bytes = protocol.len();
    timings.encode = started.elapsed();
    transfer(&protocol, &socket_path(), id, TIMEOUT, timings)
}

fn runtime_dir(runtime: Option<PathBuf>, temporary: Option<PathBuf>, uid: u32) -> PathBuf {
    runtime
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| {
            temporary
                .filter(|p| !p.as_os_str().is_empty())
                .unwrap_or_else(|| PathBuf::from("/tmp")) // Go's os.TempDir fallback, also on macOS.
                .join(format!("lf-{uid}"))
        })
}

fn socket_path() -> PathBuf {
    runtime_dir(
        env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from),
        env::var_os("TMPDIR").map(PathBuf::from),
        unsafe { libc::geteuid() },
    )
    .join("lf.sock")
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ReceiptKey(Vec<u8>);

impl ReceiptKey {
    pub(crate) fn for_preview(id: u32, path: &Path, geometry: [usize; 8]) -> Option<Self> {
        let birth = process_birth(id)?;
        let source = fs::metadata(path).ok()?;
        let executable = fs::metadata(env::current_exe().ok()?).ok()?;
        let mut key = Vec::with_capacity(160);
        key.extend_from_slice(&1u32.to_le_bytes()); // Receipt/render format version.
        key.extend_from_slice(&birth.to_le_bytes());
        // /proc start ticks are boot-relative; a surviving runtime directory
        // must not make a previous boot's receipt look like a live placement.
        #[cfg(target_os = "linux")]
        key.extend_from_slice(&fs::read("/proc/sys/kernel/random/boot_id").ok()?);
        append_file_identity(&mut key, &source);
        for value in geometry {
            key.extend_from_slice(&u64::try_from(value).ok()?.to_le_bytes());
        }
        append_file_identity(&mut key, &executable);
        key.extend_from_slice(path.as_os_str().as_bytes());
        Some(Self(key))
    }
}

fn append_file_identity(key: &mut Vec<u8>, metadata: &fs::Metadata) {
    key.extend_from_slice(&metadata.dev().to_le_bytes());
    key.extend_from_slice(&metadata.ino().to_le_bytes());
    key.extend_from_slice(&metadata.size().to_le_bytes());
    key.extend_from_slice(&metadata.mtime().to_le_bytes());
    key.extend_from_slice(&metadata.mtime_nsec().to_le_bytes());
    key.extend_from_slice(&metadata.ctime().to_le_bytes());
    key.extend_from_slice(&metadata.ctime_nsec().to_le_bytes());
}

#[cfg(target_os = "macos")]
fn process_birth(id: u32) -> Option<u64> {
    let pid = libc::pid_t::try_from(id).ok()?;
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            std::mem::size_of::<libc::proc_bsdinfo>() as i32,
        )
    };
    (size == std::mem::size_of::<libc::proc_bsdinfo>() as i32 && info.pbi_pid == id)
        .then_some(info.pbi_start_tvsec.wrapping_mul(1_000_000) + info.pbi_start_tvusec)
}

#[cfg(target_os = "linux")]
fn process_birth(id: u32) -> Option<u64> {
    let stat = fs::read_to_string(format!("/proc/{id}/stat")).ok()?;
    let mut fields = stat.rsplit_once(')')?.1.split_whitespace();
    fields.nth(19)?.parse().ok() // field 22: process start ticks
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn process_birth(_id: u32) -> Option<u64> {
    None
}

fn receipt_directory(create: bool) -> io::Result<Option<PathBuf>> {
    let socket = socket_path();
    let root = socket
        .parent()
        .ok_or_else(|| io::Error::other("invalid lf socket path"))?;
    let directory = root.join("jpg-preview-receipts");
    if create {
        match DirBuilder::new().mode(0o700).create(&directory) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
    }
    let metadata = match fs::symlink_metadata(&directory) {
        Ok(metadata) => metadata,
        Err(error) if !create && error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if !metadata.file_type().is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err(io::Error::other("unsafe lf receipt directory"));
    }
    Ok(Some(directory))
}

fn receipt_path(id: u32, create: bool) -> io::Result<Option<PathBuf>> {
    Ok(receipt_directory(create)?.map(|directory| directory.join(format!("{id}.receipt"))))
}

fn read_receipt(path: &Path, key: &ReceiptKey) -> Option<String> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
        || metadata.len() as usize > MAX_RECEIPT_BYTES
    {
        return None;
    }
    let mut bytes = Vec::new();
    file.take((MAX_RECEIPT_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() > MAX_RECEIPT_BYTES || !bytes.starts_with(RECEIPT_MAGIC) {
        return None;
    }
    let mut rest = &bytes[RECEIPT_MAGIC.len()..];
    let key_len = usize::from(u16::from_le_bytes(rest.get(..2)?.try_into().ok()?));
    rest = rest.get(2..)?;
    if rest.get(..key_len)? != key.0 {
        return None;
    }
    let status = std::str::from_utf8(rest.get(key_len..)?).ok()?;
    if status.is_empty()
        || !status
            .bytes()
            .all(|byte| byte == b' ' || byte.is_ascii_graphic())
    {
        return None;
    }
    Some(status.to_owned())
}

fn write_receipt(path: &Path, key: &ReceiptKey, status: &str) -> io::Result<()> {
    if status.is_empty()
        || status.len() > 1024
        || !status
            .bytes()
            .all(|byte| byte == b' ' || byte.is_ascii_graphic())
    {
        return Err(io::Error::other("invalid receipt status row"));
    }
    let key_len = u16::try_from(key.0.len()).map_err(io::Error::other)?;
    let mut bytes = Vec::with_capacity(RECEIPT_MAGIC.len() + 2 + key.0.len() + status.len());
    bytes.extend_from_slice(RECEIPT_MAGIC);
    bytes.extend_from_slice(&key_len.to_le_bytes());
    bytes.extend_from_slice(&key.0);
    bytes.extend_from_slice(status.as_bytes());
    if bytes.len() > MAX_RECEIPT_BYTES {
        return Err(io::Error::other("receipt exceeds size limit"));
    }
    let directory = path
        .parent()
        .ok_or_else(|| io::Error::other("invalid receipt path"))?;
    let staging = TransferFiles::create(directory)?;
    let temporary = staging.0.join("receipt");
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(&bytes)?;
    drop(file);
    // This is disposable display metadata, not a durable image cache. Closing
    // before the atomic rename is enough; do not fsync every image selection.
    fs::rename(temporary, path)
}

pub(crate) fn receipt_status(id: u32, key: &ReceiptKey) -> Option<String> {
    read_receipt(receipt_path(id, false).ok()??.as_path(), key)
}

pub(crate) fn save_receipt(id: u32, key: &ReceiptKey, status: &str) -> io::Result<()> {
    let path =
        receipt_path(id, true)?.ok_or_else(|| io::Error::other("receipt directory unavailable"))?;
    write_receipt(&path, key, status)
}

pub fn forget_receipt(id: u32) -> io::Result<()> {
    let Some(path) = receipt_path(id, false)? else {
        return Ok(());
    };
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

pub fn clear_image(id: u32) -> io::Result<()> {
    forget_receipt(id)?;
    let command = format!(r#"send {id} tty-write "\033_Ga=d,d=I,i=424242,q=2\033\\""#);
    let mut command = command.into_bytes();
    command.push(b'\n');
    send_to_socket(&command, &socket_path(), TIMEOUT)
}

struct TransferFiles(PathBuf);

impl TransferFiles {
    fn create(root: &Path) -> io::Result<Self> {
        loop {
            let directory = root.join(format!(
                "jpg-{}-{}",
                std::process::id(),
                NEXT_TRANSFER.fetch_add(1, Ordering::Relaxed)
            ));
            match DirBuilder::new().mode(0o700).create(&directory) {
                Ok(()) => return Ok(Self(directory)),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e),
            }
        }
    }
}

impl Drop for TransferFiles {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn transfer(
    protocol: &[u8],
    socket: &Path,
    id: u32,
    timeout: Duration,
    timings: &mut Timings,
) -> io::Result<()> {
    // A generated Kitty/base64 stream never contains single quotes. Literal
    // quoting avoids escaping and reparsing megabytes of image data in lf.
    if protocol.contains(&b'\'') {
        return Err(io::Error::other("invalid quote in Kitty stream"));
    }
    let started = Instant::now();
    let files = TransferFiles::create(
        socket
            .parent()
            .ok_or_else(|| io::Error::other("invalid lf socket path"))?,
    )?;
    let ack_path = files.0.join("ack");
    let c_path = CString::new(ack_path.as_os_str().as_bytes())?;
    if unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // RDWR prevents EOF before the shell opens the FIFO; nonblocking + poll
    // provides bounded cancellation without sleeps or a terminal response query.
    let mut ack = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(&ack_path)?;
    let source = files.0.join("image.lfrc");
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&source)?;
    // source files have no remote scanner's 64 KiB line limit. The image stays
    // in one UI-thread write, still containing bounded 4096-byte Kitty packets.
    output.write_all(b"tty-write '")?;
    output.write_all(protocol)?;
    output.write_all(b"'\n")?;
    // A shell builtin acknowledges execution AFTER all tty writes. Sending all
    // image bytes over the server socket can deadlock lf when quitting under
    // backpressure; one small source notification avoids that bulk queue.
    writeln!(output, "&printf x 1<> {}", shell_quote(&ack_path)?)?;
    drop(output);
    let mut notification = format!("send {id} source \"").into_bytes();
    escape_command_body(&mut notification, source.as_os_str().as_bytes());
    notification.extend_from_slice(b"\"\n");
    timings.stage_file = started.elapsed();
    let started = Instant::now();
    send_to_socket(&notification, socket, timeout)?;
    timings.notify = started.elapsed();
    let started = Instant::now();
    wait_for_ack(&mut ack, timeout)?;
    timings.lf_wait = started.elapsed();
    Ok(())
    // files is removed only after consumption, rejection, or a bounded timeout.
}

fn shell_quote(path: &Path) -> io::Result<String> {
    let path = path
        .to_str()
        .ok_or_else(|| io::Error::other("lf runtime path is not UTF-8"))?;
    if path.contains(['\n', '\r']) {
        return Err(io::Error::other("lf runtime path contains a line break"));
    }
    Ok(format!("'{}'", path.replace('\'', "'\\''")))
}

fn wait_for_ack(ack: &mut File, timeout: Duration) -> io::Result<()> {
    let deadline = Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "lf did not consume image commands",
            ));
        }
        let mut descriptor = libc::pollfd {
            fd: ack.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let result = unsafe {
            libc::poll(
                &mut descriptor,
                1,
                remaining.as_millis().max(1).min(i32::MAX as u128) as i32,
            )
        };
        if result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if result > 0 {
            let mut byte = [0];
            match ack.read(&mut byte) {
                Ok(1) if byte[0] == b'x' => return Ok(()),
                Err(e)
                    if e.kind() == io::ErrorKind::WouldBlock
                        || e.kind() == io::ErrorKind::Interrupted =>
                {
                    continue
                }
                _ => return Err(io::Error::other("invalid lf image acknowledgement")),
            }
        }
    }
}

fn escape_command_body(output: &mut Vec<u8>, bytes: &[u8]) {
    let mut octal = false;
    for &byte in bytes {
        match byte {
            b'\x1b' => {
                output.extend_from_slice(b"\\033");
                octal = true;
            }
            b'0'..=b'9' if octal => {
                output.extend_from_slice(format!("\\{byte:03o}").as_bytes());
            }
            _ => {
                octal = false;
                match byte {
                    b'\\' => output.extend_from_slice(b"\\\\"),
                    b'"' => output.extend_from_slice(b"\\\""),
                    b'\r' => output.extend_from_slice(b"\\r"),
                    b'\n' => output.extend_from_slice(b"\\n"),
                    _ => output.push(byte),
                }
            }
        }
    }
}

fn send_to_socket(command: &[u8], path: &Path, timeout: Duration) -> io::Result<()> {
    let mut stream = UnixStream::connect(path)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    stream.write_all(command)?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut reply = Vec::new();
    (&mut stream).take(65537).read_to_end(&mut reply)?;
    if !reply.is_empty() {
        return Err(io::Error::other(format!(
            "lf server rejected image write: {}",
            String::from_utf8_lossy(&reply).trim()
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::os::unix::net::UnixListener;
    use std::thread;

    #[test]
    fn receipt_key_tracks_process_file_path_and_geometry() {
        let root = TransferFiles::create(&env::temp_dir()).unwrap();
        let image = root.0.join("image.png");
        fs::write(&image, b"original").unwrap();
        let id = std::process::id();
        assert!(process_birth(id).is_some());
        assert!(process_birth(u32::MAX).is_none());
        let geometry = [1, 2, 40, 20, 10, 20, 400, 400];
        let key = ReceiptKey::for_preview(id, &image, geometry).unwrap();
        assert_eq!(
            ReceiptKey::for_preview(id, &image, geometry),
            Some(ReceiptKey(key.0.clone()))
        );
        let mut resized = geometry;
        resized[2] += 1;
        assert_ne!(ReceiptKey::for_preview(id, &image, resized).unwrap(), key);
        let alias = root.0.join("image.arw");
        fs::hard_link(&image, &alias).unwrap();
        assert_ne!(ReceiptKey::for_preview(id, &alias, geometry).unwrap(), key);
        let modified = fs::metadata(&image).unwrap().modified().unwrap();
        fs::write(&image, b"changed-size").unwrap();
        File::options()
            .write(true)
            .open(&image)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(modified))
            .unwrap();
        assert_ne!(ReceiptKey::for_preview(id, &image, geometry).unwrap(), key);
    }

    #[test]
    fn receipts_are_bounded_private_metadata_and_reject_stale_keys() {
        let root = TransferFiles::create(&env::temp_dir()).unwrap();
        let path = root.0.join("display.receipt");
        let key = ReceiptKey(vec![1, 2, 3]);
        assert_eq!(read_receipt(&path, &key), None);
        write_receipt(&path, &key, "total=10ms decode=2 1KiB>2KiB 20x30").unwrap();
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
        assert!(read_receipt(&path, &key).unwrap().starts_with("total=10ms"));
        assert_eq!(read_receipt(&path, &ReceiptKey(vec![1, 2, 4])), None);
        assert!(write_receipt(&path, &key, "bad\x1b[2J").is_err());
        assert!(read_receipt(&path, &key).is_some());
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(read_receipt(&path, &key), None);
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        fs::write(&path, vec![b'x'; MAX_RECEIPT_BYTES + 1]).unwrap();
        assert_eq!(read_receipt(&path, &key), None);
        fs::write(&path, b"LFR1").unwrap();
        assert_eq!(read_receipt(&path, &key), None);
        fs::remove_file(&path).unwrap();
        symlink(root.0.join("missing"), &path).unwrap();
        assert_eq!(read_receipt(&path, &key), None);
        fs::remove_file(&path).unwrap();
        let fifo = CString::new(path.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        // Opening a corrupt receipt FIFO must never wait for another process.
        assert_eq!(read_receipt(&path, &key), None);
    }

    #[test]
    fn failed_receipt_publication_cleans_staging_files() {
        let root = TransferFiles::create(&env::temp_dir()).unwrap();
        let destination = root.0.join("directory");
        fs::create_dir(&destination).unwrap();
        assert!(write_receipt(&destination, &ReceiptKey(vec![1]), "total=1ms").is_err());
        assert_eq!(fs::read_dir(&root.0).unwrap().count(), 1);
    }

    #[test]
    fn escapes_controls_without_lf_greedy_octal_ambiguity() {
        let mut escaped = Vec::new();
        escape_command_body(&mut escaped, b"\x1b7\x1b8\x1b123\\\"\r\n");
        assert_eq!(
            escaped,
            b"\\033\\067\\033\\070\\033\\061\\062\\063\\\\\\\"\\r\\n"
        );
    }

    #[test]
    fn runtime_discovery_matches_go_even_without_tmpdir_on_macos() {
        assert_eq!(runtime_dir(None, None, 501), PathBuf::from("/tmp/lf-501"));
        assert_eq!(
            runtime_dir(None, Some("/custom/temp".into()), 501),
            PathBuf::from("/custom/temp/lf-501")
        );
        assert_eq!(
            runtime_dir(Some("/run/user/501".into()), None, 501),
            PathBuf::from("/run/user/501")
        );
    }

    #[test]
    fn one_small_notification_consumption_ack_and_timeout_cleanup() {
        let root = TransferFiles::create(&env::temp_dir()).unwrap();
        let socket = root.0.join("lf.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let mut protocol = b"\x1b7".to_vec();
        protocol.extend(std::iter::repeat_n(b'A', 200_000));
        protocol.extend_from_slice(b"\x1b8");
        let expected = protocol.clone();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = String::new();
            stream.read_to_string(&mut request).unwrap();
            assert!(request.len() < 1024);
            let source = request
                .strip_prefix("send 17 source \"")
                .unwrap()
                .strip_suffix("\"\n")
                .unwrap();
            let content = fs::read_to_string(source).unwrap();
            let body = content.strip_prefix("tty-write '").unwrap().as_bytes();
            assert_eq!(&body[..expected.len()], expected);
            assert!(body[expected.len()..].starts_with(b"'\n&printf x 1<> "));
            let ack = Path::new(source).parent().unwrap().join("ack");
            drop(stream); // Transport forwarding alone must not delete the source.
            assert!(Path::new(source).exists());
            OpenOptions::new()
                .write(true)
                .open(ack)
                .unwrap()
                .write_all(b"x")
                .unwrap();
        });
        let started = Instant::now();
        let mut timings = Timings::default();
        transfer(&protocol, &socket, 17, Duration::from_secs(1), &mut timings).unwrap();
        assert!(timings.stage_file + timings.notify + timings.lf_wait <= started.elapsed());
        server.join().unwrap();
        assert_eq!(fs::read_dir(&root.0).unwrap().count(), 1); // Only server socket remains.
        fs::remove_file(&socket).unwrap();

        let listener = UnixListener::bind(&socket).unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = Vec::new();
            stream.read_to_end(&mut request).unwrap();
            // Accept forwarding, but simulate lf quitting before consuming source.
        });
        let error = transfer(
            &protocol,
            &socket,
            17,
            Duration::from_millis(20),
            &mut Timings::default(),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        server.join().unwrap();
        assert_eq!(fs::read_dir(&root.0).unwrap().count(), 1);
    }

    #[test]
    fn rejects_literal_quote_in_protocol_before_creating_files() {
        let error = transfer(
            b"bad'protocol",
            Path::new("/unused/lf.sock"),
            17,
            TIMEOUT,
            &mut Timings::default(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("invalid quote"));
    }

    #[test]
    fn rejects_server_errors_and_removes_unconsumed_payload() {
        let root = TransferFiles::create(&env::temp_dir()).unwrap();
        let socket = root.0.join("lf.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = Vec::new();
            stream.read_to_end(&mut request).unwrap();
            stream
                .write_all(b"listen: send: no such client id\n")
                .unwrap();
        });
        let error = transfer(
            b"\x1b7x\x1b8",
            &socket,
            17,
            Duration::from_secs(1),
            &mut Timings::default(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("no such client id"));
        server.join().unwrap();
        assert_eq!(fs::read_dir(&root.0).unwrap().count(), 1);
    }
}
