// =============================================================================
// Terminal Display Module — Beautiful ANSI spectrum visualizer
//
// Optimized display effects:
//   - Continuous spectrum (no bar grouping gaps) for seamless visual flow
//   - 32-level brightness gradient (smoother color transitions)
//   - Enhanced HSL color gradient with variable saturation/lightness
//   - Power-curve magnitude scaling for better dynamic range
//   - Richer bottom glow reflection with proper bar colors
//   - Smoother attack/release envelope and spatial smoothing
//   - True-color waveform with amplitude-based coloring
//   - Precomputed color string table [bar][level] — eliminates per-frame
//     string formatting calls
//   - Beat-reactive brightness boost and border glow
// =============================================================================

///|
let partial_blocks : Array[String] = [
  " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█",
]

///|
let ansi_clear : String = "\u001b[2J\u001b[H"

///|
let ansi_reset : String = "\u001b[0m"

///|
let note_names : Array[String] = [
  "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
]

///|
let num_brightness_levels : Int32 = 32

///|
/// Precomputed display context — computed once at startup, reused every frame.
struct DisplayContext {
  num_bars : Int32
  max_height : Int32
  sub_res : Int32
  max_levels : Int32
  bin_map : Array[Int32]
  bin_starts : Array[Int32]
  bin_ends : Array[Int32]
  is_grid : Array[Bool]
  grid_bars : Array[Int32]
  freq_labels : Array[Int32]
  color_table : Array[Array[String]]
  row_contrib : Array[Double]
  height_factor : Double
  sample_rate : Int32
  fft_size : Int32
}

///|
struct BeatDetector {
  energy_history : Array[Double]
  mut history_idx : Int32
  history_size : Int32
  mut beat_intensity : Double
  mut energy_sum : Double
}

///|
fn BeatDetector::new(history_size : Int32) -> BeatDetector {
  BeatDetector::{
    energy_history: Array::make(history_size, 0.0),
    history_idx: 0,
    history_size,
    beat_intensity: 0.0,
    energy_sum: 0.0,
  }
}

///|
fn BeatDetector::update(self : BeatDetector, rms : Double) -> Double {
  let energy = rms * rms
  let idx = self.history_idx
  self.energy_sum -= self.energy_history[idx]
  self.energy_history[idx] = energy
  self.energy_sum += energy
  self.history_idx = (idx + 1) % self.history_size
  let avg = self.energy_sum / self.history_size.to_double()
  if energy > avg * 1.4 && energy > 0.001 {
    self.beat_intensity = 1.0
  } else {
    self.beat_intensity *= 0.92
  }
  self.beat_intensity
}

///|
enum BarState {
  FullBlock
  BarCap
  PartialBlock(Int32)
  PeakMarker
  Empty
}

///|
fn hsl_to_rgb(h : Double, s : Double, l : Double) -> (Int32, Int32, Int32) {
  let c = (1.0 - (2.0 * l - 1.0).abs()) * s
  let h_prime = h / 60.0
  let x = c * (1.0 - (h_prime % 2.0 - 1.0).abs())
  let m = l - c / 2.0
  let (r1, g1, b1) = match h {
    hh if hh < 60.0 => (c, x, 0.0)
    hh if hh < 120.0 => (x, c, 0.0)
    hh if hh < 180.0 => (0.0, c, x)
    hh if hh < 240.0 => (0.0, x, c)
    hh if hh < 300.0 => (x, 0.0, c)
    _ => (c, 0.0, x)
  }
  (
    ((r1 + m) * 255.0).clamp(min=0.0, max=255.0).to_int(),
    ((g1 + m) * 255.0).clamp(min=0.0, max=255.0).to_int(),
    ((b1 + m) * 255.0).clamp(min=0.0, max=255.0).to_int(),
  )
}

///|
fn precompute_bar_colors(
  num_bars : Int32,
) -> (Array[Int32], Array[Int32], Array[Int32]) {
  let bar_r = Array::make(num_bars, 0)
  let bar_g = Array::make(num_bars, 0)
  let bar_b = Array::make(num_bars, 0)
  for bar in 0..<num_bars {
    let ratio = bar.to_double() / (num_bars - 1).to_double()
    // Hue: 260 (indigo) -> 0 (red), wide vibrant spectrum
    let hue = 260.0 * (1.0 - ratio)
    // Saturation: peaks at mid-range (0.95), lower at extremes (0.75)
    let sat = 0.75 + 0.2 * (1.0 - (2.0 * ratio - 1.0).abs())
    // Lightness: darker at bass (0.42), brighter at treble (0.60)
    let light = 0.42 + 0.18 * ratio
    let (r, g, b) = hsl_to_rgb(hue, sat, light)
    bar_r[bar] = r
    bar_g[bar] = g
    bar_b[bar] = b
  }
  (bar_r, bar_g, bar_b)
}

///|
fn precompute_color_table(
  bar_r : Array[Int32],
  bar_g : Array[Int32],
  bar_b : Array[Int32],
  num_levels : Int32,
) -> Array[Array[String]] {
  let num_bars = bar_r.length()
  let table : Array[Array[String]] = Array::make(num_bars, [])
  for bar in 0..<num_bars {
    let levels = Array::make(num_levels, "")
    for level in 0..<num_levels {
      // Brightness range: 0.15 (deep dark) -> 1.0 (full bright)
      let brightness = 0.15 +
        level.to_double() / (num_levels - 1).to_double() * 0.85
      let r = (bar_r[bar].to_double() * brightness)
        .clamp(min=0.0, max=255.0)
        .to_int()
      let g = (bar_g[bar].to_double() * brightness)
        .clamp(min=0.0, max=255.0)
        .to_int()
      let b = (bar_b[bar].to_double() * brightness)
        .clamp(min=0.0, max=255.0)
        .to_int()
      levels[level] = "\u001b[38;2;\{r};\{g};\{b}m"
    }
    table[bar] = levels
  }
  table
}

///|
fn log_freq_bin(bar : Int32, num_bars : Int32, half_fft : Int32) -> Int32 {
  if half_fft <= 1 {
    return 0
  }
  let ratio = bar.to_double() / num_bars.to_double()
  let log_val = @math.pow(2.0, ratio * @math.log2(half_fft.to_double()))
  (log_val.to_int() - 1).clamp(min=0, max=half_fft - 1)
}

///|
fn freq_to_bar(
  freq : Double,
  num_bars : Int32,
  half_fft : Int32,
  sample_rate : Int32,
) -> Int32 {
  if freq <= 0.0 || half_fft <= 1 {
    return 0
  }
  let bin = freq * (half_fft * 2).to_double() / sample_rate.to_double()
  if bin <= 0.0 {
    return 0
  }
  let ratio = @math.log2(bin) / @math.log2(half_fft.to_double())
  (ratio * num_bars.to_double()).to_int().clamp(min=0, max=num_bars - 1)
}

///|
fn create_display_context(
  num_bars : Int32,
  max_height : Int32,
  sub_res : Int32,
  half_fft : Int32,
  sample_rate : Int32,
  fft_size : Int32,
) -> DisplayContext {
  let bin_map = Array::makei(num_bars, fn(bar) {
    log_freq_bin(bar, num_bars, half_fft)
  })
  let bin_starts = Array::make(num_bars, 0)
  let bin_ends = Array::make(num_bars, 0)
  for bar in 0..<num_bars {
    bin_starts[bar] = bin_map[bar]
    if bar < num_bars - 1 {
      bin_ends[bar] = bin_map[bar + 1] + 1
    } else {
      bin_ends[bar] = half_fft
    }
    if bin_ends[bar] <= bin_starts[bar] {
      bin_ends[bar] = bin_starts[bar] + 1
    }
    if bin_ends[bar] > half_fft {
      bin_ends[bar] = half_fft
    }
  }
  let freq_labels : Array[Int32] = [50, 100, 200, 500, 1000, 2000, 5000, 10000]
  let grid_bars = Array::makei(freq_labels.length(), fn(j) {
    freq_to_bar(freq_labels[j].to_double(), num_bars, half_fft, sample_rate)
  })
  let is_grid = Array::make(num_bars, false)
  for j in 0..<grid_bars.length() {
    let gb = grid_bars[j]
    if gb >= 0 && gb < num_bars {
      is_grid[gb] = true
    }
  }
  let (bar_r, bar_g, bar_b) = precompute_bar_colors(num_bars)
  let color_table = precompute_color_table(
    bar_r, bar_g, bar_b, num_brightness_levels,
  )
  // Row contribution: range [3.0, 17.0] for 32 brightness levels
  // Bottom rows dimmer, top rows brighter — 3D glow effect
  let row_contrib = Array::makei(max_height, fn(row) {
    3.0 + row.to_double() / max_height.to_double() * 14.0
  })
  let max_levels = max_height * sub_res
  let height_factor = 14.0 / max_levels.to_double()
  DisplayContext::{
    num_bars,
    max_height,
    sub_res,
    max_levels,
    bin_map,
    bin_starts,
    bin_ends,
    is_grid,
    grid_bars,
    freq_labels,
    color_table,
    row_contrib,
    height_factor,
    sample_rate,
    fft_size,
  }
}

///|
fn format_time(samples : Int32, sample_rate : Int32) -> String {
  let total_ms = samples * 1000 / sample_rate
  let minutes = total_ms / 60000
  let seconds = total_ms % 60000 / 1000
  let tenths = total_ms % 1000 / 100
  "\{minutes}:\{seconds}.\{tenths}"
}

///|
fn format_freq(hz : Int32) -> String {
  match hz {
    k if k >= 1000 => "\{k / 1000}kHz"
    _ => "\{hz}Hz"
  }
}

///|
fn freq_to_note(hz : Int32) -> String {
  if hz <= 0 {
    return "---"
  }
  let midi = 69.0 + 12.0 * @math.log2(hz.to_double() / 440.0)
  let midi_int = midi.round().to_int()
  if midi_int < 0 || midi_int > 127 {
    return "---"
  }
  let note_idx = midi_int % 12
  let octave = midi_int / 12 - 1
  let cents = ((midi - midi_int.to_double()) * 100.0).to_int()
  let cents_str = if cents > 5 { "+" } else if cents < -5 { "-" } else { "" }
  "\{note_names[note_idx]}\{octave}\{cents_str}"
}

///|
fn scale_magnitude(mag : Double) -> Double {
  if mag > 0.0 {
    // Power curve: boosts low/mid values for better detail visibility
    @math.pow(mag, 0.6).clamp(min=0.0, max=1.0)
  } else {
    0.0
  }
}

///|
fn bar_state(
  height : Int32,
  peak : Int32,
  level_top : Int32,
  level_bottom : Int32,
) -> BarState {
  if height >= level_top {
    if height < level_top + 8 {
      BarCap
    } else {
      FullBlock
    }
  } else if height > level_bottom {
    let frac = height - level_bottom
    PartialBlock(frac.clamp(min=0, max=8))
  } else if peak >= level_top && peak > 0 {
    PeakMarker
  } else {
    Empty
  }
}

///|
fn render_db_scale(sb : StringBuilder, row : Int32, max_height : Int32) -> Unit {
  let db_labels : Array[String] = [" 0dB", "-12", "-24", "-36", "-48"]
  let label_row = (row * (db_labels.length() - 1) / max_height).clamp(
    min=0,
    max=db_labels.length() - 1,
  )
  let expected_row = label_row * max_height / (db_labels.length() - 1)
  if row == expected_row {
    // Warm-to-cool gradient: 0dB=warm white, -48dB=cool blue
    let hue = 200.0 *
      label_row.to_double() /
      (db_labels.length() - 1).to_double()
    let (r, g, b) = hsl_to_rgb(hue, 0.3, 0.6)
    sb.write_string("\u001b[38;2;\{r};\{g};\{b}m")
    sb.write_string(db_labels[label_row])
    sb.write_string("\u001b[0m ")
  } else {
    sb.write_string("\u001b[38;2;70;70;90m│\u001b[0m ")
  }
}

///|
fn is_ref_line(row : Int32, max_height : Int32) -> Bool {
  row == 1 * max_height / 4
}

///|
/// Render waveform strip with true-color amplitude-based coloring.
fn render_waveform(
  sb : StringBuilder,
  waveform : Array[Double],
  width : Int32,
  beat_intensity : Double,
) -> Unit {
  sb.write_string("\u001b[90m  WV \u001b[0m")
  let n = waveform.length()
  if n == 0 {
    sb.write_string("\n")
    return
  }
  let step = n.to_double() / width.to_double()
  for i in 0..<width {
    let sample_idx = (i.to_double() * step).to_int().clamp(min=0, max=n - 1)
    let sample = waveform[sample_idx]
    let scaled = (sample * 4.0).clamp(min=-4.0, max=4.0).to_int()
    let abs_amp = sample.abs().clamp(min=0.0, max=1.0)
    let amp_int = (abs_amp * 255.0).to_int()
    match scaled {
      0 => sb.write_string("\u001b[38;2;60;70;90m─\u001b[0m")
      1 => {
        let g = 180 + amp_int / 4
        sb.write_string("\u001b[38;2;80;\{g};200m▔\u001b[0m")
      }
      2 => {
        let g = 200 + amp_int / 5
        sb.write_string("\u001b[38;2;60;\{g};180m▀\u001b[0m")
      }
      3 | 4 =>
        if beat_intensity > 0.3 {
          let r = 200 + (beat_intensity * 55.0).to_int()
          sb.write_string("\u001b[38;2;\{r};255;100m█\u001b[0m")
        } else {
          let g = 220 + amp_int / 6
          sb.write_string("\u001b[38;2;100;\{g};120m█\u001b[0m")
        }
      -1 => {
        let b = 180 + amp_int / 4
        sb.write_string("\u001b[38;2;80;150;\{b}m▁\u001b[0m")
      }
      -2 => {
        let b = 200 + amp_int / 5
        sb.write_string("\u001b[38;2;100;120;\{b}m▄\u001b[0m")
      }
      -3 | -4 =>
        if beat_intensity > 0.3 {
          let r = 100 + (beat_intensity * 155.0).to_int()
          sb.write_string("\u001b[38;2;\{r};150;255m█\u001b[0m")
        } else {
          let b = 220 + amp_int / 6
          sb.write_string("\u001b[38;2;120;150;\{b}m█\u001b[0m")
        }
      _ => sb.write_string("\u001b[38;2;60;70;90m─\u001b[0m")
    }
  }
  sb.write_string("\n")
}

///|
/// Main spectrum renderer — fully optimized hot path.
/// All arrays reused, color lookup via precomputed table, O(1) brightness.
fn render_spectrum(
  magnitudes : Array[Double],
  ctx : DisplayContext,
  peak_heights : Array[Int32],
  peak_frames : Array[Int32],
  prev_heights : Array[Int32],
  heights : Array[Int32],
  current_pos : Int32,
  total_samples : Int32,
  rms_value : Double,
  beat_intensity : Double,
  waveform : Array[Double],
) -> String {
  let sb = StringBuilder::StringBuilder()
  let num_bars = ctx.num_bars
  let max_height = ctx.max_height
  let sub_res = ctx.sub_res
  let max_levels = ctx.max_levels
  let sample_rate = ctx.sample_rate
  let fft_size = ctx.fft_size

  sb.write_string(ansi_clear)

  // --- Calculate bar heights from pre-aggregated magnitudes ---
  let mut dominant_bar = 0
  let mut max_mag = 0.0
  for bar in 0..<num_bars {
    let mag = magnitudes[bar]
    if mag > max_mag {
      max_mag = mag
      dominant_bar = bar
    }
    heights[bar] = (scale_magnitude(mag) * max_levels.to_double()).to_int()
  }

  // --- Attack/release envelope (smoother rise, more responsive fall) ---
  for bar in 0..<num_bars {
    let prev = prev_heights[bar].to_double()
    let curr = heights[bar].to_double()
    let smoothed = if curr >= prev {
      prev * 0.4 + curr * 0.6
    } else {
      prev * 0.8 + curr * 0.2
    }
    heights[bar] = smoothed.to_int()
    prev_heights[bar] = heights[bar]
  }

  // --- Spatial smoothing: in-place 3-tap blur [0.25, 0.5, 0.25] ---
  let mut prev_val = 0.0
  for bar in 0..<num_bars {
    let left = prev_val
    let center = heights[bar].to_double()
    let right = if bar < num_bars - 1 {
      heights[bar + 1].to_double()
    } else {
      0.0
    }
    let blurred = left * 0.25 + center * 0.5 + right * 0.25
    prev_val = center
    heights[bar] = blurred.to_int()
  }

  // --- Update peak hold ---
  for bar in 0..<num_bars {
    match (heights[bar] >= peak_heights[bar], peak_frames[bar] > 3) {
      (true, _) => {
        peak_heights[bar] = heights[bar]
        peak_frames[bar] = 0
      }
      (false, true) => {
        let decayed = (peak_heights[bar].to_double() * 0.88).to_int()
        peak_heights[bar] = decayed
        peak_frames[bar] = 0
      }
      (false, false) => peak_frames[bar] = peak_frames[bar] + 1
    }
  }

  // --- Dominant frequency + note ---
  let dominant_bin = ctx.bin_map[dominant_bar]
  let dominant_freq = dominant_bin * sample_rate / fft_size
  let note_name = freq_to_note(dominant_freq)

  // --- Beat glow border ---
  let beat_glow = if beat_intensity > 0.1 {
    "\u001b[38;2;255;\{(beat_intensity * 200.0).to_int()};\{(beat_intensity * 100.0).to_int()}m"
  } else {
    "\u001b[1;36m"
  }

  // --- Beat-reactive brightness boost (shift color level up to 4) ---
  let beat_boost = (beat_intensity * 6.0).to_int()

  // --- Header ---
  let header_width = num_bars + 6
  let title = "🎵 MoonFFTmusic — Real-time Spectrum Analyzer"
  let beat_indicator = if beat_intensity > 0.5 { " ♫" } else { "  " }
  let info_line = "Rate: \{sample_rate}Hz | FFT: \{fft_size} | Bars: \{num_bars} | Peak: \{format_freq(dominant_freq)} (\{note_name})\{beat_indicator} | \{format_time(current_pos, sample_rate)}"

  sb.write_string(beat_glow)
  sb.write_string("╔")
  for _ in 0..<header_width {
    sb.write_string("═")
  }
  sb.write_string("╗\n║ ")
  sb.write_string(title)
  let title_pad = (header_width - title.length() - 2).clamp(
    min=0,
    max=header_width,
  )
  for _ in 0..<title_pad {
    sb.write_string(" ")
  }
  sb.write_string(" ║\n║ ")
  sb.write_string(info_line)
  let info_pad = (header_width - info_line.length() - 2).clamp(
    min=0,
    max=header_width,
  )
  for _ in 0..<info_pad {
    sb.write_string(" ")
  }
  sb.write_string(" ║\n╚")
  for _ in 0..<header_width {
    sb.write_string("═")
  }
  sb.write_string("╝\n\u001b[0m")

  // --- Separator with true-color gradient + beat pulse ---
  let sep_light = 0.3 + beat_intensity * 0.15
  for i in 0..<(num_bars + 6) {
    let ratio = i.to_double() / (num_bars + 5).to_double()
    let hue = 260.0 * (1.0 - ratio)
    let (r, g, b) = hsl_to_rgb(hue, 0.6, sep_light)
    sb.write_string("\u001b[38;2;\{r};\{g};\{b}m─")
  }
  sb.write_string("\u001b[0m\n")

  // --- Peak marker row (continuous, no bar gaps) ---
  sb.write_string("\u001b[90m     \u001b[0m")
  for bar in 0..<num_bars {
    if bar == dominant_bar && heights[bar] > 0 {
      sb.write_string("\u001b[1;33m▼\u001b[0m")
    } else if ctx.is_grid[bar] {
      sb.write_string(ctx.color_table[bar][3])
      sb.write_string("╎\u001b[0m")
    } else {
      sb.write_string(" ")
    }
  }
  sb.write_string("\n")

  // --- Render bars with precomputed color table (continuous, no gaps) ---
  for row in 0..<max_height {
    render_db_scale(sb, row, max_height)
    let level_top = (max_height - row) * sub_res
    let level_bottom = (max_height - row - 1) * sub_res
    let ref_line = is_ref_line(row, max_height)
    for bar in 0..<num_bars {
      match
        bar_state(heights[bar], peak_heights[bar], level_top, level_bottom) {
        FullBlock => {
          let level = (ctx.row_contrib[row] +
            heights[bar].to_double() * ctx.height_factor +
            beat_boost.to_double())
            .to_int()
            .clamp(min=0, max=num_brightness_levels - 1)
          sb.write_string(ctx.color_table[bar][level])
          sb.write_string("█")
        }
        BarCap => {
          let level = (ctx.row_contrib[row] +
            heights[bar].to_double() * ctx.height_factor +
            beat_boost.to_double() +
            4.0)
            .to_int()
            .clamp(min=0, max=num_brightness_levels - 1)
          sb.write_string(ctx.color_table[bar][level])
          sb.write_string("▀")
        }
        PartialBlock(frac) => {
          let level = (ctx.row_contrib[row] +
            heights[bar].to_double() * ctx.height_factor +
            beat_boost.to_double())
            .to_int()
            .clamp(min=0, max=num_brightness_levels - 1)
          sb.write_string(ctx.color_table[bar][level])
          sb.write_string(partial_blocks[frac])
        }
        PeakMarker => {
          sb.write_string("\u001b[1m")
          let peak_level = (peak_heights[bar].to_double() * ctx.height_factor +
            20.0)
            .to_int()
            .clamp(min=10, max=num_brightness_levels - 1)
          sb.write_string(ctx.color_table[bar][peak_level])
          sb.write_string("━")
          sb.write_string("\u001b[22m")
        }
        Empty =>
          if ctx.is_grid[bar] {
            sb.write_string(ctx.color_table[bar][3])
            sb.write_string("╎\u001b[0m")
          } else if ref_line {
            sb.write_string(ctx.color_table[bar][2])
            sb.write_string("┄\u001b[0m")
          } else {
            sb.write_string(" ")
          }
      }
    }
    sb.write_string(ansi_reset)
    sb.write_string("\n")
  }

  // --- Bottom glow reflection with proper bar colors (5 rows) ---
  for glow_row in 0..<5 {
    sb.write_string("\u001b[90m     \u001b[0m")
    let glow_factor = match glow_row {
      0 => 0.4
      1 => 0.3
      2 => 0.2
      3 => 0.12
      _ => 0.06
    }
    for bar in 0..<num_bars {
      let reflected_height = (heights[bar].to_double() * glow_factor).to_int()
      let glow_level = (glow_row + 1) * sub_res
      if reflected_height >= glow_level {
        let color_level = match glow_row {
          0 => 12
          1 => 9
          2 => 6
          3 => 4
          _ => 2
        }
        sb.write_string(ctx.color_table[bar][color_level])
        sb.write_string("▀")
      } else {
        sb.write_string(" ")
      }
    }
    sb.write_string(ansi_reset)
    sb.write_string("\n")
  }

  // --- Frequency labels ---
  sb.write_string("     ")
  let mut label_pos = 0
  for i in 0..<num_bars {
    let mut found_label = ""
    for j in 0..<ctx.freq_labels.length() {
      if ctx.grid_bars[j] == i {
        found_label = format_freq(ctx.freq_labels[j])
        break
      }
    }
    if found_label.length() > 0 {
      while label_pos < i {
        sb.write_string(" ")
        label_pos = label_pos + 1
      }
      sb.write_string(ctx.color_table[i][18])
      sb.write_string(found_label)
      sb.write_string("\u001b[0m")
      label_pos = i + found_label.length()
    }
  }
  sb.write_string("\n")

  // --- Waveform strip ---
  render_waveform(sb, waveform, num_bars, beat_intensity)

  // --- RMS meter ---
  let rms_db = if rms_value > 0.0 {
    20.0 * @math.log10(rms_value)
  } else {
    -99.0
  }
  let rms_pct = if rms_value > 0.0 {
    ((rms_db + 60.0) / 60.0).clamp(min=0.0, max=1.0)
  } else {
    0.0
  }
  let meter_width = 20
  let meter_filled = (rms_pct * meter_width.to_double()).to_int()

  sb.write_string("\n\u001b[1;37mRMS: \u001b[0m[")
  for i in 0..<meter_width {
    let pct = i.to_double() / meter_width.to_double()
    if i < meter_filled {
      let hue = 120.0 * (1.0 - pct)
      let (r, g, b) = hsl_to_rgb(hue, 0.85, 0.55)
      sb.write_string("\u001b[38;2;\{r};\{g};\{b}m█")
    } else {
      sb.write_string("\u001b[90m░")
    }
  }
  sb.write_string("\u001b[0m] ")
  let db_int = rms_db.to_int()
  let db_frac = ((rms_db - db_int.to_double()) * 10.0).abs().to_int()
  sb.write_string("\{db_int}.\{db_frac} dB\n")

  // --- Progress bar ---
  let progress_pct = if total_samples > 0 {
    current_pos.to_double() / total_samples.to_double()
  } else {
    0.0
  }
  let progress_filled = (progress_pct * num_bars.to_double()).to_int()

  for i in 0..<num_bars {
    if i < progress_filled {
      sb.write_string(ctx.color_table[i][28])
      sb.write_string("║")
    } else if i == progress_filled {
      sb.write_string(ctx.color_table[i][28])
      sb.write_string("▓")
    } else {
      sb.write_string("\u001b[90m░")
    }
  }
  sb.write_string("\u001b[0m ")
  let pct_int = (progress_pct * 100.0).to_int()
  sb.write_string(
    "\{pct_int}%  \{format_time(current_pos, sample_rate)} / \{format_time(total_samples, sample_rate)}\n",
  )

  sb.to_string()
}
