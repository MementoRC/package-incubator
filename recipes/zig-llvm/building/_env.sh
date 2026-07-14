build_platform="${build_platform:-${target_platform}}"

is_linux() { [[ "${target_platform}" == "linux-"* ]]; }
is_osx() { [[ "${target_platform}" == "osx-"* ]]; }
is_unix() { [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; }
is_not_unix() { [[ "${target_platform}" != "linux-"* && "${target_platform}" != "osx-"* ]]; }
is_cross() { [[ "${build_platform}" != "${target_platform}" ]]; }

# Debug output: ZIG_LLVM_DEBUG=1 in recipe.yaml env
# Note: ZIG_LLVM_DEBUG is an incubator dev-only debug knob, not wired into
# recipe.yaml (unlike ZIG_DEBUG_SDK) — set it manually in a local shell.
_debug() { [[ "${ZIG_LLVM_DEBUG:-0}" == "1" ]]; }
dbg() { _debug && echo "  [DBG] $*" || true; }

# Derive the zig-style target triple from an LLVM triple (drop -unknown-/-w64- infixes).
zig_triplet_from_llvm() {
  local _t="${1/-unknown-/-}"
  printf '%s' "${_t/-w64-/-}"
}


LLVM_SRC="${SRC_DIR}/llvm"
LLVM_BUILD="${SRC_DIR}/conda-llvm-build"
# Windows: conda convention is $PREFIX/Library/ for non-Python artifacts
if [[ "${target_platform}" == win-* ]]; then
  LLVM_INSTALL="${PREFIX}/Library/lib/zig-llvm"
else
  LLVM_INSTALL="${PREFIX}/lib/zig-llvm"
fi

