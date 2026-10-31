// =============================================================================
// Terminal Display Module — ANSI bar chart spectrum visualizer
// Renders frequency magnitudes as colored vertical bars
// =============================================================================

///|
/// Clear screen and move cursor to home position (top-left)
fn clear_screen() -> String {
  "\u001b[2J\u001b[H"
}

///|
/// Get ANSI color code for a frequency bar based on its position
/// Low frequencies = green, mid = yellow, high = red
fn bar_color(bar : Int32, num_bars : Int32) -> String {
  let third = num_bars / 3
  if bar < third {
    "\u001b[32m" // green for low frequencies
  } else if bar < third * 2 {
    "\u001b[33m" // yellow for mid frequencies
  } else {
    "\u001b[31m" // red for high frequencies
  }
}

///|
/// Render the frequency spectrum as a vertical bar chart
///
/// # Parameters
/// - magnitudes: FFT magnitude for each frequency bin
/// - num_bars: number of vertical bars to display (typically 40-60)
/// - max_height: maximum bar height in terminal rows
/// - sample_rate: audio sample rate (for frequency labels)
/// - fft_size: FFT window size (for info display)
///
/// # Output
/// Returns a string with ANSI escape codes for terminal rendering.
/// Uses logarithmic magnitude scaling for better visual frequency distribution.
fn render_spectrum(
  magnitudes : Array[Double],
  num_bars : Int32,
  max_height : Int32,
  sample_rate : Int32,
  fft_size : Int32,
) -> String {
  let mut output = clear_screen()

  // Header with project title and info
  output += "\u001b[1;36mMoonFFTmusic — Real-time Spectrum Analyzer\u001b[0m\n"
  output += "Sample Rate: \{sample_rate}Hz | FFT Size: \{fft_size} | Bars: \{num_bars}\n"
  output += "\n"

  // Calculate bar heights using logarithmic scale
  // Log scaling gives better visual distribution across frequencies
  let heights = Array::make(num_bars, 0)
  let half_fft = fft_size / 2
  for bar in 0..<num_bars {
    // Map bar index to FFT frequency bin (linear mapping)
    let bin_idx = bar * half_fft / num_bars
    if bin_idx < magnitudes.length() {
      let mag = magnitudes[bin_idx]
      // Logarithmic scale: log10(mag * 1000 + 1) / 3
      // This maps magnitude range to [0, 1] approximately
      let log_mag = if mag > 0.0 {
        @math.log10(mag * 1000.0 + 1.0) / 3.0
      } else {
        0.0
      }
      // Clamp to [0, 1] and scale to bar height
      let clamped = if log_mag > 1.0 {
        1.0
      } else if log_mag < 0.0 {
        0.0
      } else {
        log_mag
      }
      heights[bar] = (clamped * max_height.to_double()).to_int()
    }
  }

  // Render bars from top row to bottom row
  // Each row checks which bars have reached that height level
  for row in 0..<max_height {
    let level = max_height - row // height threshold for this row
    let mut line = ""
    for bar in 0..<num_bars {
      if heights[bar] >= level {
        // Bar reaches this level: draw colored block
        line += bar_color(bar, num_bars) + "█"
      } else {
        // Bar doesn't reach this level: draw space
        line += " "
      }
    }
    output += line + "\u001b[0m\n"
  }

  // Footer with frequency range labels
  output += "\u001b[0m\u001b[90m"
  let max_freq = sample_rate / 2 // Nyquist frequency
  output += "0Hz"
  // Pad to right-align the max frequency label
  let label_str = "\{max_freq}Hz"
  let label_padding = num_bars - 3 - label_str.length()
  if label_padding > 0 {
    for _ in 0..<label_padding {
      output += " "
    }
  }
  output += label_str + "\n"
  output += "\u001b[0m"

  output
}
