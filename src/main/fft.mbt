// =============================================================================
// FFT Module — Radix-2 Cooley-Tukey Fast Fourier Transform
// Implemented natively in MoonBit (iterative, in-place)
// =============================================================================

///|
/// Complex number with real (re) and imaginary (im) parts
struct Complex {
  re : Double
  im : Double
}

///|
/// Complex magnitude: |z| = sqrt(re^2 + im^2)
fn Complex::mag(self : Complex) -> Double {
  (self.re * self.re + self.im * self.im).sqrt()
}

///|
/// Compute log2 of a power-of-2 integer (counts bits)
fn log2_int(n : Int32) -> Int32 {
  let mut bits = 0
  let mut x = n
  while x > 1 {
    x = x >> 1
    bits += 1
  }
  bits
}

///|
/// Bit-reversal permutation: reverse the lower 'bits' bits of n
/// Example: bit_reverse(0b001, 3) = 0b100 = 4
fn bit_reverse(n : Int32, bits : Int32) -> Int32 {
  let mut result : Int32 = 0
  let mut x = n
  for _ in 0..<bits {
    result = (result << 1) | (x & 1)
    x = x >> 1
  }
  result
}

///|
/// Iterative radix-2 Cooley-Tukey FFT (in-place transform)
///
/// # Algorithm
/// 1. Bit-reversal permutation: reorder samples into bit-reversed index order
/// 2. Butterfly operations: combine pairs at increasing stride (2, 4, 8, ..., N)
///
/// # Parameters
/// - data: array of Complex numbers, length must be a power of 2
///
/// After calling, data[] contains the frequency-domain complex values.
fn fft(data : Array[Complex]) -> Unit {
  let n = data.length()
  if n <= 1 {
    return
  }
  let bits = log2_int(n)

  // Step 1: Bit-reversal permutation
  // Swap elements so they appear in bit-reversed index order
  for i in 0..<n {
    let j = bit_reverse(i, bits)
    if j > i {
      let temp = data[i]
      data[i] = data[j]
      data[j] = temp
    }
  }

  // Step 2: Butterfly operations
  // For each stage (size = 2, 4, 8, ..., N), combine pairs of elements
  let mut size : Int32 = 2
  while size <= n {
    let half = size / 2
    // Twiddle factor base: W = exp(-2πi / size)
    let angle = -2.0 * @math.PI / size.to_double()
    let w_re = @math.cos(angle)
    let w_im = @math.sin(angle)

    // Process each group of 'size' elements
    let mut start = 0
    while start < n {
      // Twiddle factor W^j, starting at W^0 = 1+0i
      let mut tw_re = 1.0
      let mut tw_im = 0.0
      for j in 0..<half {
        let idx1 = start + j
        let idx2 = start + j + half
        // t = W^j * data[idx2]
        let t_re = tw_re * data[idx2].re - tw_im * data[idx2].im
        let t_im = tw_re * data[idx2].im + tw_im * data[idx2].re
        // Save original value before overwriting
        let orig_re = data[idx1].re
        let orig_im = data[idx1].im
        // Butterfly: X[idx1] = orig + t, X[idx2] = orig - t
        data[idx1] = Complex::{ re: orig_re + t_re, im: orig_im + t_im, }
        data[idx2] = Complex::{ re: orig_re - t_re, im: orig_im - t_im, }
        // Advance twiddle: W^(j+1) = W^j * W
        let new_re = tw_re * w_re - tw_im * w_im
        let new_im = tw_re * w_im + tw_im * w_re
        tw_re = new_re
        tw_im = new_im
      }
      start += size
    }
    size *= 2
  }
}

///|
/// Apply Hann window function to each sample before FFT
///
/// The Hann window reduces spectral leakage by smoothly tapering
/// the signal to zero at the chunk boundaries.
///
/// w(n) = 0.5 * (1 - cos(2πn / (N-1)))
fn apply_hann_window(data : Array[Complex]) -> Unit {
  let n = data.length()
  if n <= 1 {
    return
  }
  let denom = (n - 1).to_double()
  for i in 0..<n {
    let hann = 0.5 * (1.0 - @math.cos(2.0 * @math.PI * i.to_double() / denom))
    data[i] = Complex::{ re: data[i].re * hann, im: data[i].im * hann, }
  }
}
