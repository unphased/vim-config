use std::env;
use std::ffi::CString;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use crate::{emit_kitty as emit_protocol, PreparedImage, Timings};

const MAX_COMMAND_BYTES: usize = 60_000; // lf's remote scanner has a 64 KiB limit.
const TARGET_COMMAND_BYTES: usize = 48 * 1024;
const TIMEOUT: Duration = Duration::from_secs(5);
const APC_START: &[u8] = b"\x1b_G";
const APC_END: &[u8] = b"\x1b\\";
static NEXT_TRANSFER: AtomicU64 = AtomicU64::new(0);
type KittyParts<'a> = (&'a [u8], Vec<&'a [u8]>, &'a [u8]);

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
    let commands = command_lines(&protocol, id)?;
    let (prefix, _, suffix) = split_protocol(&protocol)?;
    timings.wire_bytes =
        protocol.len() + commands.len().saturating_sub(1) * (prefix.len() + suffix.len());
    timings.encode = started.elapsed();
    let started = Instant::now();
    transfer(&commands, &socket_path(), id, TIMEOUT)?;
    timings.delivery = started.elapsed();
    Ok(())
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

fn transfer(commands: &[Vec<u8>], socket: &Path, id: u32, timeout: Duration) -> io::Result<()> {
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
    let prefix = format!("send {id} ");
    for command in commands {
        output.write_all(
            command
                .strip_prefix(prefix.as_bytes())
                .ok_or_else(|| io::Error::other("invalid lf image command"))?,
        )?;
    }
    // A shell builtin acknowledges execution AFTER all tty writes. Sending all
    // image bytes over the server socket can deadlock lf when quitting under
    // backpressure; one small source notification avoids that bulk queue.
    writeln!(output, "&printf x > {}", shell_quote(&ack_path)?)?;
    drop(output);
    let mut notification = format!("send {id} source \"").into_bytes();
    escape_command_body(&mut notification, source.as_os_str().as_bytes());
    notification.extend_from_slice(b"\"\n");
    send_to_socket(&notification, socket, timeout)?;
    wait_for_ack(&mut ack, timeout)
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

pub(super) fn command_lines(protocol: &[u8], id: u32) -> io::Result<Vec<Vec<u8>>> {
    let (prefix, packets, suffix) = split_protocol(protocol)?;
    let command_prefix = format!("send {id} tty-write \"");
    let fixed_size = command_prefix.len() + escaped_len(prefix) + escaped_len(suffix) + 2;
    let mut commands = Vec::new();
    let mut batch = Vec::new();
    let mut batch_size = fixed_size;
    for packet in packets {
        let packet_size = escaped_len(packet);
        if !batch.is_empty() && batch_size + packet_size > TARGET_COMMAND_BYTES {
            commands.push(make_command(&command_prefix, prefix, &batch, suffix)?);
            batch.clear();
            batch_size = fixed_size;
        }
        if batch_size + packet_size > MAX_COMMAND_BYTES {
            return Err(io::Error::other(
                "kitty packet exceeds lf command size limit",
            ));
        }
        batch.extend_from_slice(packet);
        batch_size += packet_size;
    }
    if !batch.is_empty() {
        commands.push(make_command(&command_prefix, prefix, &batch, suffix)?);
    }
    Ok(commands)
}

fn split_protocol(protocol: &[u8]) -> io::Result<KittyParts<'_>> {
    let first = find_bytes(protocol, APC_START, 0)
        .ok_or_else(|| io::Error::other("missing kitty packet"))?;
    let prefix = &protocol[..first];
    if !prefix.starts_with(b"\x1b7") {
        return Err(io::Error::other("missing cursor save"));
    }
    let mut packets = Vec::new();
    let mut cursor = first;
    loop {
        if !protocol[cursor..].starts_with(APC_START) {
            return Err(io::Error::other("invalid kitty packet boundary"));
        }
        let end = find_bytes(protocol, APC_END, cursor + APC_START.len())
            .ok_or_else(|| io::Error::other("unterminated kitty packet"))?
            + APC_END.len();
        packets.push(&protocol[cursor..end]);
        cursor = end;
        if !protocol[cursor..].starts_with(APC_START) {
            break;
        }
    }
    if &protocol[cursor..] != b"\x1b8" {
        return Err(io::Error::other("missing cursor restore"));
    }
    Ok((prefix, packets, &protocol[cursor..]))
}

fn find_bytes(haystack: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    haystack
        .get(from..)?
        .windows(needle.len())
        .position(|window| window == needle)
        .map(|offset| from + offset)
}

fn escaped_len(bytes: &[u8]) -> usize {
    let mut output = Vec::new();
    escape_command_body(&mut output, bytes);
    output.len()
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

fn make_command(
    command_prefix: &str,
    prefix: &[u8],
    packets: &[u8],
    suffix: &[u8],
) -> io::Result<Vec<u8>> {
    let mut command = command_prefix.as_bytes().to_vec();
    escape_command_body(&mut command, prefix);
    escape_command_body(&mut command, packets);
    escape_command_body(&mut command, suffix);
    command.extend_from_slice(b"\"\n");
    if command.len() > MAX_COMMAND_BYTES {
        return Err(io::Error::other("lf command exceeds size limit"));
    }
    Ok(command)
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
    use std::os::unix::net::UnixListener;
    use std::thread;

    #[test]
    fn escapes_controls_without_lf_greedy_octal_ambiguity() {
        let mut escaped = Vec::new();
        escape_command_body(&mut escaped, b"\x1b7\x1b8\x1b123\\\"\r\n");
        assert_eq!(
            escaped,
            b"\\033\\067\\033\\070\\033\\061\\062\\063\\\\\\\"\\r\\n"
        );
        assert_eq!(escaped_len(b"\x1b7"), 8);
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
        let commands = vec![b"send 17 tty-write \"payload\"\n".to_vec()];
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
            assert!(content.starts_with("tty-write \"payload\"\n&printf x > "));
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
        transfer(&commands, &socket, 17, Duration::from_secs(1)).unwrap();
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
        let error = transfer(&commands, &socket, 17, Duration::from_millis(20)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        server.join().unwrap();
        assert_eq!(fs::read_dir(&root.0).unwrap().count(), 1);
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
            &[b"send 17 tty-write \"x\"\n".to_vec()],
            &socket,
            17,
            Duration::from_secs(1),
        )
        .unwrap_err();
        assert!(error.to_string().contains("no such client id"));
        server.join().unwrap();
        assert_eq!(fs::read_dir(&root.0).unwrap().count(), 1);
    }
}
