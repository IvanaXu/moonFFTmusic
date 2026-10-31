// =============================================================================
// WAV File Reader Module — Parse RIFF/WAVE PCM audio files
// Optimized with MoonBit features: derive(Debug), match patterns, test blocks
// =============================================================================

///|
/// Parsed WAV file data
/// derive(Debug) auto-generates to_string for debugging
struct WavData {
  sample_rate : Int32
  num_channels : Int32
  bits_per_sample : Int32
  samples : Array[Double] // normalized to [-1.0, 1.0]
} derive(Debug)

///|
/// Read a little-endian unsigned 16-bit value from bytes at position
fn read_u16_le(data : Bytes, pos : Int32) -> Int32 {
  data[pos].to_int() | (data[pos + 1].to_int() << 8)
}

///|
/// Read a little-endian unsigned 32-bit value from bytes at position
fn read_u32_le(data : Bytes, pos : Int32) -> Int32 {
  data[pos].to_int() |
  (data[pos + 1].to_int() << 8) |
  (data[pos + 2].to_int() << 16) |
  (data[pos + 3].to_int() << 24)
}

///|
/// Read a little-endian signed 16-bit value from bytes at position
/// Uses match pattern for sign extension
fn read_s16_le(data : Bytes, pos : Int32) -> Int32 {
  let val = data[pos].to_int() | (data[pos + 1].to_int() << 8)
  match val {
    v if v >= 32768 => v - 65536
    _ => val
  }
}

///|
/// Check if 4 bytes at position match the given ASCII tag
fn is_tag(
  data : Bytes,
  pos : Int32,
  a : Int32,
  b : Int32,
  c : Int32,
  d : Int32,
) -> Bool {
  data[pos].to_int() == a &&
  data[pos + 1].to_int() == b &&
  data[pos + 2].to_int() == c &&
  data[pos + 3].to_int() == d
}

///|
/// Chunk type identified during WAV parsing — used with match pattern
enum ChunkType {
  FmtChunk // "fmt " — format information
  DataChunk // "data" — audio data
  OtherChunk // unknown chunk — skip
}

///|
/// Identify chunk type using match pattern
fn identify_chunk(data : Bytes, pos : Int32) -> ChunkType {
  if is_tag(data, pos, 0x66, 0x6d, 0x74, 0x20) {
    FmtChunk
  } else if is_tag(data, pos, 0x64, 0x61, 0x74, 0x61) {
    DataChunk
  } else {
    OtherChunk
  }
}

///|
/// Parse a WAV file from raw bytes and extract normalized audio samples
///
/// # WAV File Format
/// - RIFF header: "RIFF" + file_size + "WAVE"
/// - fmt  chunk: "fmt " + chunk_size + audio_format + channels + sample_rate + ...
/// - data chunk: "data" + chunk_size + raw PCM samples
///
/// # Returns
/// - Some(WavData) if parsing succeeds
/// - None if the file is not a valid 16-bit PCM WAV file
fn read_wav(data : Bytes) -> WavData? {
  let len = data.length()
  // Minimum valid WAV header is 44 bytes
  if len < 44 {
    return None
  }
  // Verify RIFF magic bytes: "RIFF" = 0x52 0x49 0x46 0x46
  if !is_tag(data, 0, 0x52, 0x49, 0x46, 0x46) {
    return None
  }
  // Verify WAVE format: "WAVE" = 0x57 0x41 0x56 0x45
  if !is_tag(data, 8, 0x57, 0x41, 0x56, 0x45) {
    return None
  }

  // Parse chunks using match pattern on ChunkType enum
  let mut pos = 12
  let mut sample_rate = 44100
  let mut num_channels = 1
  let mut bits_per_sample = 16
  let mut data_start = -1
  let mut data_size = 0

  while pos + 8 <= len {
    let chunk_size = read_u32_le(data, pos + 4)
    // Use match pattern for chunk type dispatch
    match identify_chunk(data, pos) {
      FmtChunk => {
        num_channels = read_u16_le(data, pos + 10)
        sample_rate = read_u32_le(data, pos + 12)
        bits_per_sample = read_u16_le(data, pos + 22)
      }
      DataChunk => {
        data_start = pos + 8
        data_size = chunk_size
        break
      }
      OtherChunk => () // skip unknown chunks
    }
    // Advance to next chunk (word-aligned, padded to even size)
    pos += 8 + chunk_size
    if chunk_size % 2 == 1 {
      pos += 1
    }
  }

  // Validate using guard pattern
  if data_start < 0 || bits_per_sample != 16 {
    return None
  }

  // Calculate number of audio frames
  let bytes_per_frame = 2 * num_channels
  let total_samples = data_size / bytes_per_frame
  let samples = Array::make(total_samples, 0.0)

  // Read and normalize PCM samples — match on channel count
  for i in 0..<total_samples {
    let byte_pos = data_start + i * bytes_per_frame
    if byte_pos + 1 >= len {
      break
    }
    match num_channels {
      1 =>
        // Mono: single 16-bit sample
        samples[i] = read_s16_le(data, byte_pos).to_double() / 32768.0
      _ => {
        // Stereo+: average first two channels
        let left = read_s16_le(data, byte_pos)
        match byte_pos + 3 < len {
          true => {
            let right = read_s16_le(data, byte_pos + 2)
            samples[i] = (left.to_double() + right.to_double()) / 65536.0
          }
          false => samples[i] = left.to_double() / 32768.0
        }
      }
    }
  }

  Some(WavData::{ sample_rate, num_channels, bits_per_sample, samples, })
}

// =============================================================================
// Inline Tests
// =============================================================================

///|
test "read_u16_le reads little-endian 16-bit" {
  // Bytes: 0x34 0x12 → 0x1234 = 4660
  let data = Bytes::from_array([0x34, 0x12, 0x00, 0x00])
  assert_eq(read_u16_le(data, 0), 0x1234)
}

///|
test "read_u32_le reads little-endian 32-bit" {
  // Bytes: 0x78 0x56 0x34 0x12 → 0x12345678
  let data = Bytes::from_array([0x78, 0x56, 0x34, 0x12])
  assert_eq(read_u32_le(data, 0), 0x12345678)
}

///|
test "read_s16_le handles negative values" {
  // Bytes: 0x00 0x80 → 0x8000 = -32768 (most negative 16-bit)
  let data = Bytes::from_array([0x00, 0x80, 0x00, 0x00])
  assert_eq(read_s16_le(data, 0), -32768)
}

///|
test "read_s16_le handles positive values" {
  // Bytes: 0xFF 0x7F → 0x7FFF = 32767 (most positive 16-bit)
  let data = Bytes::from_array([0xFF, 0x7F, 0x00, 0x00])
  assert_eq(read_s16_le(data, 0), 32767)
}

///|
test "is_tag matches correct bytes" {
  let data = Bytes::from_array([0x52, 0x49, 0x46, 0x46]) // "RIFF"
  assert_true(is_tag(data, 0, 0x52, 0x49, 0x46, 0x46))
}

///|
test "is_tag rejects wrong bytes" {
  let data = Bytes::from_array([0x00, 0x49, 0x46, 0x46])
  assert_false(is_tag(data, 0, 0x52, 0x49, 0x46, 0x46))
}

///|
test "read_wav rejects too-short data" {
  let data = Bytes::from_array([0x52, 0x49, 0x46, 0x46])
  assert_true(read_wav(data) is None)
}

///|
test "read_wav rejects non-RIFF data" {
  let data = Bytes::from_array([
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ])
  assert_true(read_wav(data) is None)
}
