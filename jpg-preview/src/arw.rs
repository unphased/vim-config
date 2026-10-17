use std::io::{self, Read, Seek, SeekFrom};

use image::metadata::Orientation;

pub const MAX_ENCODED_BYTES: u64 = 128 * 1024 * 1024;
const MAX_IFD_BYTES: u64 = 1024 * 1024;

pub struct ExtractedJpeg {
    pub bytes: Vec<u8>,
    pub orientation: Option<Orientation>,
}

#[derive(Clone, Copy)]
enum Endian {
    Little,
    Big,
}

impl Endian {
    fn u16(self, bytes: [u8; 2]) -> u16 {
        match self {
            Self::Little => u16::from_le_bytes(bytes),
            Self::Big => u16::from_be_bytes(bytes),
        }
    }

    fn u32(self, bytes: [u8; 4]) -> u32 {
        match self {
            Self::Little => u32::from_le_bytes(bytes),
            Self::Big => u32::from_be_bytes(bytes),
        }
    }
}

fn invalid_data(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn checked_range(offset: u64, length: u64, file_size: u64) -> io::Result<u64> {
    let end = offset
        .checked_add(length)
        .ok_or_else(|| invalid_data("ARW TIFF offset overflow"))?;
    if end > file_size {
        return Err(invalid_data("ARW TIFF data extends beyond end of file"));
    }
    Ok(end)
}

/// Extracts the embedded JPEG and optional valid EXIF orientation from classic TIFF IFD0.
pub fn extract<R: Read + Seek>(input: &mut R) -> io::Result<ExtractedJpeg> {
    let file_size = input.seek(SeekFrom::End(0))?;
    input.seek(SeekFrom::Start(0))?;

    let mut header = [0; 8];
    input.read_exact(&mut header)?;
    let endian = match &header[..2] {
        b"II" => Endian::Little,
        b"MM" => Endian::Big,
        _ => return Err(invalid_data("invalid ARW TIFF byte order")),
    };
    if endian.u16([header[2], header[3]]) != 42 {
        return Err(invalid_data("unsupported ARW TIFF magic"));
    }

    let ifd_offset = u64::from(endian.u32([header[4], header[5], header[6], header[7]]));
    checked_range(ifd_offset, 2, file_size)?;
    input.seek(SeekFrom::Start(ifd_offset))?;
    let mut count_bytes = [0; 2];
    input.read_exact(&mut count_bytes)?;
    let entry_count = u64::from(endian.u16(count_bytes));
    let ifd_bytes = 2 + entry_count * 12 + 4;
    if ifd_bytes > MAX_IFD_BYTES {
        return Err(invalid_data("ARW TIFF IFD exceeds size limit"));
    }
    checked_range(ifd_offset, ifd_bytes, file_size)?;

    let mut jpeg_offset = None;
    let mut jpeg_length = None;
    let mut orientation = None;
    let mut orientation_seen = false;
    let mut entry = [0; 12];
    for _ in 0..entry_count {
        input.read_exact(&mut entry)?;
        let tag = endian.u16([entry[0], entry[1]]);
        let kind = endian.u16([entry[2], entry[3]]);
        let count = endian.u32([entry[4], entry[5], entry[6], entry[7]]);
        let value = [entry[8], entry[9], entry[10], entry[11]];
        match tag {
            0x0201 | 0x0202 => {
                if kind != 4 || count != 1 {
                    return Err(invalid_data("invalid ARW embedded JPEG tag"));
                }
                let value = u64::from(endian.u32(value));
                let target = if tag == 0x0201 {
                    &mut jpeg_offset
                } else {
                    &mut jpeg_length
                };
                if target.replace(value).is_some() {
                    return Err(invalid_data("duplicate ARW embedded JPEG tag"));
                }
            }
            0x0112 => {
                if kind != 3 || count != 1 || orientation_seen {
                    return Err(invalid_data("invalid ARW orientation tag"));
                }
                orientation_seen = true;
                let exif = endian.u16([value[0], value[1]]);
                if let Ok(exif) = u8::try_from(exif) {
                    orientation = Orientation::from_exif(exif);
                }
            }
            _ => {}
        }
    }

    let offset = jpeg_offset.ok_or_else(|| invalid_data("ARW embedded JPEG offset is missing"))?;
    let length = jpeg_length.ok_or_else(|| invalid_data("ARW embedded JPEG length is missing"))?;
    if length == 0 {
        return Err(invalid_data("ARW embedded JPEG is empty"));
    }
    if length > MAX_ENCODED_BYTES {
        return Err(invalid_data("ARW embedded JPEG exceeds input size limit"));
    }
    checked_range(offset, length, file_size)?;

    let capacity = usize::try_from(length).map_err(|_| invalid_data("ARW JPEG is too large"))?;
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(capacity)
        .map_err(|_| io::Error::other("unable to allocate ARW embedded JPEG"))?;
    bytes.resize(capacity, 0);
    input.seek(SeekFrom::Start(offset))?;
    input.read_exact(&mut bytes)?;
    if !bytes.starts_with(&[0xff, 0xd8]) {
        return Err(invalid_data(
            "ARW payload does not start with a JPEG marker",
        ));
    }
    Ok(ExtractedJpeg { bytes, orientation })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[derive(Clone, Copy)]
    enum ByteOrder {
        Little,
        Big,
    }

    impl ByteOrder {
        fn u16(self, value: u16) -> [u8; 2] {
            match self {
                Self::Little => value.to_le_bytes(),
                Self::Big => value.to_be_bytes(),
            }
        }

        fn u32(self, value: u32) -> [u8; 4] {
            match self {
                Self::Little => value.to_le_bytes(),
                Self::Big => value.to_be_bytes(),
            }
        }

        fn bytes(self) -> [u8; 2] {
            match self {
                Self::Little => *b"II",
                Self::Big => *b"MM",
            }
        }
    }

    fn tiff(
        order: ByteOrder,
        orientation: Option<u16>,
        jpeg_offset: u32,
        jpeg_length: u32,
    ) -> Vec<u8> {
        let ifd_offset = 37usize;
        let jpeg = b"\xff\xd8embedded jpeg\xff\xd9";
        let mut data = vec![0; ifd_offset];
        data[..2].copy_from_slice(&order.bytes());
        data[2..4].copy_from_slice(&order.u16(42));
        data[4..8].copy_from_slice(&order.u32(ifd_offset as u32));
        let mut entries = vec![
            (0x0100, 4, 1, 123),
            (0x0201, 4, 1, jpeg_offset),
            (0x0202, 4, 1, jpeg_length),
        ];
        if let Some(value) = orientation {
            entries.push((0x0112, 3, 1, u32::from(value)));
        }
        data.extend_from_slice(&order.u16(entries.len() as u16));
        for (tag, kind, count, value) in entries {
            data.extend_from_slice(&order.u16(tag));
            data.extend_from_slice(&order.u16(kind));
            data.extend_from_slice(&order.u32(count));
            if kind == 3 {
                data.extend_from_slice(&order.u16(value as u16));
                data.extend_from_slice(&[0, 0]);
            } else {
                data.extend_from_slice(&order.u32(value));
            }
        }
        data.extend_from_slice(&[0; 4]);
        data.resize(jpeg_offset as usize, 0);
        data.extend_from_slice(jpeg);
        data
    }

    #[test]
    fn extracts_embedded_jpeg_from_both_endian_tiffs_and_nondefault_ifd_offsets() {
        let jpeg = b"\xff\xd8embedded jpeg\xff\xd9";
        for order in [ByteOrder::Little, ByteOrder::Big] {
            let bytes = tiff(order, Some(6), 100, jpeg.len() as u32);
            let extracted = extract(&mut Cursor::new(bytes)).unwrap();
            assert_eq!(extracted.bytes, jpeg);
            assert_eq!(extracted.orientation, Some(Orientation::Rotate90));
        }
    }

    #[test]
    fn invalid_orientation_is_ignored_but_required_tag_errors_fail() {
        let jpeg = b"\xff\xd8embedded jpeg\xff\xd9";
        let bytes = tiff(ByteOrder::Little, Some(9), 100, jpeg.len() as u32);
        assert_eq!(extract(&mut Cursor::new(bytes)).unwrap().orientation, None);

        let mut missing = tiff(ByteOrder::Little, None, 100, jpeg.len() as u32);
        missing[ifd_offset()..ifd_offset() + 2].copy_from_slice(&2u16.to_le_bytes());
        assert!(extract(&mut Cursor::new(missing)).is_err());
    }

    #[test]
    fn rejects_invalid_headers_ifd_bounds_tags_and_jpeg_lengths() {
        let valid = tiff(
            ByteOrder::Little,
            Some(1),
            100,
            b"\xff\xd8embedded jpeg\xff\xd9".len() as u32,
        );
        let mutate = |edit: &dyn Fn(&mut Vec<u8>)| {
            let mut bytes = valid.clone();
            edit(&mut bytes);
            assert!(extract(&mut Cursor::new(bytes)).is_err());
        };
        mutate(&|bytes| bytes[0] = b'X');
        mutate(&|bytes| bytes[2] = 43);
        mutate(&|bytes| bytes[4..8].copy_from_slice(&u32::MAX.to_le_bytes()));
        mutate(&|bytes| {
            bytes[ifd_offset()..ifd_offset() + 2].copy_from_slice(&u16::MAX.to_le_bytes())
        });
        mutate(&|bytes| {
            bytes[ifd_offset() + 2 + 12 + 2..ifd_offset() + 2 + 12 + 4]
                .copy_from_slice(&3u16.to_le_bytes())
        });
        mutate(&|bytes| {
            bytes[ifd_offset() + 2 + 12 + 4..ifd_offset() + 2 + 12 + 8]
                .copy_from_slice(&2u32.to_le_bytes())
        });
        mutate(&|bytes| {
            bytes[ifd_offset() + 2 + 12 + 8..ifd_offset() + 2 + 12 + 12]
                .copy_from_slice(&0u32.to_le_bytes())
        });
        mutate(&|bytes| {
            bytes[ifd_offset() + 2 + 24 + 8..ifd_offset() + 2 + 24 + 12]
                .copy_from_slice(&0u32.to_le_bytes())
        });
        mutate(&|bytes| {
            bytes[ifd_offset() + 2 + 24 + 8..ifd_offset() + 2 + 24 + 12]
                .copy_from_slice(&u32::MAX.to_le_bytes())
        });
        let mut truncated = valid;
        truncated.truncate(ifd_offset() + 2 + 36);
        assert!(extract(&mut Cursor::new(truncated)).is_err());
    }

    fn ifd_offset() -> usize {
        37
    }

    struct SparseReader {
        file_size: u64,
        position: u64,
        segments: Vec<(u64, Vec<u8>)>,
        bytes_read: usize,
    }

    impl Read for SparseReader {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            let Some((offset, bytes)) = self.segments.iter().find(|(offset, bytes)| {
                self.position >= *offset && self.position < *offset + bytes.len() as u64
            }) else {
                return Ok(0);
            };
            let in_segment = (self.position - *offset) as usize;
            let count = buf.len().min(bytes.len() - in_segment);
            buf[..count].copy_from_slice(&bytes[in_segment..in_segment + count]);
            self.position += count as u64;
            self.bytes_read += count;
            Ok(count)
        }
    }

    impl Seek for SparseReader {
        fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
            let target = match position {
                SeekFrom::Start(offset) => i128::from(offset),
                SeekFrom::Current(offset) => i128::from(self.position) + i128::from(offset),
                SeekFrom::End(offset) => i128::from(self.file_size) + i128::from(offset),
            };
            if target < 0 || target > i128::from(u64::MAX) {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid seek"));
            }
            self.position = target as u64;
            Ok(self.position)
        }
    }

    #[test]
    fn sparse_large_raw_reads_only_ifd_and_embedded_jpeg() {
        let jpeg = b"\xff\xd8small\xff\xd9";
        let ifd_offset = 37u64;
        let jpeg_offset = 256 * 1024 * 1024u64;
        let mut metadata = vec![0; (ifd_offset + 2 + 3 * 12 + 4) as usize];
        metadata[..2].copy_from_slice(b"II");
        metadata[2..4].copy_from_slice(&42u16.to_le_bytes());
        metadata[4..8].copy_from_slice(&(ifd_offset as u32).to_le_bytes());
        metadata[ifd_offset as usize..ifd_offset as usize + 2].copy_from_slice(&3u16.to_le_bytes());
        for (index, (tag, value)) in [(0x0201u16, jpeg_offset as u32), (0x0202, jpeg.len() as u32)]
            .into_iter()
            .enumerate()
        {
            let entry = ifd_offset as usize + 2 + index * 12;
            metadata[entry..entry + 2].copy_from_slice(&tag.to_le_bytes());
            metadata[entry + 2..entry + 4].copy_from_slice(&4u16.to_le_bytes());
            metadata[entry + 4..entry + 8].copy_from_slice(&1u32.to_le_bytes());
            metadata[entry + 8..entry + 12].copy_from_slice(&value.to_le_bytes());
        }
        // Third entry is an unrelated tag.
        let other = ifd_offset as usize + 2 + 24;
        metadata[other..other + 2].copy_from_slice(&0x0100u16.to_le_bytes());
        metadata[other + 2..other + 4].copy_from_slice(&4u16.to_le_bytes());
        metadata[other + 4..other + 8].copy_from_slice(&1u32.to_le_bytes());
        let mut reader = SparseReader {
            file_size: jpeg_offset + jpeg.len() as u64 + 100_000_000,
            position: 0,
            segments: vec![(0, metadata), (jpeg_offset, jpeg.to_vec())],
            bytes_read: 0,
        };
        let extracted = extract(&mut reader).unwrap();
        assert_eq!(extracted.bytes, jpeg);
        assert_eq!(reader.bytes_read, 8 + 2 + 3 * 12 + jpeg.len());
        assert!(reader.bytes_read < 1024);
    }
}
