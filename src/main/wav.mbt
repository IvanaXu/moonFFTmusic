// =============================================================================
// WAV File Reader Module — Parse RIFF/WAVE PCM audio files
// Supports 16-bit signed PCM, mono and stereo
// =============================================================================

///|
/// Parsed WAV file data
struct WavData {
  sample_rate : Int32
  num_channels : Int32
  bits_per_sample : Int32
  samples : Array[Double] // normalized to [-1.0, 1.0]
}

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
fn read_s16_le(data : Bytes, pos : Int32) -> Int32 {
  let val = data[pos].to_int() | (data[pos + 1].to_int() << 8)
  if val >= 32768 {
    val - 65536
  } else {
    val
  }
}

///|
/// Check if 4 bytes at position match the given ASCII tag bytes
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

  // Parse chunks starting after the RIFF header (offset 12)
  let mut pos = 12
  let mut sample_rate = 44100
  let mut num_channels = 1
  let mut bits_per_sample = 16
  let mut data_start = -1
  let mut data_size = 0

  // Walk through chunks: each has 4-byte ID + 4-byte size + payload
  while pos + 8 <= len {
    let chunk_size = read_u32_le(data, pos + 4)
    // "fmt " chunk: 0x66 0x6d 0x74 0x20
    if is_tag(data, pos, 0x66, 0x6d, 0x74, 0x20) {
      num_channels = read_u16_le(data, pos + 10)
      sample_rate = read_u32_le(data, pos + 12)
      bits_per_sample = read_u16_le(data, pos + 22)
    }
    // "data" chunk: 0x64 0x61 0x74 0x61
    if is_tag(data, pos, 0x64, 0x61, 0x74, 0x61) {
      data_start = pos + 8
      data_size = chunk_size
      break
    }
    // Advance to next chunk (chunks are word-aligned, padded to even size)
    pos += 8 + chunk_size
    if chunk_size % 2 == 1 {
      pos += 1
    }
  }

  // Validate: must have data chunk and 16-bit PCM format
  if data_start < 0 || bits_per_sample != 16 {
    return None
  }

  // Calculate number of audio frames (samples per channel)
  let bytes_per_frame = 2 * num_channels // 16-bit = 2 bytes per sample
  let total_samples = data_size / bytes_per_frame
  let samples = Array::make(total_samples, 0.0)

  // Read and normalize PCM samples to [-1.0, 1.0]
  for i in 0..<total_samples {
    let byte_pos = data_start + i * bytes_per_frame
    if byte_pos + 1 >= len {
      break
    }
    if num_channels == 1 {
      // Mono: single 16-bit sample
      let raw = read_s16_le(data, byte_pos)
      samples[i] = raw.to_double() / 32768.0
    } else {
      // Stereo (or more): average first two channels
      let left = read_s16_le(data, byte_pos)
      if byte_pos + 3 < len {
        let right = read_s16_le(data, byte_pos + 2)
        samples[i] = (left.to_double() + right.to_double()) / 65536.0
      } else {
        samples[i] = left.to_double() / 32768.0
      }
    }
  }

  Some(WavData::{ sample_rate, num_channels, bits_per_sample, samples, })
}
