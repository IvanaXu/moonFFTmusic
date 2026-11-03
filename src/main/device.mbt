// =============================================================================
// Device Selection — pick GPU when detectable, otherwise CPU
//
// Detection strategy (Linux native):
//   1. Honor CUDA_VISIBLE_DEVICES: "-1" or empty explicitly disables GPU
//   2. NVIDIA driver nodes: /dev/nvidia0 .. /dev/nvidia15
//   3. Generic DRM nodes: /dev/dri/card0..7, /dev/dri/renderD128..135
//      (AMD / Intel / other GPUs)
//   4. Fall back to CPU when no GPU node exists
//
// The GPU compute kernel itself is a follow-up; selection and reporting land
// now so the device switch is already in place when GPU targets arrive.
// =============================================================================

///|
#derive(Debug)
struct GpuInfo {
  /// A detected GPU device: vendor label + device node path
  vendor : String
  node : String
}

///|
#derive(Debug)
enum ComputeDevice {
  /// Compute device chosen at startup
  Gpu(GpuInfo)
  Cpu
}

///|
/// Candidate device nodes probed in priority order (NVIDIA first)
fn gpu_candidate_nodes() -> Array[String] {
  let nodes : Array[String] = []
  for i in 0..<16 {
    nodes.push("/dev/nvidia\{i}")
  }
  for i in 0..<8 {
    nodes.push("/dev/dri/card\{i}")
  }
  for i in 0..<8 {
    nodes.push("/dev/dri/renderD\{128 + i}")
  }
  nodes
}

///|
/// True when CUDA_VISIBLE_DEVICES explicitly disables GPU usage
fn gpu_disabled_by_env(value : String?) -> Bool {
  match value {
    Some(s) => s == "-1" || s == ""
    None => false
  }
}

///|
/// Pick the first available GPU from detected nodes (order = priority)
fn pick_gpu(nodes : Array[String]) -> GpuInfo? {
  for node in nodes {
    if node.contains("nvidia") {
      return Some(GpuInfo::{ vendor: "NVIDIA", node, })
    }
    if node.contains("/dev/dri/") {
      return Some(GpuInfo::{ vendor: "DRM", node, })
    }
  }
  None
}

///|
/// Detect a usable GPU via device nodes under /dev
async fn detect_gpu() -> GpuInfo? {
  if gpu_disabled_by_env(@env.get_env_var("CUDA_VISIBLE_DEVICES")) {
    return None
  }
  let found : Array[String] = []
  for node in gpu_candidate_nodes() {
    if @fs.exists(node) {
      found.push(node)
    }
  }
  pick_gpu(found)
}

///|
/// Auto-select compute device: GPU when detectable, CPU otherwise
async fn select_device() -> ComputeDevice {
  match detect_gpu() {
    Some(info) => Gpu(info)
    None => Cpu
  }
}

///|
/// Human-readable device label for startup logging
fn device_label(device : ComputeDevice) -> String {
  match device {
    Gpu(info) => "GPU (\{info.vendor}, \{info.node})"
    Cpu => "CPU"
  }
}

// =============================================================================
// Inline Tests
// =============================================================================

///|
test "gpu_disabled_by_env honors explicit disable" {
  assert_false(gpu_disabled_by_env(None))
  assert_true(gpu_disabled_by_env(Some("")))
  assert_true(gpu_disabled_by_env(Some("-1")))
  assert_false(gpu_disabled_by_env(Some("0")))
  assert_false(gpu_disabled_by_env(Some("0,1")))
}

///|
test "pick_gpu selects first node in priority order" {
  assert_true(pick_gpu([]) is None)
  let drm = pick_gpu(["/dev/dri/card0"]).unwrap()
  assert_eq(drm.vendor, "DRM")
  assert_eq(drm.node, "/dev/dri/card0")
  let nvidia = pick_gpu(["/dev/nvidia3", "/dev/dri/card0"]).unwrap()
  assert_eq(nvidia.vendor, "NVIDIA")
  assert_eq(nvidia.node, "/dev/nvidia3")
}

///|
test "device_label formats GPU and CPU" {
  assert_eq(device_label(Cpu), "CPU")
  assert_eq(
    device_label(Gpu(GpuInfo::{ vendor: "NVIDIA", node: "/dev/nvidia0", })),
    "GPU (NVIDIA, /dev/nvidia0)",
  )
}

///|
test "gpu_candidate_nodes probes nvidia then dri" {
  let nodes = gpu_candidate_nodes()
  assert_eq(nodes[0], "/dev/nvidia0")
  assert_true(nodes.contains("/dev/nvidia15"))
  assert_true(nodes.contains("/dev/dri/card0"))
  assert_true(nodes.contains("/dev/dri/renderD135"))
}
