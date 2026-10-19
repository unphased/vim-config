//! Private, crash-recoverable Brotli frame storage for opaque encoded recording blocks.
use super::{Context, MAX_BLOCK_BYTES, Profile, Result, ownership};
use brotli::{CompressorWriter, Decompressor};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

const ARCHIVE_VERSION: u32 = 1;
const FRAME_VERSION: u32 = 1;
const ARCHIVE_FILE: &str = "archive.json";
const MANIFEST_FILE: &str = "manifest.json";
const MANIFEST_TEMP: &str = ".manifest.json.tmp";
const JOURNAL_FILE: &str = "active.journal";
const LOCK_FILE: &str = "writer.lock";
const JOURNAL_MAGIC: &[u8; 4] = b"HJR1";
const FRAME_MAGIC: &[u8; 4] = b"HFR1";
const PCR_MAGIC: &[u8; 4] = b"PCR1";
const JOURNAL_RECORD_PREFIX: usize = 8 + 8 + 32;
const JOURNAL_RECORD_SUFFIX: usize = 32;
const MAX_BLOCKS_PER_FRAME: usize = 16_384;
const MAX_FRAME_HEADER_BYTES: usize = 4 * 1024 * 1024;
const MAX_MANIFEST_BYTES: usize = 32 * 1024 * 1024;
const MAX_MANIFEST_ENTRY_BYTES: usize = 512;
const MAX_ARCHIVE_METADATA_BYTES: usize = 16 * 1024 * 1024;
const MAX_ARCHIVE_FRAMES: usize = 100_000;
const MAX_FRAME_RAW_BYTES: usize = MAX_BLOCK_BYTES + MAX_BLOCKS_PER_FRAME * 11 + 32;
const MAX_FRAME_COMPRESSED_BYTES: u64 = (MAX_FRAME_RAW_BYTES as u64) + 1024 * 1024;
const MAX_JOURNAL_BYTES: u64 = (MAX_BLOCK_BYTES as u64) * 2
    + (MAX_BLOCKS_PER_FRAME as u64) * (JOURNAL_RECORD_PREFIX as u64 + JOURNAL_RECORD_SUFFIX as u64)
    + 64;

/// Limits frame input and total archive growth. Frame input is measured as the uncompressed PCR1 wrapper.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StoreOptions {
    pub frame_bytes: usize,
    pub max_bytes: u64,
    pub min_free_bytes: u64,
}

impl Default for StoreOptions {
    fn default() -> Self {
        Self {
            frame_bytes: 16 * 1024 * 1024,
            max_bytes: 8 * 1024 * 1024 * 1024,
            min_free_bytes: 0,
        }
    }
}

impl StoreOptions {
    fn validate(self) -> Result<()> {
        if self.frame_bytes == 0 || self.frame_bytes > MAX_BLOCK_BYTES {
            return Err(format!("frame_bytes must be in 1..={MAX_BLOCK_BYTES}"));
        }
        if self.max_bytes == 0 {
            return Err("max_bytes must be positive".into());
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ArchiveMetadata {
    format: String,
    version: u32,
    context: Context,
    profile: Profile,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BlockRef {
    id: u64,
    raw_bytes: u64,
    sha256: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct FrameHeader {
    version: u32,
    codec: String,
    quality: u8,
    window_log: u8,
    first_block: u64,
    last_block: u64,
    payload_bytes: u64,
    compressed_bytes: u64,
    payload_sha256: String,
    blocks: Vec<BlockRef>,
}

struct FrameFileInfo {
    payload_offset: usize,
    compressed_bytes: u64,
    checksum: [u8; 32],
    file_bytes: u64,
}

#[derive(Clone, Debug)]
struct FrameInfo {
    name: String,
    first: u64,
    last: u64,
    count: u64,
    payload_bytes: u64,
    compressed_bytes: u64,
    file_bytes: u64,
    payload_sha256: String,
    file_sha256: String,
}

#[derive(Serialize)]
struct Manifest<'a> {
    format: &'static str,
    version: u32,
    frames: Vec<ManifestFrame<'a>>,
}

#[derive(Serialize)]
struct ManifestFrame<'a> {
    file: &'a str,
    first_block: u64,
    last_block: u64,
    block_count: u64,
    payload_bytes: u64,
    compressed_bytes: u64,
    file_bytes: u64,
    payload_sha256: &'a str,
    file_sha256: &'a str,
}

/// Median encoder measurements for three sequential Brotli runs over one PCR1 frame.
#[derive(Clone, Debug, Serialize)]
pub struct FrameBenchmark {
    pub input_bytes: u64,
    pub compressed_bytes: u64,
    pub encoder_cpu_seconds: f64,
    pub encoder_wall_seconds: f64,
    pub repeats: u32,
}

/// Bounded accumulator shared by source and cached codec benchmarks.
pub(crate) struct CodecFrameAccumulator {
    frame_bytes: usize,
    pending: Vec<Vec<u8>>,
    pending_block_bytes: usize,
    pub(crate) input_bytes: u64,
    pub(crate) compressed_bytes: u64,
    pub(crate) encoder_cpu_seconds: f64,
    pub(crate) encoder_wall_seconds: f64,
    pub(crate) frames: u64,
    pub(crate) repeats: u64,
    pub(crate) max_input_bytes: u64,
}

impl CodecFrameAccumulator {
    pub(crate) fn new(frame_bytes: usize) -> Result<Self> {
        if frame_bytes == 0 || frame_bytes > MAX_BLOCK_BYTES {
            return Err(format!("frame_bytes must be in 1..={MAX_BLOCK_BYTES}"));
        }
        Ok(Self {
            frame_bytes,
            pending: Vec::new(),
            pending_block_bytes: 0,
            input_bytes: 0,
            compressed_bytes: 0,
            encoder_cpu_seconds: 0.0,
            encoder_wall_seconds: 0.0,
            frames: 0,
            repeats: 0,
            max_input_bytes: 0,
        })
    }

    pub(crate) fn push(&mut self, block: &[u8]) -> Result<()> {
        if block.is_empty() || block.len() > MAX_BLOCK_BYTES {
            return Err(format!("block length must be in 1..={MAX_BLOCK_BYTES}"));
        }
        let next_block_bytes = self
            .pending_block_bytes
            .checked_add(varint_len(block.len() as u64) + block.len())
            .ok_or_else(|| "codec frame input size overflow".to_string())?;
        let projected = 4 + varint_len((self.pending.len() + 1) as u64) + next_block_bytes;
        if !self.pending.is_empty()
            && (projected > self.frame_bytes || self.pending.len() >= MAX_BLOCKS_PER_FRAME)
        {
            self.flush()?;
        }
        self.pending_block_bytes = self
            .pending_block_bytes
            .checked_add(varint_len(block.len() as u64) + block.len())
            .ok_or_else(|| "codec frame input size overflow".to_string())?;
        self.pending.push(block.to_vec());
        let input_bytes = 4 + varint_len(self.pending.len() as u64) + self.pending_block_bytes;
        if input_bytes >= self.frame_bytes || self.pending.len() >= MAX_BLOCKS_PER_FRAME {
            self.flush()?;
        }
        Ok(())
    }

    pub(crate) fn finish(&mut self) -> Result<()> {
        self.flush()
    }

    fn flush(&mut self) -> Result<()> {
        if self.pending.is_empty() {
            return Ok(());
        }
        let result = benchmark_frame(&self.pending)?;
        self.input_bytes = self.input_bytes.saturating_add(result.input_bytes);
        self.compressed_bytes = self
            .compressed_bytes
            .saturating_add(result.compressed_bytes);
        self.encoder_cpu_seconds += result.encoder_cpu_seconds;
        self.encoder_wall_seconds += result.encoder_wall_seconds;
        self.frames = self.frames.saturating_add(1);
        self.repeats = self.repeats.saturating_add(result.repeats as u64);
        self.max_input_bytes = self.max_input_bytes.max(result.input_bytes);
        self.pending.clear();
        self.pending_block_bytes = 0;
        Ok(())
    }
}

#[derive(Clone)]
struct StoredBlock {
    id: u64,
    bytes: Vec<u8>,
    sha256: [u8; 32],
}

/// Writes a single run/profile archive. `append` durably journals every accepted block.
pub struct ArchiveWriter {
    root: PathBuf,
    options: StoreOptions,
    _lock: File,
    frames: Vec<FrameInfo>,
    active: Vec<StoredBlock>,
    active_wire_bytes: usize,
    usage_bytes: u64,
    next_id: u64,
    poisoned: bool,
    recovery_report: Vec<String>,
}

impl ArchiveWriter {
    pub fn open(
        path: &Path,
        context: &Context,
        profile: Profile,
        options: StoreOptions,
    ) -> Result<Self> {
        options.validate()?;
        context.validate()?;
        let root = prepare_root(path)?;
        let lock = acquire_lock(&root)?;

        remove_owned_temp(&root, MANIFEST_TEMP)?;
        remove_owned_temp(&root, ".archive.json.tmp")?;
        cleanup_frame_temps(&root)?;
        let mut metadata = read_metadata_if_exists(&root)?;
        if let Some(found) = &metadata {
            if found.version != ARCHIVE_VERSION || found.format != "pane-load-recording-archive" {
                return Err("unsupported recording archive metadata".into());
            }
            found.context.validate()?;
            if found.context != *context || found.profile != profile {
                return Err("archive context/profile does not match requested writer".into());
            }
        } else {
            if contains_recording_content(&root)? {
                return Err("archive metadata is missing from a non-empty store".into());
            }
            let value = ArchiveMetadata {
                format: "pane-load-recording-archive".into(),
                version: ARCHIVE_VERSION,
                context: context.clone(),
                profile,
            };
            let bytes =
                serde_json::to_vec(&value).map_err(|e| format!("encode archive metadata: {e}"))?;
            if bytes.len() > MAX_ARCHIVE_METADATA_BYTES {
                return Err("archive metadata exceeds size limit".into());
            }
            atomic_write_new(&root, ARCHIVE_FILE, ".archive.json.tmp", &bytes, options)?;
            metadata = Some(value);
        }
        let _metadata =
            metadata.ok_or_else(|| "archive metadata initialization failed".to_string())?;

        let frames = scan_frames(&root)?;
        validate_frame_sequence(&frames)?;
        let usage_bytes = directory_bytes(&root)?;
        let mut writer = Self {
            root,
            options,
            _lock: lock,
            frames,
            active: Vec::new(),
            active_wire_bytes: 0,
            usage_bytes,
            next_id: 0,
            poisoned: false,
            recovery_report: Vec::new(),
        };
        writer.rebuild_manifest()?;
        writer.recover_journal()?;
        writer.next_id = writer.frames.last().map_or(Ok(0), |frame| {
            frame
                .last
                .checked_add(1)
                .ok_or_else(|| "recording block id exhausted".to_string())
        })?;
        Ok(writer)
    }

    /// Adds an opaque PST block. A block is durable before this method succeeds.
    pub fn append(&mut self, block: &[u8]) -> Result<()> {
        if self.poisoned {
            return Err(
                "archive writer is unusable after a storage error; reopen to recover".into(),
            );
        }
        if block.is_empty() || block.len() > MAX_BLOCK_BYTES {
            return Err(format!("block length must be in 1..={MAX_BLOCK_BYTES}"));
        }
        if self.next_id == u64::MAX {
            return Err("recording block id exhausted".into());
        }
        if self.frames.len() >= MAX_ARCHIVE_FRAMES {
            return Err("archive has too many frames".into());
        }

        if !self.active.is_empty()
            && (self.active.len() >= MAX_BLOCKS_PER_FRAME
                || self.projected_payload_len(block.len())? > self.options.frame_bytes)
        {
            self.flush_frame()?;
        }
        if self.frames.len() >= MAX_ARCHIVE_FRAMES {
            return Err("archive has too many frames".into());
        }
        self.preflight_pending_manifest(block.len())?;

        let id = self.next_id;
        let sha256: [u8; 32] = Sha256::digest(block).into();
        let record = journal_record(id, block, &sha256);
        let journal_exists = self.root.join(JOURNAL_FILE).exists();
        let additional = record.len()
            + if journal_exists {
                0
            } else {
                JOURNAL_MAGIC.len()
            };
        ensure_capacity_at(
            &self.root,
            self.options,
            self.usage_bytes,
            additional as u64,
        )?;
        let journal_path = self.root.join(JOURNAL_FILE);
        let result = (|| -> Result<()> {
            let mut file = if journal_exists {
                let mut file = open_existing_regular(&journal_path, true)?;
                file.seek(SeekFrom::End(0))
                    .map_err(io_error("seek journal end"))?;
                file
            } else {
                create_private_new(&journal_path)?
            };
            if !journal_exists {
                file.write_all(JOURNAL_MAGIC)
                    .map_err(io_error("write journal header"))?;
            }
            file.write_all(&record)
                .map_err(io_error("append journal record"))?;
            file.sync_all().map_err(io_error("sync journal"))?;
            if !journal_exists {
                sync_directory(&self.root)?;
            }
            Ok(())
        })();
        if let Err(e) = result {
            self.poisoned = true;
            return Err(e);
        }
        self.usage_bytes = self
            .usage_bytes
            .checked_add(additional as u64)
            .ok_or_else(|| "archive size overflow".to_string())?;

        self.active_wire_bytes = self
            .active_wire_bytes
            .checked_add(varint_len(block.len() as u64) + block.len())
            .ok_or_else(|| "frame size overflow".to_string())?;
        self.active.push(StoredBlock {
            id,
            bytes: block.to_vec(),
            sha256,
        });
        self.next_id += 1;
        if self.active.len() >= MAX_BLOCKS_PER_FRAME
            || self.current_payload_len()? >= self.options.frame_bytes
        {
            self.flush_frame()?;
        }
        Ok(())
    }

    /// Whether there are durable blocks waiting in the active frame.
    pub fn has_active_frame(&self) -> bool {
        !self.active.is_empty()
    }

    /// Publishes the current durable tail as an immutable partial frame.
    pub fn flush_frame(&mut self) -> Result<()> {
        if self.poisoned {
            return Err(
                "archive writer is unusable after a storage error; reopen to recover".into(),
            );
        }
        if self.active.is_empty() {
            return Ok(());
        }
        let blocks = std::mem::take(&mut self.active);
        self.active_wire_bytes = 0;
        if let Err(e) = self.publish_blocks(&blocks, true) {
            self.poisoned = true;
            return Err(e);
        }
        Ok(())
    }

    /// Flushes a final partial frame. Call this on orderly shutdown (including SIGTERM handling).
    pub fn finish(mut self) -> Result<()> {
        self.flush_frame()
    }

    /// Reports journal-tail repairs performed during `open`.
    pub fn recovery_report(&self) -> &[String] {
        &self.recovery_report
    }

    fn projected_payload_len(&self, next_block_bytes: usize) -> Result<usize> {
        let block_wire = varint_len(next_block_bytes as u64)
            .checked_add(next_block_bytes)
            .ok_or_else(|| "frame size overflow".to_string())?;
        4usize
            .checked_add(varint_len((self.active.len() + 1) as u64))
            .and_then(|n| n.checked_add(self.active_wire_bytes))
            .and_then(|n| n.checked_add(block_wire))
            .ok_or_else(|| "frame size overflow".into())
    }

    fn current_payload_len(&self) -> Result<usize> {
        4usize
            .checked_add(varint_len(self.active.len() as u64))
            .and_then(|n| n.checked_add(self.active_wire_bytes))
            .ok_or_else(|| "frame size overflow".into())
    }

    fn recover_journal(&mut self) -> Result<()> {
        let path = self.root.join(JOURNAL_FILE);
        if !path.exists() {
            return Ok(());
        }
        let (blocks, malformed_at) = self.read_journal_prefix()?;
        if let Some(offset) = malformed_at {
            self.recovery_report.push(format!(
                "discarded invalid trailing journal suffix at byte {offset}"
            ));
        }
        if blocks.is_empty() {
            self.rebuild_manifest()?;
            let journal_bytes = fs::metadata(&path).map_err(io_error("stat journal"))?.len();
            remove_owned_regular(&self.root, JOURNAL_FILE)?;
            self.usage_bytes = self.usage_bytes.saturating_sub(journal_bytes);
            sync_directory(&self.root)?;
            return Ok(());
        }
        let mut pending = Vec::new();
        let mut expected_new = self.frames.last().map_or(Ok(0), |frame| {
            frame
                .last
                .checked_add(1)
                .ok_or_else(|| "recording block id exhausted".to_string())
        })?;
        let mut cached_frame: Option<(String, Vec<BlockRef>)> = None;
        for block in blocks {
            if block.id < expected_new {
                let frame = self
                    .frames
                    .iter()
                    .find(|frame| frame.first <= block.id && block.id <= frame.last)
                    .ok_or_else(|| {
                        format!(
                            "journal block {} is below archive range but not committed",
                            block.id
                        )
                    })?;
                if cached_frame
                    .as_ref()
                    .is_none_or(|(name, _)| name != &frame.name)
                {
                    let (header, _) = read_frame_header(&self.root.join(&frame.name))?;
                    cached_frame = Some((frame.name.clone(), header.blocks));
                }
                let refs = &cached_frame
                    .as_ref()
                    .ok_or_else(|| "committed frame metadata was not cached".to_string())?
                    .1;
                let index = usize::try_from(block.id - frame.first)
                    .map_err(|_| "block id index overflow")?;
                let known = refs
                    .get(index)
                    .ok_or_else(|| "frame block index mismatch".to_string())?;
                if known.raw_bytes != block.bytes.len() as u64
                    || decode_hex_32(&known.sha256)? != block.sha256
                {
                    return Err(format!(
                        "journal block {} conflicts with immutable frame",
                        block.id
                    ));
                }
            } else if block.id == expected_new {
                pending.push(block);
                expected_new = expected_new
                    .checked_add(1)
                    .ok_or_else(|| "recording block id exhausted".to_string())?;
            } else {
                self.recovery_report.push(format!(
                    "discarded non-contiguous journal tail beginning at block {}",
                    block.id
                ));
                break;
            }
        }
        if pending.is_empty() {
            self.rebuild_manifest()?;
            let journal_bytes = fs::metadata(&path).map_err(io_error("stat journal"))?.len();
            remove_owned_regular(&self.root, JOURNAL_FILE)?;
            self.usage_bytes = self.usage_bytes.saturating_sub(journal_bytes);
            sync_directory(&self.root)?;
        } else {
            self.publish_blocks(&pending, true)?;
        }
        Ok(())
    }

    fn read_journal_prefix(&mut self) -> Result<(Vec<StoredBlock>, Option<u64>)> {
        let path = self.root.join(JOURNAL_FILE);
        let mut file = open_existing_regular(&path, false)?;
        let size = file.metadata().map_err(io_error("stat journal"))?.len();
        let mut magic = [0u8; 4];
        let read = read_partial(&mut file, &mut magic).map_err(io_error("read journal header"))?;
        if read != 4 || &magic != JOURNAL_MAGIC {
            return Ok((Vec::new(), Some(0)));
        }
        let mut valid = Vec::new();
        let mut offset = 4u64;
        let mut previous_id = None;
        loop {
            let mut prefix = [0u8; JOURNAL_RECORD_PREFIX];
            let got =
                read_partial(&mut file, &mut prefix).map_err(io_error("read journal record"))?;
            if got == 0 {
                return Ok((
                    valid,
                    if size > MAX_JOURNAL_BYTES {
                        Some(offset)
                    } else {
                        None
                    },
                ));
            }
            if got != prefix.len() {
                return Ok((valid, Some(offset)));
            }
            let id = u64::from_le_bytes(
                prefix[..8]
                    .try_into()
                    .map_err(|_| "invalid journal block id".to_string())?,
            );
            let len64 = u64::from_le_bytes(
                prefix[8..16]
                    .try_into()
                    .map_err(|_| "invalid journal block length".to_string())?,
            );
            if len64 == 0 || len64 > MAX_BLOCK_BYTES as u64 || valid.len() >= MAX_BLOCKS_PER_FRAME {
                return Ok((valid, Some(offset)));
            }
            let record_size = (JOURNAL_RECORD_PREFIX as u64)
                .checked_add(len64)
                .and_then(|n| n.checked_add(JOURNAL_RECORD_SUFFIX as u64))
                .ok_or_else(|| "journal record length overflow".to_string())?;
            if offset
                .checked_add(record_size)
                .is_none_or(|end| end > MAX_JOURNAL_BYTES)
            {
                return Ok((valid, Some(offset)));
            }
            if previous_id.is_some_and(|prev: u64| prev.checked_add(1) != Some(id)) {
                return Ok((valid, Some(offset)));
            }
            let len =
                usize::try_from(len64).map_err(|_| "journal block length does not fit memory")?;
            let expected_sha: [u8; 32] = prefix[16..48]
                .try_into()
                .map_err(|_| "invalid journal block digest".to_string())?;
            let mut block = vec![0; len];
            if read_partial(&mut file, &mut block).map_err(io_error("read journal block"))? != len {
                return Ok((valid, Some(offset)));
            }
            let mut checksum = [0u8; JOURNAL_RECORD_SUFFIX];
            if read_partial(&mut file, &mut checksum).map_err(io_error("read journal checksum"))?
                != checksum.len()
            {
                return Ok((valid, Some(offset)));
            }
            let mut record_hash = Sha256::new();
            record_hash.update(prefix);
            record_hash.update(&block);
            let actual_record_hash: [u8; 32] = record_hash.finalize().into();
            let actual_sha: [u8; 32] = Sha256::digest(&block).into();
            if actual_record_hash != checksum || actual_sha != expected_sha {
                return Ok((valid, Some(offset)));
            }
            offset = offset
                .checked_add((JOURNAL_RECORD_PREFIX + len + JOURNAL_RECORD_SUFFIX) as u64)
                .ok_or_else(|| "journal offset overflow".to_string())?;
            previous_id = Some(id);
            valid.push(StoredBlock {
                id,
                bytes: block,
                sha256: actual_sha,
            });
        }
    }

    fn publish_blocks(&mut self, blocks: &[StoredBlock], remove_journal: bool) -> Result<()> {
        if blocks.is_empty() {
            return Ok(());
        }
        if blocks.len() > MAX_BLOCKS_PER_FRAME {
            return Err("too many blocks in frame".into());
        }
        for pair in blocks.windows(2) {
            if pair[0].id.checked_add(1) != Some(pair[1].id) {
                return Err("frame block ids are not contiguous".into());
            }
        }
        let first = blocks[0].id;
        let last = blocks[blocks.len() - 1].id;
        if let Some(previous) = self.frames.last() {
            if previous.last.checked_add(1) != Some(first) {
                return Err("new frame does not continue the committed block range".into());
            }
        } else if first != 0 {
            return Err("first frame must begin with block id zero".into());
        }

        let payload = pack_pcr_frame(blocks)?;
        let payload_sha: [u8; 32] = Sha256::digest(&payload).into();
        let compressed = compress_payload(&payload)?;
        let header = FrameHeader {
            version: FRAME_VERSION,
            codec: "brotli".into(),
            quality: 5,
            window_log: 20,
            first_block: first,
            last_block: last,
            payload_bytes: payload.len() as u64,
            compressed_bytes: compressed.len() as u64,
            payload_sha256: hex(&payload_sha),
            blocks: blocks
                .iter()
                .map(|block| BlockRef {
                    id: block.id,
                    raw_bytes: block.bytes.len() as u64,
                    sha256: hex(&block.sha256),
                })
                .collect(),
        };
        let header_bytes =
            serde_json::to_vec(&header).map_err(|e| format!("encode frame header: {e}"))?;
        if header_bytes.len() > MAX_FRAME_HEADER_BYTES {
            return Err("frame header exceeds size limit".into());
        }
        let filename = frame_filename(first, last);
        let final_path = self.root.join(&filename);
        let mut prefix = Vec::with_capacity(8 + header_bytes.len());
        prefix.extend_from_slice(FRAME_MAGIC);
        prefix.extend_from_slice(&(header_bytes.len() as u32).to_le_bytes());
        prefix.extend_from_slice(&header_bytes);
        let file_size = (prefix.len() as u64)
            .checked_add(compressed.len() as u64)
            .and_then(|size| size.checked_add(32))
            .ok_or_else(|| "compressed frame size overflow".to_string())?;
        if file_size > MAX_FRAME_COMPRESSED_BYTES + MAX_FRAME_HEADER_BYTES as u64 + 8 {
            return Err("compressed frame exceeds size limit".into());
        }
        let mut file_hash = Sha256::new();
        file_hash.update(&prefix);
        file_hash.update(&compressed);
        let digest: [u8; 32] = file_hash.finalize().into();
        let proposed = FrameInfo {
            name: filename.clone(),
            first,
            last,
            count: blocks.len() as u64,
            payload_bytes: payload.len() as u64,
            compressed_bytes: compressed.len() as u64,
            file_bytes: file_size,
            payload_sha256: hex(&payload_sha),
            file_sha256: hex(&digest),
        };
        if fs::symlink_metadata(&final_path).is_ok() {
            let existing = verify_frame(&final_path, &mut |_| Ok(()))?;
            if existing.first != first
                || existing.last != last
                || existing.payload_sha256 != hex(&payload_sha)
                || !same_block_refs(&read_frame_header(&final_path)?.0.blocks, &header.blocks)?
            {
                return Err(format!(
                    "conflicting immutable frame already exists: {filename}"
                ));
            }
            if !self.frames.iter().any(|frame| frame.name == filename) {
                self.preflight_publication(&existing, 0)?;
                self.frames.push(existing);
                self.frames.sort_by_key(|frame| frame.first);
            }
        } else {
            self.preflight_publication(&proposed, file_size)?;
            let tmp_name = format!("{filename}.tmp");
            let tmp_path = self.root.join(&tmp_name);
            let mut file = create_private_new(&tmp_path)?;
            file.write_all(&prefix)
                .map_err(io_error("write frame header"))?;
            file.write_all(&compressed)
                .map_err(io_error("write compressed frame"))?;
            file.write_all(&digest)
                .map_err(io_error("write frame checksum"))?;
            file.sync_all().map_err(io_error("sync frame"))?;
            if fs::symlink_metadata(&final_path).is_ok() {
                remove_owned_regular(&self.root, &tmp_name)?;
                return Err(format!("refusing to overwrite immutable frame: {filename}"));
            }
            rename_noreplace(&tmp_path, &final_path)
                .map_err(io_error("publish immutable frame"))?;
            self.usage_bytes = self
                .usage_bytes
                .checked_add(file_size)
                .ok_or_else(|| "archive size overflow".to_string())?;
            sync_directory(&self.root)?;
            self.frames.push(proposed);
            self.frames.sort_by_key(|frame| frame.first);
        }
        validate_frame_sequence(&self.frames)?;
        self.rebuild_manifest()?;
        if remove_journal && self.root.join(JOURNAL_FILE).exists() {
            let journal_bytes = fs::metadata(self.root.join(JOURNAL_FILE))
                .map_err(io_error("stat journal"))?
                .len();
            remove_owned_regular(&self.root, JOURNAL_FILE)?;
            self.usage_bytes = self.usage_bytes.saturating_sub(journal_bytes);
            sync_directory(&self.root)?;
        }
        Ok(())
    }

    fn preflight_pending_manifest(&self, next_block_bytes: usize) -> Result<()> {
        if !self.active.is_empty()
            || self.frames.len() < MAX_MANIFEST_BYTES / MAX_MANIFEST_ENTRY_BYTES
        {
            return Ok(());
        }
        let manifest = open_existing_regular(&self.root.join(MANIFEST_FILE), false)?;
        let current_bytes = manifest
            .metadata()
            .map_err(io_error("stat archive manifest"))?
            .len();
        if current_bytes.saturating_add(MAX_MANIFEST_ENTRY_BYTES as u64)
            <= MAX_MANIFEST_BYTES as u64
        {
            return Ok(());
        }
        let first = self.active.first().map_or(self.next_id, |block| block.id);
        let candidate = FrameInfo {
            name: frame_filename(first, self.next_id),
            first,
            last: self.next_id,
            count: (self.active.len() + 1) as u64,
            payload_bytes: self.projected_payload_len(next_block_bytes)? as u64,
            compressed_bytes: MAX_FRAME_COMPRESSED_BYTES,
            file_bytes: MAX_FRAME_COMPRESSED_BYTES + MAX_FRAME_HEADER_BYTES as u64 + 40,
            payload_sha256: "0".repeat(64),
            file_sha256: "0".repeat(64),
        };
        self.encode_manifest_with_candidate(&candidate).map(|_| ())
    }

    fn encode_manifest_with_candidate(&self, candidate: &FrameInfo) -> Result<Vec<u8>> {
        let mut frames = self.frames.clone();
        frames.push(candidate.clone());
        frames.sort_by_key(|frame| frame.first);
        validate_frame_sequence(&frames)?;
        encode_manifest(&frames)
    }

    fn preflight_publication(&self, frame: &FrameInfo, frame_bytes: u64) -> Result<()> {
        let manifest = self.encode_manifest_with_candidate(frame)?;
        let additional = frame_bytes
            .checked_add(manifest.len() as u64)
            .ok_or_else(|| "archive publication size overflow".to_string())?;
        ensure_capacity_at(&self.root, self.options, self.usage_bytes, additional)
    }

    fn rebuild_manifest(&mut self) -> Result<()> {
        let bytes = encode_manifest(&self.frames)?;
        let current = self.root.join(MANIFEST_FILE);
        if let Ok(meta) = fs::symlink_metadata(&current) {
            if meta.file_type().is_symlink()
                || !meta.is_file()
                || meta.uid() != ownership::expected_uid()
            {
                return Err("unsafe archive manifest".into());
            }
            if meta.len() <= MAX_MANIFEST_BYTES as u64
                && read_private_file(&current, MAX_MANIFEST_BYTES)? == bytes
            {
                return Ok(());
            }
        }
        atomic_replace(
            &self.root,
            MANIFEST_FILE,
            MANIFEST_TEMP,
            &bytes,
            self.options,
            &mut self.usage_bytes,
        )
    }
}

fn encode_manifest(frames: &[FrameInfo]) -> Result<Vec<u8>> {
    if frames.len() > MAX_ARCHIVE_FRAMES {
        return Err("archive has too many frames".into());
    }
    let manifest = Manifest {
        format: "pane-load-recording-manifest",
        version: ARCHIVE_VERSION,
        frames: frames
            .iter()
            .map(|frame| ManifestFrame {
                file: &frame.name,
                first_block: frame.first,
                last_block: frame.last,
                block_count: frame.count,
                payload_bytes: frame.payload_bytes,
                compressed_bytes: frame.compressed_bytes,
                file_bytes: frame.file_bytes,
                payload_sha256: &frame.payload_sha256,
                file_sha256: &frame.file_sha256,
            })
            .collect(),
    };
    let bytes =
        serde_json::to_vec(&manifest).map_err(|e| format!("encode archive manifest: {e}"))?;
    if bytes.len() > MAX_MANIFEST_BYTES {
        return Err("archive manifest exceeds size limit".into());
    }
    Ok(bytes)
}

/// Visits decoded PST blocks in committed frame order without materializing the archive.
pub fn visit_blocks(path: &Path, mut callback: impl FnMut(&[u8]) -> Result<()>) -> Result<()> {
    let root = existing_root(path)?;
    let metadata = read_metadata(&root)?;
    metadata.context.validate()?;
    let frames = scan_frames_with(&root, &mut callback)?;
    validate_frame_sequence(&frames)
}

/// Small-archive convenience helper. Production readers should use `visit_blocks`.
pub fn read_archive(path: &Path) -> Result<Vec<Vec<u8>>> {
    let mut blocks = Vec::new();
    visit_blocks(path, |block| {
        blocks.push(block.to_vec());
        Ok(())
    })?;
    Ok(blocks)
}

/// Benchmarks the archive's Brotli settings, excluding PCR1 packing and verification.
pub fn benchmark_frame(blocks: &[Vec<u8>]) -> Result<FrameBenchmark> {
    if blocks.is_empty() || blocks.len() > MAX_BLOCKS_PER_FRAME {
        return Err(format!(
            "frame block count must be in 1..={MAX_BLOCKS_PER_FRAME}"
        ));
    }
    if blocks
        .iter()
        .any(|block| block.is_empty() || block.len() > MAX_BLOCK_BYTES)
    {
        return Err(format!("block length must be in 1..={MAX_BLOCK_BYTES}"));
    }
    let payload = pack_pcr_payload(blocks.iter().map(Vec::as_slice), blocks.len())?;
    let mut cpu_samples = Vec::with_capacity(3);
    let mut wall_samples = Vec::with_capacity(3);
    let mut compressed_bytes = None;
    for _ in 0..3 {
        let cpu_start = process_cpu_seconds()?;
        let wall_start = std::time::Instant::now();
        let compressed = compress_payload(&payload)?;
        let wall_seconds = wall_start.elapsed().as_secs_f64();
        let cpu_seconds = (process_cpu_seconds()? - cpu_start).max(0.0);
        if compressed_bytes.is_some_and(|size| size != compressed.len()) {
            return Err("Brotli output size varied between benchmark repeats".into());
        }
        compressed_bytes = Some(compressed.len());
        cpu_samples.push(cpu_seconds);
        wall_samples.push(wall_seconds);

        let mut decoded = Vec::with_capacity(payload.len());
        Decompressor::new(compressed.as_slice(), 4096)
            .take(payload.len() as u64 + 1)
            .read_to_end(&mut decoded)
            .map_err(io_error("verify benchmark decompression"))?;
        if decoded != payload {
            return Err("benchmark decompression did not reproduce PCR1 input".into());
        }
    }
    cpu_samples.sort_by(f64::total_cmp);
    wall_samples.sort_by(f64::total_cmp);
    Ok(FrameBenchmark {
        input_bytes: payload.len() as u64,
        compressed_bytes: compressed_bytes.ok_or_else(|| "missing benchmark result".to_string())?
            as u64,
        encoder_cpu_seconds: cpu_samples[1],
        encoder_wall_seconds: wall_samples[1],
        repeats: 3,
    })
}

fn process_cpu_seconds() -> Result<f64> {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } != 0 {
        return Err(format!(
            "read process CPU usage: {}",
            io::Error::last_os_error()
        ));
    }
    let usage = unsafe { usage.assume_init() };
    let timeval_seconds =
        |time: libc::timeval| time.tv_sec as f64 + time.tv_usec as f64 / 1_000_000.0;
    Ok(timeval_seconds(usage.ru_utime) + timeval_seconds(usage.ru_stime))
}

fn compress_payload(payload: &[u8]) -> Result<Vec<u8>> {
    let mut compressed = Vec::new();
    {
        let mut encoder = CompressorWriter::new(&mut compressed, 4096, 5, 20);
        encoder
            .write_all(payload)
            .map_err(io_error("compress frame"))?;
        encoder.flush().map_err(io_error("finish Brotli frame"))?;
    }
    Ok(compressed)
}

fn scan_frames(root: &Path) -> Result<Vec<FrameInfo>> {
    scan_frames_with(root, &mut |_| Ok(()))
}

fn scan_frames_with(
    root: &Path,
    callback: &mut impl FnMut(&[u8]) -> Result<()>,
) -> Result<Vec<FrameInfo>> {
    let mut paths = Vec::new();
    for entry in fs::read_dir(root).map_err(io_error("list archive"))? {
        let entry = entry.map_err(io_error("read archive entry"))?;
        let name_os = entry.file_name();
        let name = name_os
            .to_str()
            .ok_or_else(|| "archive contains a non-UTF8 filename".to_string())?;
        let metadata =
            fs::symlink_metadata(entry.path()).map_err(io_error("inspect archive entry"))?;
        if metadata.file_type().is_symlink()
            || !metadata.is_file()
            || metadata.uid() != ownership::expected_uid()
        {
            return Err(format!("unsafe or unowned archive entry: {name}"));
        }
        if metadata.permissions().mode() & 0o777 != 0o600 {
            let _protected = open_existing_regular(&entry.path(), false)?;
        }
        if name.ends_with(".pcr") {
            if paths.len() >= MAX_ARCHIVE_FRAMES {
                return Err("archive has too many frames".into());
            }
            paths.push((name.to_owned(), entry.path()));
        } else if matches!(
            name,
            ARCHIVE_FILE | MANIFEST_FILE | MANIFEST_TEMP | JOURNAL_FILE | LOCK_FILE
        ) || name.starts_with("frame-") && name.ends_with(".tmp")
        {
            // Temporary publications and the active journal are not authoritative frames.
        } else {
            return Err(format!("unexpected archive entry: {name}"));
        }
    }
    paths.sort_by(|a, b| a.0.cmp(&b.0));

    // Validate the complete filename/header catalog before a callback can observe any block.
    let mut catalog = Vec::with_capacity(paths.len());
    for (name, path) in &paths {
        let (named_first, named_last) = parse_frame_filename(name)?;
        let (header, file_info) = read_frame_header(path)?;
        if (named_first, named_last) != (header.first_block, header.last_block) {
            return Err(format!("frame filename/content range mismatch: {name}"));
        }
        catalog.push(frame_info(name.clone(), &header, &file_info));
    }
    validate_frame_sequence(&catalog)?;

    let mut verified = Vec::with_capacity(paths.len());
    for (name, path) in paths {
        let frame = verify_frame(&path, callback)?;
        if frame.name != name {
            return Err(format!("frame filename changed during read: {name}"));
        }
        verified.push(frame);
    }
    Ok(verified)
}

fn verify_frame(path: &Path, callback: &mut impl FnMut(&[u8]) -> Result<()>) -> Result<FrameInfo> {
    let (header, file_info) = read_frame_header(path)?;
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| "invalid frame filename".to_string())?;
    if parse_frame_filename(name)? != (header.first_block, header.last_block) {
        return Err(format!("frame filename/content range mismatch: {name}"));
    }
    verify_frame_digest(
        path,
        file_info.payload_offset,
        file_info.compressed_bytes,
        &file_info.checksum,
    )?;
    let mut file = open_existing_regular(path, false)?;
    file.seek(SeekFrom::Start(file_info.payload_offset as u64))
        .map_err(io_error("seek frame payload"))?;
    let limited = file.take(header.compressed_bytes);
    let decompressor = Decompressor::new(limited, 4096);
    let mut bounded = BoundedReader {
        inner: decompressor,
        remaining: MAX_FRAME_RAW_BYTES,
    };
    let mut payload = Vec::with_capacity(header.payload_bytes as usize);
    bounded
        .read_to_end(&mut payload)
        .map_err(io_error("decompress frame payload"))?;
    let mut decompressor = bounded.inner;
    let mut decoded_extra = [0u8; 1];
    if decompressor
        .read(&mut decoded_extra)
        .map_err(io_error("finish Brotli frame"))?
        != 0
    {
        return Err("decompressed frame exceeds size limit".into());
    }
    let compressed_input = decompressor.into_inner();
    if compressed_input.limit() != 0 {
        return Err("truncated Brotli frame".into());
    }
    if payload.len() as u64 != header.payload_bytes
        || hex(&Sha256::digest(&payload)) != header.payload_sha256
    {
        return Err("frame payload checksum/length mismatch".into());
    }
    if payload.get(..4) != Some(PCR_MAGIC.as_slice()) {
        return Err("invalid PCR1 frame payload".into());
    }
    let mut cursor = io::Cursor::new(&payload[4..]);
    let count = read_uvarint(&mut cursor)?;
    if count != header.blocks.len() as u64 {
        return Err("PCR1 frame block count mismatch".into());
    }
    let mut block_ranges = Vec::with_capacity(header.blocks.len());
    for expected in &header.blocks {
        let len = read_uvarint(&mut cursor)?;
        if len == 0 || len > MAX_BLOCK_BYTES as u64 || len != expected.raw_bytes {
            return Err(format!("invalid frame block length for id {}", expected.id));
        }
        let start = 4usize
            .checked_add(usize::try_from(cursor.position()).map_err(|_| "payload offset overflow")?)
            .ok_or_else(|| "payload offset overflow".to_string())?;
        let end = start
            .checked_add(usize::try_from(len).map_err(|_| "block length does not fit memory")?)
            .ok_or_else(|| "payload offset overflow".to_string())?;
        let block = payload
            .get(start..end)
            .ok_or_else(|| "truncated PCR1 block".to_string())?;
        let actual: [u8; 32] = Sha256::digest(block).into();
        if hex(&actual) != expected.sha256 {
            return Err(format!("frame block {} checksum mismatch", expected.id));
        }
        cursor.set_position(
            cursor
                .position()
                .checked_add(len)
                .ok_or_else(|| "payload offset overflow".to_string())?,
        );
        block_ranges.push((start, end));
    }
    if cursor.position() != (payload.len() - 4) as u64 {
        return Err("trailing bytes in PCR1 frame payload".into());
    }

    // The complete bounded frame, including all checksums and lengths, is valid now.
    for (start, end) in block_ranges {
        callback(&payload[start..end])?;
    }
    Ok(frame_info(name.to_owned(), &header, &file_info))
}

struct BoundedReader<R> {
    inner: R,
    remaining: usize,
}

impl<R: Read> Read for BoundedReader<R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        if self.remaining == 0 {
            let mut extra = [0u8; 1];
            return match self.inner.read(&mut extra)? {
                0 => Ok(0),
                _ => Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "decompressed frame exceeds size limit",
                )),
            };
        }
        let allowed = buffer.len().min(self.remaining);
        let count = self.inner.read(&mut buffer[..allowed])?;
        self.remaining -= count;
        Ok(count)
    }
}

fn frame_info(name: String, header: &FrameHeader, file_info: &FrameFileInfo) -> FrameInfo {
    FrameInfo {
        name,
        first: header.first_block,
        last: header.last_block,
        count: header.blocks.len() as u64,
        payload_bytes: header.payload_bytes,
        compressed_bytes: header.compressed_bytes,
        file_bytes: file_info.file_bytes,
        payload_sha256: header.payload_sha256.clone(),
        file_sha256: hex(&file_info.checksum),
    }
}

// Header-end offset, compressed length, trailer digest, and total file length.
fn read_frame_header(path: &Path) -> Result<(FrameHeader, FrameFileInfo)> {
    let mut file = open_existing_regular(path, false)?;
    let meta = file.metadata().map_err(io_error("stat frame"))?;
    let size = meta.len();
    let max_file = MAX_FRAME_COMPRESSED_BYTES + MAX_FRAME_HEADER_BYTES as u64 + 8 + 32;
    if size < 8 + 32 || size > max_file {
        return Err("frame file length outside supported bounds".into());
    }
    let mut prefix = [0u8; 8];
    file.read_exact(&mut prefix)
        .map_err(io_error("read frame prefix"))?;
    if &prefix[..4] != FRAME_MAGIC {
        return Err("invalid frame magic".into());
    }
    let header_len = u32::from_le_bytes(
        prefix[4..8]
            .try_into()
            .map_err(|_| "invalid frame header length".to_string())?,
    ) as usize;
    if header_len == 0 || header_len > MAX_FRAME_HEADER_BYTES || 8 + header_len as u64 + 32 > size {
        return Err("invalid frame header length".into());
    }
    let mut bytes = vec![0; header_len];
    file.read_exact(&mut bytes)
        .map_err(io_error("read frame metadata"))?;
    let header: FrameHeader =
        serde_json::from_slice(&bytes).map_err(|e| format!("invalid frame metadata: {e}"))?;
    validate_frame_header(&header)?;
    let payload_offset = 8usize
        .checked_add(header_len)
        .ok_or_else(|| "frame offset overflow".to_string())?;
    let compressed_bytes = header.compressed_bytes;
    let expected = payload_offset as u64 + compressed_bytes + 32;
    if expected != size {
        return Err("frame length does not match metadata".into());
    }
    file.seek(SeekFrom::Start(size - 32))
        .map_err(io_error("seek frame checksum"))?;
    let mut digest = [0u8; 32];
    file.read_exact(&mut digest)
        .map_err(io_error("read frame checksum"))?;
    Ok((
        header,
        FrameFileInfo {
            payload_offset,
            compressed_bytes,
            checksum: digest,
            file_bytes: size,
        },
    ))
}

fn validate_frame_header(header: &FrameHeader) -> Result<()> {
    if header.version != FRAME_VERSION
        || header.codec != "brotli"
        || header.quality != 5
        || header.window_log != 20
    {
        return Err("unsupported frame format or compression settings".into());
    }
    let range_count = header
        .last_block
        .checked_sub(header.first_block)
        .and_then(|count| count.checked_add(1));
    if header.blocks.is_empty()
        || header.blocks.len() > MAX_BLOCKS_PER_FRAME
        || range_count != Some(header.blocks.len() as u64)
        || header.payload_bytes == 0
        || header.payload_bytes > MAX_FRAME_RAW_BYTES as u64
        || header.compressed_bytes == 0
        || header.compressed_bytes > MAX_FRAME_COMPRESSED_BYTES
    {
        return Err("invalid frame range, count, or payload size".into());
    }
    let mut exact_payload_bytes = 4usize
        .checked_add(varint_len(header.blocks.len() as u64))
        .ok_or_else(|| "frame payload length overflow".to_string())?;
    for block in &header.blocks {
        if block.raw_bytes == 0 || block.raw_bytes > MAX_BLOCK_BYTES as u64 {
            return Err("invalid frame block size".into());
        }
        let raw_bytes = usize::try_from(block.raw_bytes)
            .map_err(|_| "frame block length does not fit memory")?;
        exact_payload_bytes = exact_payload_bytes
            .checked_add(varint_len(block.raw_bytes) + raw_bytes)
            .ok_or_else(|| "frame payload length overflow".to_string())?;
    }
    if exact_payload_bytes > MAX_FRAME_RAW_BYTES
        || exact_payload_bytes as u64 != header.payload_bytes
    {
        return Err("frame payload length does not match block references".into());
    }
    decode_hex_32(&header.payload_sha256)?;
    for (index, block) in header.blocks.iter().enumerate() {
        let expected_id = header.first_block.checked_add(index as u64);
        if expected_id != Some(block.id) {
            return Err("invalid frame block index".into());
        }
        decode_hex_32(&block.sha256)?;
    }
    Ok(())
}

fn verify_frame_digest(
    path: &Path,
    offset: usize,
    compressed_len: u64,
    expected: &[u8; 32],
) -> Result<()> {
    let mut file = open_existing_regular(path, false)?;
    let end = (offset as u64)
        .checked_add(compressed_len)
        .ok_or_else(|| "frame length overflow".to_string())?;
    file.seek(SeekFrom::Start(0))
        .map_err(io_error("seek frame checksum input"))?;
    let mut remaining = end;
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    while remaining != 0 {
        let want = remaining.min(buffer.len() as u64) as usize;
        let n = file
            .read(&mut buffer[..want])
            .map_err(io_error("read frame checksum input"))?;
        if n == 0 {
            return Err("truncated frame checksum input".into());
        }
        digest.update(&buffer[..n]);
        remaining -= n as u64;
    }
    let actual: [u8; 32] = digest.finalize().into();
    if &actual != expected {
        return Err("frame file checksum mismatch".into());
    }
    Ok(())
}

fn read_uvarint(reader: &mut impl Read) -> Result<u64> {
    let mut value = 0u64;
    let mut shift = 0u32;
    let mut encoded = [0u8; 10];
    for index in 0..10 {
        reader
            .read_exact(&mut encoded[index..=index])
            .map_err(io_error("read PCR1 integer"))?;
        let byte = encoded[index];
        if shift == 63 && byte > 1 {
            return Err("PCR1 integer overflow".into());
        }
        value |= u64::from(byte & 0x7f)
            .checked_shl(shift)
            .ok_or_else(|| "PCR1 integer overflow".to_string())?;
        if byte < 0x80 {
            if varint_len(value) != index + 1 {
                return Err("non-canonical PCR1 integer".into());
            }
            return Ok(value);
        }
        shift += 7;
    }
    Err("PCR1 integer is too long".into())
}

fn pack_pcr_frame(blocks: &[StoredBlock]) -> Result<Vec<u8>> {
    pack_pcr_payload(
        blocks.iter().map(|block| block.bytes.as_slice()),
        blocks.len(),
    )
}

fn pack_pcr_payload<'a>(
    blocks: impl IntoIterator<Item = &'a [u8]>,
    count: usize,
) -> Result<Vec<u8>> {
    if count == 0 || count > MAX_BLOCKS_PER_FRAME {
        return Err("frame block count outside supported bounds".into());
    }
    let mut output = Vec::new();
    output.extend_from_slice(PCR_MAGIC);
    write_uvarint(count as u64, &mut output);
    for block in blocks {
        if block.is_empty() || block.len() > MAX_BLOCK_BYTES {
            return Err("frame block length outside supported bounds".into());
        }
        let new_len = output
            .len()
            .checked_add(varint_len(block.len() as u64))
            .and_then(|len| len.checked_add(block.len()))
            .ok_or_else(|| "uncompressed frame size overflow".to_string())?;
        if new_len > MAX_FRAME_RAW_BYTES {
            return Err("uncompressed frame exceeds size limit".into());
        }
        write_uvarint(block.len() as u64, &mut output);
        output.extend_from_slice(block);
    }
    Ok(output)
}

fn journal_record(id: u64, block: &[u8], block_sha: &[u8; 32]) -> Vec<u8> {
    let mut record =
        Vec::with_capacity(JOURNAL_RECORD_PREFIX + block.len() + JOURNAL_RECORD_SUFFIX);
    record.extend_from_slice(&id.to_le_bytes());
    record.extend_from_slice(&(block.len() as u64).to_le_bytes());
    record.extend_from_slice(block_sha);
    record.extend_from_slice(block);
    let checksum: [u8; 32] = Sha256::digest(&record).into();
    record.extend_from_slice(&checksum);
    record
}

fn write_uvarint(mut value: u64, output: &mut Vec<u8>) {
    while value >= 0x80 {
        output.push((value as u8 & 0x7f) | 0x80);
        value >>= 7;
    }
    output.push(value as u8);
}
fn varint_len(mut value: u64) -> usize {
    let mut n = 1;
    while value >= 0x80 {
        n += 1;
        value >>= 7;
    }
    n
}

fn same_block_refs(a: &[BlockRef], b: &[BlockRef]) -> Result<bool> {
    if a.len() != b.len() {
        return Ok(false);
    }
    for (left, right) in a.iter().zip(b) {
        if left.id != right.id
            || left.raw_bytes != right.raw_bytes
            || decode_hex_32(&left.sha256)? != decode_hex_32(&right.sha256)?
        {
            return Ok(false);
        }
    }
    Ok(true)
}

fn validate_frame_sequence(frames: &[FrameInfo]) -> Result<()> {
    if frames.len() > MAX_ARCHIVE_FRAMES {
        return Err("archive has too many frames".into());
    }
    let mut expected = 0u64;
    for frame in frames {
        if frame.first != expected
            || frame.last < frame.first
            || frame.count != frame.last - frame.first + 1
        {
            return Err("immutable frame ranges overlap or contain a gap".into());
        }
        expected = frame
            .last
            .checked_add(1)
            .ok_or_else(|| "recording block id exhausted".to_string())?;
    }
    Ok(())
}

fn frame_filename(first: u64, last: u64) -> String {
    format!("frame-{first:020}-{last:020}.pcr")
}
fn parse_frame_filename(name: &str) -> Result<(u64, u64)> {
    let middle = name
        .strip_prefix("frame-")
        .and_then(|n| n.strip_suffix(".pcr"))
        .ok_or_else(|| format!("invalid frame filename: {name}"))?;
    let (a, b) = middle
        .split_once('-')
        .ok_or_else(|| format!("invalid frame filename: {name}"))?;
    if a.len() != 20
        || b.len() != 20
        || !a.bytes().all(|c| c.is_ascii_digit())
        || !b.bytes().all(|c| c.is_ascii_digit())
    {
        return Err(format!("invalid frame filename: {name}"));
    }
    Ok((
        a.parse().map_err(|_| "invalid frame start id")?,
        b.parse().map_err(|_| "invalid frame end id")?,
    ))
}

fn prepare_root(path: &Path) -> Result<PathBuf> {
    let name = path
        .file_name()
        .ok_or_else(|| "archive path must name a directory".to_string())?;
    if name == "." || name == ".." {
        return Err("invalid archive directory name".into());
    }
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let parent = fs::canonicalize(parent).map_err(io_error("resolve archive parent"))?;
    let root = parent.join(name);
    let created = match fs::symlink_metadata(&root) {
        Ok(meta) if meta.file_type().is_symlink() => {
            return Err("archive path must not be a symlink".into());
        }
        Ok(meta) if !meta.is_dir() => return Err("archive path is not a directory".into()),
        Ok(_) => false,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            ownership::create_private_directory(&root)
                .map_err(io_error("create archive directory"))?;
            sync_directory(&parent)?;
            true
        }
        Err(e) => return Err(format!("inspect archive path: {e}")),
    };
    let meta = fs::symlink_metadata(&root).map_err(io_error("inspect archive directory"))?;
    if !meta.is_dir() || meta.uid() != ownership::expected_uid() {
        return Err("archive directory is not owned by current user".into());
    }
    if !created && meta.permissions().mode() & 0o777 != 0o700 {
        ownership::make_existing_directory_private(&root)
            .map_err(io_error("make archive directory private"))?;
    }
    Ok(root)
}

fn existing_root(path: &Path) -> Result<PathBuf> {
    let meta = fs::symlink_metadata(path).map_err(io_error("inspect archive directory"))?;
    if meta.file_type().is_symlink() || !meta.is_dir() || meta.uid() != ownership::expected_uid() {
        return Err("archive path is not an owned, non-symlink directory".into());
    }
    if meta.permissions().mode() & 0o077 != 0 {
        return Err("archive directory is not private".into());
    }
    fs::canonicalize(path).map_err(io_error("resolve archive directory"))
}

fn acquire_lock(root: &Path) -> Result<File> {
    let path = root.join(LOCK_FILE);
    let mut opts = OpenOptions::new();
    opts.read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let (file, created) = match opts.open(&path) {
        Ok(file) => {
            if let Err(error) = ownership::chown_created_file(&file) {
                drop(file);
                let _ = fs::remove_file(&path);
                return Err(format!("set writer lock owner: {error}"));
            }
            (file, true)
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            opts.create_new(false);
            (
                opts.open(&path).map_err(io_error("open writer lock"))?,
                false,
            )
        }
        Err(error) => return Err(io_error("create writer lock")(error)),
    };
    let meta = file.metadata().map_err(io_error("stat writer lock"))?;
    if !meta.is_file() || meta.uid() != ownership::expected_uid() {
        return Err("writer lock is not an owned regular file".into());
    }
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(io_error("protect writer lock"))?;
    let status = unsafe {
        libc::flock(
            std::os::fd::AsRawFd::as_raw_fd(&file),
            libc::LOCK_EX | libc::LOCK_NB,
        )
    };
    if status != 0 {
        return Err("archive already has an active writer".into());
    }
    if created {
        sync_directory(root)?;
    }
    Ok(file)
}

fn read_metadata_if_exists(root: &Path) -> Result<Option<ArchiveMetadata>> {
    let path = root.join(ARCHIVE_FILE);
    match fs::symlink_metadata(&path) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("inspect archive metadata: {e}")),
        Ok(_) => {
            let bytes = read_private_file(&path, MAX_ARCHIVE_METADATA_BYTES)?;
            let metadata: ArchiveMetadata = serde_json::from_slice(&bytes)
                .map_err(|e| format!("invalid archive metadata: {e}"))?;
            Ok(Some(metadata))
        }
    }
}
fn read_metadata(root: &Path) -> Result<ArchiveMetadata> {
    let metadata =
        read_metadata_if_exists(root)?.ok_or_else(|| "archive metadata is missing".to_string())?;
    if metadata.version != ARCHIVE_VERSION || metadata.format != "pane-load-recording-archive" {
        return Err("unsupported recording archive metadata".into());
    }
    metadata.context.validate()?;
    Ok(metadata)
}

fn contains_recording_content(root: &Path) -> Result<bool> {
    for entry in fs::read_dir(root).map_err(io_error("list archive"))? {
        let name = entry.map_err(io_error("read archive entry"))?.file_name();
        if name != LOCK_FILE && name != MANIFEST_TEMP {
            return Ok(true);
        }
    }
    Ok(false)
}

fn read_private_file(path: &Path, max: usize) -> Result<Vec<u8>> {
    let mut file = open_existing_regular(path, false)?;
    let len = file
        .metadata()
        .map_err(io_error("stat private file"))?
        .len();
    if len > max as u64 {
        return Err("private metadata file exceeds size limit".into());
    }
    let mut bytes = Vec::with_capacity(len as usize);
    file.read_to_end(&mut bytes)
        .map_err(io_error("read private file"))?;
    Ok(bytes)
}

fn open_existing_regular(path: &Path, write: bool) -> Result<File> {
    let mut opts = OpenOptions::new();
    opts.read(true)
        .write(write)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let file = opts.open(path).map_err(io_error("open regular file"))?;
    let meta = file.metadata().map_err(io_error("stat regular file"))?;
    if !meta.is_file() || meta.uid() != ownership::expected_uid() {
        return Err(format!(
            "unsafe or unowned regular file: {}",
            path.display()
        ));
    }
    if meta.permissions().mode() & 0o777 != 0o600 {
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(io_error("protect file"))?;
    }
    Ok(file)
}

fn create_private_new(path: &Path) -> Result<File> {
    let mut opts = OpenOptions::new();
    opts.write(true)
        .read(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let file = opts.open(path).map_err(io_error("create private file"))?;
    if let Err(error) = ownership::chown_created_file(&file) {
        drop(file);
        let _ = fs::remove_file(path);
        return Err(format!("set private file owner: {error}"));
    }
    Ok(file)
}

fn atomic_write_new(
    root: &Path,
    target: &str,
    temp: &str,
    bytes: &[u8],
    options: StoreOptions,
) -> Result<()> {
    ensure_capacity(root, options, bytes.len() as u64)?;
    let path = root.join(temp);
    let mut file = create_private_new(&path)?;
    file.write_all(bytes)
        .map_err(io_error("write private metadata"))?;
    file.sync_all().map_err(io_error("sync private metadata"))?;
    let target_path = root.join(target);
    if fs::symlink_metadata(&target_path).is_ok() {
        remove_owned_regular(root, temp)?;
        return Err(format!("refusing to replace immutable {target}"));
    }
    fs::rename(&path, &target_path).map_err(io_error("publish private metadata"))?;
    sync_directory(root)
}

fn atomic_replace(
    root: &Path,
    target: &str,
    temp: &str,
    bytes: &[u8],
    options: StoreOptions,
    usage_bytes: &mut u64,
) -> Result<()> {
    remove_owned_temp(root, temp)?;
    ensure_capacity_at(root, options, *usage_bytes, bytes.len() as u64)?;
    let path = root.join(temp);
    let mut file = create_private_new(&path)?;
    file.write_all(bytes)
        .map_err(io_error("write archive manifest"))?;
    file.sync_all().map_err(io_error("sync archive manifest"))?;
    let target_path = root.join(target);
    let old_bytes = match fs::symlink_metadata(&target_path) {
        Ok(metadata) => metadata.len(),
        Err(error) if error.kind() == io::ErrorKind::NotFound => 0,
        Err(error) => return Err(format!("inspect old archive manifest: {error}")),
    };
    fs::rename(&path, &target_path).map_err(io_error("publish archive manifest"))?;
    *usage_bytes = usage_bytes
        .checked_sub(old_bytes)
        .and_then(|used| used.checked_add(bytes.len() as u64))
        .ok_or_else(|| "archive size accounting underflow or overflow".to_string())?;
    sync_directory(root)
}

fn cleanup_frame_temps(root: &Path) -> Result<()> {
    for entry in fs::read_dir(root).map_err(io_error("list archive temporary files"))? {
        let entry = entry.map_err(io_error("read archive temporary entry"))?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        if name.starts_with("frame-") && name.ends_with(".tmp") {
            let frame_name = name
                .strip_suffix(".tmp")
                .ok_or_else(|| "invalid frame temporary name".to_string())?;
            parse_frame_filename(frame_name)?;
            let meta = fs::symlink_metadata(entry.path())
                .map_err(io_error("inspect frame temporary file"))?;
            if meta.file_type().is_symlink()
                || !meta.is_file()
                || meta.uid() != ownership::expected_uid()
            {
                return Err(format!("unsafe frame temporary file: {name}"));
            }
            fs::remove_file(entry.path()).map_err(io_error("remove stale frame temporary file"))?;
        }
    }
    Ok(())
}

fn remove_owned_temp(root: &Path, name: &str) -> Result<()> {
    let path = root.join(name);
    match fs::symlink_metadata(&path) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("inspect temporary file: {e}")),
        Ok(meta) => {
            if meta.file_type().is_symlink()
                || !meta.is_file()
                || meta.uid() != ownership::expected_uid()
            {
                return Err(format!("unsafe temporary file: {name}"));
            }
            fs::remove_file(path).map_err(io_error("remove stale temporary file"))
        }
    }
}
fn remove_owned_regular(root: &Path, name: &str) -> Result<()> {
    let path = root.join(name);
    let meta = fs::symlink_metadata(&path).map_err(io_error("inspect file to remove"))?;
    if meta.file_type().is_symlink() || !meta.is_file() || meta.uid() != ownership::expected_uid() {
        return Err(format!("refusing to remove unsafe file: {name}"));
    }
    fs::remove_file(path).map_err(io_error("remove file"))
}

fn ensure_capacity(root: &Path, options: StoreOptions, additional: u64) -> Result<()> {
    ensure_capacity_at(root, options, directory_bytes(root)?, additional)
}
fn ensure_capacity_at(
    root: &Path,
    options: StoreOptions,
    used: u64,
    additional: u64,
) -> Result<()> {
    let projected = used
        .checked_add(additional)
        .ok_or_else(|| "archive size overflow".to_string())?;
    if projected > options.max_bytes {
        return Err("recording store byte limit reached".into());
    }
    let free = free_bytes(root)?;
    let required = additional
        .checked_add(options.min_free_bytes)
        .ok_or_else(|| "free-space limit overflow".to_string())?;
    if free < required {
        return Err("recording store free-space reserve reached".into());
    }
    Ok(())
}
fn directory_bytes(root: &Path) -> Result<u64> {
    let mut total = 0u64;
    for entry in fs::read_dir(root).map_err(io_error("measure archive"))? {
        let entry = entry.map_err(io_error("measure archive entry"))?;
        let meta = fs::symlink_metadata(entry.path()).map_err(io_error("stat archive entry"))?;
        if meta.file_type().is_symlink()
            || !meta.is_file()
            || meta.uid() != ownership::expected_uid()
        {
            return Err("unsafe archive entry while accounting storage".into());
        }
        total = total
            .checked_add(meta.len())
            .ok_or_else(|| "archive size overflow".to_string())?;
    }
    Ok(total)
}
fn free_bytes(root: &Path) -> Result<u64> {
    let path = CString::new(root.as_os_str().as_encoded_bytes())
        .map_err(|_| "archive path contains NUL")?;
    let mut stat = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    if unsafe { libc::statvfs(path.as_ptr(), stat.as_mut_ptr()) } != 0 {
        return Err(format!("statvfs archive: {}", io::Error::last_os_error()));
    }
    let stat = unsafe { stat.assume_init() };
    let unit = if stat.f_frsize == 0 {
        stat.f_bsize
    } else {
        stat.f_frsize
    };
    Ok(u64::from(stat.f_bavail).saturating_mul(unit))
}

#[cfg(target_os = "linux")]
fn rename_noreplace(from: &Path, to: &Path) -> io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let from = CString::new(from.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "source path contains NUL"))?;
    let to = CString::new(to.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "target path contains NUL"))?;
    let result = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            from.as_ptr(),
            libc::AT_FDCWD,
            to.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(target_os = "macos")]
fn rename_noreplace(from: &Path, to: &Path) -> io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let from = CString::new(from.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "source path contains NUL"))?;
    let to = CString::new(to.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "target path contains NUL"))?;
    let result = unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn rename_noreplace(from: &Path, to: &Path) -> io::Result<()> {
    fs::hard_link(from, to)?;
    fs::remove_file(from)
}

fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(io_error("sync archive directory"))
}
fn read_partial(reader: &mut impl Read, buffer: &mut [u8]) -> io::Result<usize> {
    let mut read = 0;
    while read < buffer.len() {
        match reader.read(&mut buffer[read..])? {
            0 => break,
            n => read += n,
        }
    }
    Ok(read)
}
fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(DIGITS[(byte >> 4) as usize] as char);
        out.push(DIGITS[(byte & 15) as usize] as char);
    }
    out
}
fn decode_hex_32(text: &str) -> Result<[u8; 32]> {
    if text.len() != 64 {
        return Err("invalid SHA-256 text length".into());
    }
    let mut output = [0u8; 32];
    for (index, pair) in text.as_bytes().chunks_exact(2).enumerate() {
        let high = hex_nibble(pair[0]).ok_or_else(|| "invalid SHA-256 text".to_string())?;
        let low = hex_nibble(pair[1]).ok_or_else(|| "invalid SHA-256 text".to_string())?;
        output[index] = (high << 4) | low;
    }
    Ok(output)
}
fn hex_nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        _ => None,
    }
}
fn io_error(context: &'static str) -> impl FnOnce(io::Error) -> String {
    move |e| format!("{context}: {e}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "pane-load-store-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn archive(&self) -> PathBuf {
            self.0.join("archive")
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn context() -> Context {
        Context::new(super::super::Timebase {
            numer: 125,
            denom: 3,
        })
    }
    fn options(frame_bytes: usize) -> StoreOptions {
        StoreOptions {
            frame_bytes,
            max_bytes: 16 * 1024 * 1024,
            min_free_bytes: 0,
        }
    }
    fn frame_paths(path: &Path) -> Vec<PathBuf> {
        let mut frames: Vec<_> = fs::read_dir(path)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| path.extension().is_some_and(|extension| extension == "pcr"))
            .collect();
        frames.sort();
        frames
    }
    fn rewrite_frame_header(path: &Path, mutate: impl FnOnce(&mut serde_json::Value)) {
        rewrite_frame(path, |header, _| mutate(header));
    }
    fn rewrite_frame(path: &Path, mutate: impl FnOnce(&mut serde_json::Value, &mut Vec<u8>)) {
        let bytes = fs::read(path).unwrap();
        let header_len = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;
        let mut header: serde_json::Value =
            serde_json::from_slice(&bytes[8..8 + header_len]).unwrap();
        let mut compressed = bytes[8 + header_len..bytes.len() - 32].to_vec();
        mutate(&mut header, &mut compressed);
        header["compressed_bytes"] = serde_json::json!(compressed.len());
        let header = serde_json::to_vec(&header).unwrap();
        let mut rewritten = Vec::new();
        rewritten.extend_from_slice(FRAME_MAGIC);
        rewritten.extend_from_slice(&(header.len() as u32).to_le_bytes());
        rewritten.extend_from_slice(&header);
        rewritten.extend_from_slice(&compressed);
        let checksum: [u8; 32] = Sha256::digest(&rewritten).into();
        rewritten.extend_from_slice(&checksum);
        fs::write(path, rewritten).unwrap();
    }

    #[test]
    fn round_trips_multiple_frames_and_a_final_tail() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(15)).unwrap();
        let expected = vec![
            b"arbitrary PST bytes one".to_vec(),
            b"PST1\x00two".to_vec(),
            b"tail".to_vec(),
        ];
        for block in &expected {
            writer.append(block).unwrap();
        }
        writer.finish().unwrap();
        assert_eq!(read_archive(&path).unwrap(), expected);
        let mut streamed = Vec::new();
        visit_blocks(&path, |block| {
            streamed.push(block.to_vec());
            Ok(())
        })
        .unwrap();
        assert_eq!(streamed, expected);
        let frames = scan_frames(&existing_root(&path).unwrap()).unwrap();
        assert!(frames.len() >= 2);
    }

    #[test]
    fn writer_lock_is_exclusive_and_released_on_drop() {
        let temp = Temp::new();
        let path = temp.archive();
        let writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(100)).unwrap();
        assert!(ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(100)).is_err());
        drop(writer);
        ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(100))
            .unwrap()
            .finish()
            .unwrap();
    }

    #[test]
    fn archive_and_files_are_private() {
        use std::os::unix::fs::PermissionsExt;
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(100)).unwrap();
        writer.append(b"opaque").unwrap();
        writer.finish().unwrap();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o700
        );
        for entry in fs::read_dir(path).unwrap() {
            assert_eq!(
                entry.unwrap().metadata().unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn detects_corrupt_immutable_frame() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(100)).unwrap();
        writer.append(b"opaque payload").unwrap();
        writer.finish().unwrap();
        let frame = fs::read_dir(&path)
            .unwrap()
            .map(|e| e.unwrap().path())
            .find(|p| p.extension().is_some_and(|e| e == "pcr"))
            .unwrap();
        let mut bytes = fs::read(&frame).unwrap();
        let middle = bytes.len() / 2;
        bytes[middle] ^= 0x20;
        fs::write(frame, bytes).unwrap();
        assert!(visit_blocks(&path, |_| Ok(())).is_err());
    }

    #[test]
    fn torn_journal_recovers_verified_prefix_and_reports_tail() {
        let temp = Temp::new();
        let path = temp.archive();
        let block = b"durable block before torn suffix";
        let writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(1000)).unwrap();
        let mut writer = writer;
        writer.append(block).unwrap();
        drop(writer);
        OpenOptions::new()
            .append(true)
            .open(path.join(JOURNAL_FILE))
            .unwrap()
            .write_all(&[0x55, 0x66, 0x77])
            .unwrap();
        let writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(1000)).unwrap();
        assert!(
            writer
                .recovery_report()
                .iter()
                .any(|line| line.contains("invalid trailing journal suffix"))
        );
        drop(writer);
        assert_eq!(read_archive(&path).unwrap(), vec![block.to_vec()]);
    }

    #[test]
    fn journal_duplicate_of_published_frame_is_deduplicated() {
        let temp = Temp::new();
        let path = temp.archive();
        let block = b"already committed";
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(1)).unwrap();
        writer.append(block).unwrap(); // threshold publishes immediately
        drop(writer);
        let sha: [u8; 32] = Sha256::digest(block).into();
        let mut journal = JOURNAL_MAGIC.to_vec();
        journal.extend_from_slice(&journal_record(0, block, &sha));
        fs::write(path.join(JOURNAL_FILE), journal).unwrap();
        let writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(100)).unwrap();
        drop(writer);
        assert!(!path.join(JOURNAL_FILE).exists());
        assert_eq!(read_archive(&path).unwrap(), vec![block.to_vec()]);
    }

    #[test]
    fn rejects_symlink_store_unsupported_metadata_and_oversized_blocks() {
        let temp = Temp::new();
        let link = temp.0.join("link");
        std::os::unix::fs::symlink(temp.archive(), &link).unwrap();
        assert!(ArchiveWriter::open(&link, &context(), Profile::Adaptive, options(100)).is_err());

        let path = temp.archive();
        let writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(100)).unwrap();
        drop(writer);
        let meta_path = path.join(ARCHIVE_FILE);
        let mut metadata: serde_json::Value =
            serde_json::from_slice(&fs::read(&meta_path).unwrap()).unwrap();
        metadata["version"] = serde_json::json!(999);
        fs::write(&meta_path, serde_json::to_vec(&metadata).unwrap()).unwrap();
        assert!(ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(100)).is_err());

        let fresh = temp.0.join("fresh");
        let mut writer =
            ArchiveWriter::open(&fresh, &context(), Profile::Adaptive, options(100)).unwrap();
        assert!(writer.append(&vec![0; MAX_BLOCK_BYTES + 1]).is_err());
    }

    #[test]
    fn never_overwrites_conflicting_immutable_frame() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(100)).unwrap();
        writer.append(b"pending block").unwrap();
        let conflict = path.join(frame_filename(0, 0));
        fs::write(&conflict, b"conflicting immutable content").unwrap();
        let before = fs::read(&conflict).unwrap();
        assert!(writer.finish().is_err());
        assert_eq!(fs::read(conflict).unwrap(), before);
    }

    #[test]
    fn rejects_malicious_frame_header_length_before_allocation() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(100)).unwrap();
        writer.append(b"opaque payload").unwrap();
        writer.finish().unwrap();
        let frame = fs::read_dir(&path)
            .unwrap()
            .map(|e| e.unwrap().path())
            .find(|p| p.extension().is_some_and(|e| e == "pcr"))
            .unwrap();
        let mut bytes = fs::read(&frame).unwrap();
        bytes[4..8].copy_from_slice(&u32::MAX.to_le_bytes());
        fs::write(frame, bytes).unwrap();
        assert!(visit_blocks(&path, |_| Ok(())).is_err());
    }

    #[test]
    fn finish_commits_caller_flushed_sigterm_equivalent_tail() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(1024)).unwrap();
        writer.append(b"current encoding block").unwrap();
        writer.flush_frame().unwrap(); // same durable action a SIGTERM caller performs
        writer.finish().unwrap();
        assert_eq!(
            read_archive(&path).unwrap(),
            vec![b"current encoding block".to_vec()]
        );
    }

    #[test]
    fn enforces_store_bytes_before_journal_write() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(1000)).unwrap();
        writer.options.max_bytes = directory_bytes(&path).unwrap() + 16;
        assert!(
            writer
                .append(b"this record cannot fit in the configured store")
                .is_err()
        );
        assert!(!path.join(JOURNAL_FILE).exists());
    }

    #[test]
    fn frame_publication_counts_journal_and_new_frame_peak_before_writing() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(4096)).unwrap();
        writer.append(b"near-cap frame payload").unwrap();
        let used_with_journal = directory_bytes(&path).unwrap();
        writer.options.max_bytes = used_with_journal + 1;
        assert!(writer.flush_frame().unwrap_err().contains("byte limit"));
        assert!(directory_bytes(&path).unwrap() <= writer.options.max_bytes);
        assert!(path.join(JOURNAL_FILE).is_file());
        assert!(
            !frame_paths(&path)
                .iter()
                .any(|frame| { fs::metadata(frame).is_ok_and(|meta| meta.len() > 0) })
        );
    }

    #[test]
    fn journal_appends_survive_drop_without_finish() {
        let temp = Temp::new();
        let path = temp.archive();
        let expected = vec![
            b"first subthreshold block".to_vec(),
            b"second block".to_vec(),
        ];
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(4096)).unwrap();
        for block in &expected {
            writer.append(block).unwrap();
        }
        drop(writer);
        let reopened =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(4096)).unwrap();
        drop(reopened);
        assert_eq!(read_archive(&path).unwrap(), expected);
    }

    #[test]
    fn storage_error_poison_guard_rejects_later_appends() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(4096)).unwrap();
        writer
            .append(b"durably journaled before publish failure")
            .unwrap();
        writer.options.max_bytes = directory_bytes(&path).unwrap() + 1;
        assert!(writer.flush_frame().is_err());
        let error = writer.append(b"must not be accepted").unwrap_err();
        assert!(error.contains("unusable after a storage error"), "{error}");
    }

    #[test]
    fn callbacks_wait_for_frame_checksum_and_payload_validation() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(4096)).unwrap();
        writer.append(b"opaque callback payload").unwrap();
        writer.finish().unwrap();
        let frame = frame_paths(&path).remove(0);

        let mut bytes = fs::read(&frame).unwrap();
        let last = bytes.len() - 1;
        bytes[last] ^= 0x80;
        fs::write(&frame, bytes).unwrap();
        let mut callbacks = 0;
        assert!(
            visit_blocks(&path, |_| {
                callbacks += 1;
                Ok(())
            })
            .is_err()
        );
        assert_eq!(callbacks, 0);
    }

    #[test]
    fn malformed_frame_name_is_rejected_before_any_callback() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(4096)).unwrap();
        writer.append(b"opaque callback payload").unwrap();
        writer.finish().unwrap();
        let frame = frame_paths(&path).remove(0);
        fs::rename(&frame, path.join("not-a-frame-name.pcr")).unwrap();
        let mut callbacks = 0;
        assert!(
            visit_blocks(&path, |_| {
                callbacks += 1;
                Ok(())
            })
            .is_err()
        );
        assert_eq!(callbacks, 0);
    }

    #[test]
    fn malformed_payload_length_is_rejected_before_any_callback() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(4096)).unwrap();
        writer.append(b"opaque callback payload").unwrap();
        writer.finish().unwrap();
        let frame = frame_paths(&path).remove(0);
        rewrite_frame_header(&frame, |header| {
            let length = header["payload_bytes"].as_u64().unwrap();
            header["payload_bytes"] = serde_json::json!(length + 1);
        });
        let mut callbacks = 0;
        assert!(
            visit_blocks(&path, |_| {
                callbacks += 1;
                Ok(())
            })
            .is_err()
        );
        assert_eq!(callbacks, 0);
    }

    #[test]
    fn payload_and_block_hashes_are_verified_before_any_callback() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(4096)).unwrap();
        writer.append(b"first block").unwrap();
        writer.append(b"second block").unwrap();
        writer.finish().unwrap();
        let frame = frame_paths(&path).remove(0);

        rewrite_frame_header(&frame, |header| {
            header["blocks"][1]["sha256"] = serde_json::json!("00".repeat(32));
        });
        let mut callbacks = 0;
        assert!(
            visit_blocks(&path, |_| {
                callbacks += 1;
                Ok(())
            })
            .is_err()
        );
        assert_eq!(callbacks, 0);

        // Re-create a valid archive and corrupt only the payload digest in its header.
        let path = temp.0.join("payload-hash-archive");
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(4096)).unwrap();
        writer.append(b"one block").unwrap();
        writer.finish().unwrap();
        let frame = frame_paths(&path).remove(0);
        rewrite_frame_header(&frame, |header| {
            header["payload_sha256"] = serde_json::json!("00".repeat(32));
        });
        let mut callbacks = 0;
        assert!(
            visit_blocks(&path, |_| {
                callbacks += 1;
                Ok(())
            })
            .is_err()
        );
        assert_eq!(callbacks, 0);
    }

    #[test]
    fn truncated_and_trailing_brotli_data_are_rejected_before_callbacks() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(4096)).unwrap();
        writer
            .append(b"payload for compressed stream checks")
            .unwrap();
        writer.finish().unwrap();
        let frame = frame_paths(&path).remove(0);

        rewrite_frame(&frame, |_, compressed| {
            compressed.pop();
        });
        let mut callbacks = 0;
        assert!(
            visit_blocks(&path, |_| {
                callbacks += 1;
                Ok(())
            })
            .is_err()
        );
        assert_eq!(callbacks, 0);

        let path = temp.0.join("trailing-brotli-archive");
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(4096)).unwrap();
        writer
            .append(b"payload for trailing compressed data")
            .unwrap();
        writer.finish().unwrap();
        let frame = frame_paths(&path).remove(0);
        rewrite_frame(&frame, |_, compressed| {
            compressed.extend_from_slice(&[0xde, 0xad, 0xbe, 0xef]);
        });
        let mut callbacks = 0;
        assert!(
            visit_blocks(&path, |_| {
                callbacks += 1;
                Ok(())
            })
            .is_err()
        );
        assert_eq!(callbacks, 0);
    }

    #[test]
    fn bounded_reader_never_exposes_bytes_after_its_limit() {
        let mut reader = BoundedReader {
            inner: io::Cursor::new(b"123456".to_vec()),
            remaining: 4,
        };
        let mut decoded = Vec::new();
        assert!(reader.read_to_end(&mut decoded).is_err());
        assert_eq!(decoded, b"1234");
    }

    #[test]
    fn frame_catalog_limit_is_checked_before_immutable_publication() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(4096)).unwrap();
        writer.frames = (0..MAX_ARCHIVE_FRAMES as u64)
            .map(|id| FrameInfo {
                name: frame_filename(id, id),
                first: id,
                last: id,
                count: 1,
                payload_bytes: 5,
                compressed_bytes: 1,
                file_bytes: 64,
                payload_sha256: "00".repeat(32),
                file_sha256: "00".repeat(32),
            })
            .collect();
        assert!(writer.append(b"must not journal at catalog limit").is_err());
        assert!(!path.join(JOURNAL_FILE).exists());
        let block = StoredBlock {
            id: MAX_ARCHIVE_FRAMES as u64,
            bytes: b"new".to_vec(),
            sha256: Sha256::digest(b"new").into(),
        };
        assert!(writer.publish_blocks(&[block], false).is_err());
        assert!(
            !path
                .join(frame_filename(
                    MAX_ARCHIVE_FRAMES as u64,
                    MAX_ARCHIVE_FRAMES as u64
                ))
                .exists()
        );
    }

    #[test]
    fn later_frame_sequence_is_validated_before_callbacks() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(1)).unwrap();
        writer.append(b"first").unwrap();
        writer.append(b"second").unwrap();
        writer.finish().unwrap();
        let frames = frame_paths(&path);
        assert_eq!(frames.len(), 2);
        rewrite_frame_header(&frames[1], |header| {
            header["first_block"] = serde_json::json!(2);
            header["last_block"] = serde_json::json!(2);
            header["blocks"][0]["id"] = serde_json::json!(2);
        });
        fs::rename(&frames[1], path.join(frame_filename(2, 2))).unwrap();
        let mut callbacks = 0;
        assert!(
            visit_blocks(&path, |_| {
                callbacks += 1;
                Ok(())
            })
            .is_err()
        );
        assert_eq!(callbacks, 0);
    }

    #[test]
    fn manifest_limit_rejects_new_journal_tail_before_acceptance() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(4096)).unwrap();
        writer.options.max_bytes = u64::MAX;
        writer.next_id = (MAX_MANIFEST_BYTES / MAX_MANIFEST_ENTRY_BYTES) as u64;
        writer.frames = (0..writer.next_id)
            .map(|id| FrameInfo {
                name: frame_filename(id, id),
                first: id,
                last: id,
                count: 1,
                payload_bytes: 1,
                compressed_bytes: 1,
                file_bytes: 1,
                payload_sha256: "00".repeat(32),
                file_sha256: "00".repeat(32),
            })
            .collect();
        writer.frames[0].name = "x".repeat(MAX_MANIFEST_BYTES);
        let manifest = OpenOptions::new()
            .write(true)
            .open(path.join(MANIFEST_FILE))
            .unwrap();
        manifest.set_len((MAX_MANIFEST_BYTES - 1) as u64).unwrap();

        assert!(writer.append(b"must remain unjournaled").is_err());
        assert!(!path.join(JOURNAL_FILE).exists());
    }

    #[test]
    fn archive_metadata_size_is_limited_before_publication() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut context = context();
        context.source_headers = vec![serde_json::Value::String(
            "x".repeat(MAX_ARCHIVE_METADATA_BYTES + 1),
        )];
        assert!(ArchiveWriter::open(&path, &context, Profile::Adaptive, options(4096)).is_err());
        assert!(!path.join(ARCHIVE_FILE).exists());
    }

    #[test]
    fn benchmark_frame_reports_verified_three_repeat_encoder_medians() {
        let blocks = vec![b"first opaque block".to_vec(), b"another block".to_vec()];
        let benchmark = benchmark_frame(&blocks).unwrap();
        let expected_input = pack_pcr_payload(blocks.iter().map(Vec::as_slice), blocks.len())
            .unwrap()
            .len() as u64;
        assert_eq!(benchmark.input_bytes, expected_input);
        assert!(benchmark.compressed_bytes > 0);
        assert_eq!(benchmark.repeats, 3);
        assert!(benchmark.encoder_cpu_seconds.is_finite());
        assert!(benchmark.encoder_wall_seconds.is_finite());
    }

    #[test]
    fn enforces_free_space_reserve_before_journal_write() {
        let temp = Temp::new();
        let path = temp.archive();
        let mut writer =
            ArchiveWriter::open(&path, &context(), Profile::Adaptive, options(1000)).unwrap();
        writer.options.min_free_bytes = u64::MAX;
        assert!(writer.append(b"reserve cannot be maintained").is_err());
        assert!(!path.join(JOURNAL_FILE).exists());
    }
}
