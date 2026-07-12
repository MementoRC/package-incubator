#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# LC_ALL=C avoids 'bash: warning: setlocale: LC_ALL: cannot change locale
# (C.UTF-8)' from bash's startup when conda activates the env with
# LC_ALL=C.UTF-8 but the runner's locale-archive lacks C.UTF-8 (macOS
# specifically). Findllvm.cmake captures the llvm-config wrapper's stderr
# via ERROR_VARIABLE and treats the warning as 'shared library not
# supported', so any bash invocation chain that goes through cmake's
# captured-stderr path must run with LC_ALL=C.
export LC_ALL=C

if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_build.sh"  # configure_cmake_zigcpp, build_zig_with_zig, remove_failing_langref

build_platform="${build_platform:-${target_platform}}"

is_linux() { [[ "${target_platform}" == "linux-"* ]]; }
is_osx() { [[ "${target_platform}" == "osx-"* ]]; }
is_unix() { [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; }
is_not_unix() { ! is_unix; }
is_cross() { [[ "${build_platform}" != "${target_platform}" ]]; }
is_riscv64() { [[ "${target_platform:-}" == "linux-riscv64" ]]; }

is_debug() { [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]]; }

# --- Early exits ---

[[ -z "${CONDA_TRIPLET:-}" ]] && { echo "CONDA_TRIPLET must be specified in recipe.yaml env"; exit 1; }
[[ -z "${CONDA_ZIG_BUILD:-}" ]] && { echo "CONDA_ZIG_BUILD undefined, use zig_<arch> instead of _impl"; exit 1; }
[[ -z "${ZIG_TRIPLET:-}" ]] && { echo "ZIG_TRIPLET must be specified in recipe.yaml env"; exit 1; }

if [[ "${PKG_NAME:-}" != "zig-zig_impl_"* ]]; then
  echo "ERROR: Unknown package name: ${PKG_NAME} - Verify recipe.yaml script:"
  exit 1
fi

# === Build caching for quick recipe iteration ===
# Set ZIG_USE_CACHE=1 to enable build caching:
#   - First run: builds normally, caches result
#   - Subsequent runs: restores from cache, skips build
if [[ "${ZIG_USE_CACHE:-0}" == "1" ]]; then
  source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
  if stub_cache_restore; then
    echo "=== Build restored from cache (skipping compilation) ==="
    # Build musl shared libraries for cross-compilation targets
    # This enables sysroot-free cross-compilation with dynamic linking
    source "${RECIPE_DIR}/build_scripts/_post_install.sh"
    post_install
    exit 0
  fi
  echo "=== No cache found - will build and cache result ==="
  # Continue with normal build, cache will be saved at the end
fi

# --- Main ---

# This allows to skip a known failing zig build with zig
force_cmake=0

export CMAKE_BUILD_PARALLEL_LEVEL="${CPU_COUNT}"
export CMAKE_GENERATOR=Ninja
export ZIG_GLOBAL_CACHE_DIR="${SRC_DIR}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${SRC_DIR}/zig-local-cache"

cmake_source_dir="${SRC_DIR}/zig-source"
cmake_build_dir="${SRC_DIR}/build-release"
cmake_install_dir="${SRC_DIR}/cmake-built-install"
zig_build_dir="${SRC_DIR}/conda-zig-source"

mkdir -p "${zig_build_dir}" && cp -r "${cmake_source_dir}"/* "${zig_build_dir}"
mkdir -p "${cmake_install_dir}" "${ZIG_LOCAL_CACHE_DIR}" "${ZIG_GLOBAL_CACHE_DIR}"
mkdir -p "${SRC_DIR}"/build-level-patches
cp -r "${RECIPE_DIR}"/patches/xxxx* "${SRC_DIR}"/build-level-patches

# --- Common CMake/zig configuration ---
# zig_$build_platform activation sets:
#   CONDA_ZIG_BUILD, CONDA_ZIG_HOST
#   ZIG_CC, ZIG_CXX, ZIG_AR, ZIG_RANLIB, ZIG_ASM, ZIG_RC (wrapper scripts)
zig="$(find "${BUILD_PREFIX}/bin" "${BUILD_PREFIX}/Library/bin" \( -name "${CONDA_ZIG_BUILD}" -o -name "${CONDA_ZIG_BUILD}.exe" -o -name "${CONDA_ZIG_HOST}" -o -name "${CONDA_ZIG_HOST}.exe" \) 2>/dev/null | head -1 || true)"

# Fallback: search for any *-zig binary in PATH
if [[ -z "${zig}" ]]; then
  zig="$(find "${BUILD_PREFIX}/bin" "${BUILD_PREFIX}/Library/bin" -name '*-zig' -o -name '*-zig.exe' 2>/dev/null | head -1 || true)"
fi
# Fallback: conda-forge zig installs a plain `zig` binary (no triplet prefix)
if [[ -z "${zig}" ]]; then
  zig="$(find "${BUILD_PREFIX}/bin" "${BUILD_PREFIX}/Library/bin" \( -name 'zig' -o -name 'zig.exe' \) 2>/dev/null | head -1 || true)"
fi

echo "CONDA_ZIG_BUILD: ${CONDA_ZIG_BUILD:-NOT FOUND}"
echo "CONDA_ZIG_HOST: ${CONDA_ZIG_HOST:-NOT FOUND}"
echo "zig binary: ${zig:-NOT FOUND}"
echo "ZIG_CC: ${ZIG_CC:-NOT SET}"
echo "ZIG_CXX: ${ZIG_CXX:-NOT SET}"
echo "ZIG_AR: ${ZIG_AR:-NOT SET}"
echo "ZIG_RANLIB: ${ZIG_RANLIB:-NOT SET}"

# Self-stage zig-cc wrappers (formerly provided by zig-gcc build dep; now
# using conda-forge zig + self-staging the wrapper scripts from RECIPE_DIR/scripts/).
# Wrappers provide flag filtering and sysroot detection that bare `zig cc` lacks.
if [[ -z "${ZIG_CC:-}" ]] && [[ -n "${zig}" ]]; then
  _wrapper_dir="${BUILD_PREFIX}/share/zig/wrappers"
  mkdir -p "${_wrapper_dir}"

  # Derive cc_target: ZIG_WRAPPER_TRIPLET with glibc version suffix stripped.
  # Mirrors install_zig_activation.py _strip_glibc_version(): removes .X.Y from
  # -gnu* triplets only (e.g. aarch64-linux-gnu.2.17 → aarch64-linux-gnu).
  _cc_target="${ZIG_WRAPPER_TRIPLET}"
  if [[ "${_cc_target}" =~ ^(.*-gnu[a-z]*)\.[0-9]+\.[0-9]+$ ]]; then
    _cc_target="${BASH_REMATCH[1]}"
  fi
  _cc_target_arch="${_cc_target%%-*}"

  # Install shared helper scripts (sourced by wrappers; installed unprefixed)
  for _helper in "_zig-cc-common.sh" "_zig-force-load-common.sh"; do
    _src="${RECIPE_DIR}/scripts/${_helper}"
    [[ -f "${_src}" ]] || continue
    sed -e "s|@ZIG_BIN@|${zig}|g" \
        -e "s|@ZIG_TARGET@|${_cc_target}|g" \
        -e "s|@ZIG_TARGET_ARCH@|${_cc_target_arch}|g" \
        "${_src}" > "${_wrapper_dir}/${_helper}"
  done

  # Install triple-prefixed wrapper scripts (drop .sh extension, add conda triplet prefix)
  # Filename uses CONDA_TRIPLET (e.g. x86_64-conda-linux-gnu) so consumers using the
  # conda prefix convention can find them; @ZIG_TARGET@ inside the script remains _cc_target
  # (the zig -target triplet, e.g. x86_64-linux-gnu) — do NOT conflate the two.
  for _name in zig-cc zig-cxx zig-ar zig-ranlib zig-asm zig-rc zig-lld zig-force-load-cc zig-force-load-cxx; do
    _src="${RECIPE_DIR}/scripts/${_name}.sh"
    [[ -f "${_src}" ]] || continue
    _dst="${_wrapper_dir}/${CONDA_TRIPLET}-${_name}"
    sed -e "s|@ZIG_BIN@|${zig}|g" \
        -e "s|@ZIG_TARGET@|${_cc_target}|g" \
        -e "s|@ZIG_TARGET_ARCH@|${_cc_target_arch}|g" \
        "${_src}" > "${_dst}"
    chmod +x "${_dst}"
  done

  export ZIG_CC="${_wrapper_dir}/${CONDA_TRIPLET}-zig-cc"
  export ZIG_CXX="${_wrapper_dir}/${CONDA_TRIPLET}-zig-cxx"
  export ZIG_AR="${_wrapper_dir}/${CONDA_TRIPLET}-zig-ar"
  export ZIG_RANLIB="${_wrapper_dir}/${CONDA_TRIPLET}-zig-ranlib"
  export ZIG_ASM="${_wrapper_dir}/${CONDA_TRIPLET}-zig-asm"
  export ZIG_RC="${_wrapper_dir}/${CONDA_TRIPLET}-zig-rc"

  echo "Self-staged zig-cc wrappers in ${_wrapper_dir} (conda_triplet=${CONDA_TRIPLET}, zig_target=${_cc_target})"
  echo "ZIG_CC: ${ZIG_CC}"
fi

if [[ -z "${ZIG_CC:-}" ]]; then
  echo "Activation did not set ZIG_CC, using zig binary directly"
  export ZIG_CC="${zig} cc"
  export ZIG_CXX="${zig} c++"
  export ZIG_AR="${zig} ar"
  export ZIG_RANLIB="${zig} ranlib"

  echo "ZIG_CC: ${ZIG_CC:-NOT SET}"
  echo "ZIG_CXX: ${ZIG_CXX:-NOT SET}"
  echo "ZIG_AR: ${ZIG_AR:-NOT SET}"
  echo "ZIG_RANLIB: ${ZIG_RANLIB:-NOT SET}"
fi

export CC="${ZIG_CC}"
export CXX="${ZIG_CXX}"
export AR="${ZIG_AR}"
export RANLIB="${ZIG_RANLIB}"
# CONDA_BUILD_SYSROOT is normally set by compiler("c") activation (gcc/clang).
# Since we use zig as compiler, set it manually from stdlib("c") sysroot.
if is_linux && ! is_riscv64; then
  export CONDA_BUILD_SYSROOT="${BUILD_PREFIX}/${CONDA_TRIPLET}/sysroot"
fi

if is_not_unix; then
  _library="Library/"
else
  _library=""
fi
export ZIG_LLVM_ROOT="${PREFIX}/${_library}lib/zig-llvm"
export PATH="${ZIG_LLVM_ROOT}/bin:${PATH}"
# Search for llvm-config: prefer BUILD_PREFIX (runnable on build machine),
# then zig-llvm. On cross-builds, BUILD_PREFIX layout may differ from target
# (e.g. Linux host has bin/, Windows target has Library/bin/).
_llvm_config_search=(
  "${BUILD_PREFIX}/${_library}bin"       # target layout (native builds)
  "${BUILD_PREFIX}/${_library}lib/zig-llvm/bin"
)
if is_cross; then
  # Host-layout paths (BUILD_PREFIX is host arch, may differ from target layout)
  _llvm_config_search+=("${BUILD_PREFIX}/bin")
fi
# zig-llvm's own wrapper last (may be bash script unusable on Windows)
_llvm_config_search+=("${ZIG_LLVM_ROOT}/bin")
export LLVM_CONFIG=$(find "${_llvm_config_search[@]}" \( -name 'llvm-config.real' -o -name 'llvm-config.real.exe' -o -name 'llvm-config' -o -name 'llvm-config.exe' \) -type f 2>/dev/null | head -1)
echo "LLVM_CONFIG: ${LLVM_CONFIG:-NOT SET}"

# Verify zig-llvm is available
# Ensure llvm-config.real can find libunwind.so.1 and libc++ from zig-llvm runtimes
export LD_LIBRARY_PATH="${ZIG_LLVM_ROOT}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# For cross-builds, llvm-config.real.exe may be the wrong architecture (e.g. ARM64
# on x86_64 host). Detect this and fall back to extracting version from headers.
_llvm_config_works=1
if [[ ! -x "${LLVM_CONFIG}" ]]; then
  # Try the cmake config files as a fallback (they're text, not executables)
  if [[ -f "${ZIG_LLVM_ROOT}/lib/cmake/llvm/LLVMConfig.cmake" ]]; then
    echo "WARNING: llvm-config not executable, but cmake config files found"
    _llvm_config_works=0
  else
    echo "ERROR: zig-llvm llvm-config not found at ${LLVM_CONFIG}"
    echo "  Ensure zig-llvm package is installed"
    exit 1
  fi
fi
# On cross-builds, even if llvm-config exists it may not run (wrong arch)
if [[ ${_llvm_config_works} -eq 1 ]]; then
  _llvm_ver=$(${LLVM_CONFIG} --version 2>/dev/null || true)
  if [[ -z "${_llvm_ver}" ]]; then
    echo "WARNING: llvm-config exists but cannot execute (cross-build?)"
    _llvm_config_works=0
  fi
fi
# Guard: if llvm-config runs but is NOT from zig-llvm, handle it:
# - Native builds: ignore it (force cmake config files from zig-llvm)
# - Cross builds: wrap it to rewrite paths from BUILD_PREFIX → ZIG_LLVM_ROOT
#   The zig-llvm llvm-config can't run (wrong arch), but BUILD_PREFIX's can.
#   We just need its output to point at zig-llvm's libraries instead.
if [[ ${_llvm_config_works} -eq 1 ]] && [[ "${LLVM_CONFIG}" != *"zig-llvm"* ]]; then
  if is_cross && is_not_unix; then
    # Windows: cmake runs via cmd.exe, can't execute bash wrappers.
    # Use BUILD_PREFIX llvm-config.exe directly; paths are fixed in config.h later.
    echo "CROSS-BUILD (Windows): using BUILD_PREFIX llvm-config directly (no wrapper)"
    echo "  LLVM_CONFIG: ${LLVM_CONFIG}"
  elif is_cross; then
    echo "CROSS-BUILD: Wrapping ${LLVM_CONFIG} to redirect paths to zig-llvm"
    _real_llvm_config="${LLVM_CONFIG}"
    # Overwrite zig-llvm's own llvm-config wrapper IN PLACE so CMake's
    # find_program(llvm-config) via PATH also finds our cross wrapper
    # (not just the LLVM_CONFIG env var).
    _wrapper="${ZIG_LLVM_ROOT}/bin/llvm-config"
    cat > "${_wrapper}" << WRAPEOF
#!/usr/bin/env bash
# Cross-build llvm-config wrapper for osx-64 cross from osx-arm64.

# Suppress 'setlocale: LC_ALL: cannot change locale (C.UTF-8)' warnings on
# stderr — Findllvm.cmake captures wrapper stderr and treats non-empty as
# 'shared library not supported'.
export LC_ALL=C

# The "real" llvm-config is conda-forge llvmdev's host-arch binary at
# ${BUILD_PREFIX}/bin/llvm-config — static-only. zig's Findllvm.cmake
# probes shared linkability via:
#   1. llvm-config --libs --link-shared       (precondition; static llvm-config errors)
#   2. llvm-config --shared-mode --link-shared (would return 'shared' if reached)
#   3. llvm-config --shared-mode               (fallback)
# zig-llvm IS built shared (libLLVM.dylib at \${ZIG_LLVM_ROOT}/lib), so we
# answer those queries directly and only delegate the path/version queries
# to the static llvm-config (with --link-shared stripped).

# Per-invocation log so we can see exactly what CMake calls.
{
  echo "[\$(date +%H:%M:%S)] llvm-config-wrapper called: \$*"
} >> "${cmake_build_dir}/llvm-config-wrapper.log" 2>/dev/null || true

# Classify args
_has_shared_mode=0
_has_libs=0
_has_system_libs=0
_has_link_shared=0
_has_link_static=0
for arg in "\$@"; do
  case "\$arg" in
    --shared-mode)  _has_shared_mode=1 ;;
    --libs)         _has_libs=1 ;;
    --system-libs)  _has_system_libs=1 ;;
    --link-shared)  _has_link_shared=1 ;;
    --link-static)  _has_link_static=1 ;;
  esac
done

# Short-circuit: --shared-mode (regardless of --link-shared/static)
if (( _has_shared_mode )); then
  echo "shared"
  exit 0
fi

# Short-circuit: --libs --link-shared → zig-llvm ships libLLVM.dylib as a
# combined shared library; the static llvm-config can't answer this.
if (( _has_libs && _has_link_shared )); then
  echo "-lLLVM"
  exit 0
fi

# Short-circuit: --system-libs --link-shared → no extra system libs needed
# beyond what -lLLVM already pulls; return empty.
if (( _has_system_libs && _has_link_shared )); then
  echo ""
  exit 0
fi

# For all other queries, delegate to the real (static-only) llvm-config
# with --link-shared stripped (it would otherwise error). Strip
# --link-static too if present alongside --link-shared (defensive).
_args=()
for arg in "\$@"; do
  case "\$arg" in
    --link-shared) : ;;  # drop
    *) _args+=("\$arg") ;;
  esac
done

output="\$("${_real_llvm_config}" "\${_args[@]}" 2>&1)" || {
  echo "\$output" >&2
  exit 1
}

# Rewrite BUILD_PREFIX paths → ZIG_LLVM_ROOT
output="\${output//${BUILD_PREFIX//\//\\/}/${ZIG_LLVM_ROOT//\//\\/}}"

# Filter linker flags zig's lld doesn't accept (preserve existing behavior)
for arg in "\$@"; do
  case "\$arg" in
    --ldflags|--system-libs|--libs|--link-static|--link-shared)
      output=\$(echo "\$output" | sed \
        -e 's/-Wl,-Bsymbolic-functions//g' \
        -e 's/-Bsymbolic-functions//g' \
        -e 's/-Wl,-Bsymbolic//g' \
        -e 's/-Bsymbolic//g' \
        -e 's/-Wl,--disable-new-dtags//g' \
        -e 's/  */ /g' -e 's/^ *//' -e 's/ *\$//')
      break ;;
  esac
done

echo "\$output"
WRAPEOF
    chmod +x "${_wrapper}"
    export LLVM_CONFIG="${_wrapper}"
    echo "  Wrapper (in-place): ${_wrapper}"
    echo "  Real:    ${_real_llvm_config}"
    echo "  Rewrite: ${BUILD_PREFIX} → ${ZIG_LLVM_ROOT}"
  else
    echo "WARNING: llvm-config at ${LLVM_CONFIG} is NOT from zig-llvm -ignoring"
    echo "  (conda-forge LLVM is for tblgen only, not for linking)"
    _llvm_config_works=0
  fi
fi
if [[ ${_llvm_config_works} -eq 0 ]]; then
  # Extract version from LLVM headers instead of running llvm-config
  _llvm_ver=$(grep -m1 'LLVM_VERSION_STRING' "${ZIG_LLVM_ROOT}/include/llvm/Config/llvm-config.h" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/' || true)
  if [[ -z "${_llvm_ver}" ]]; then
    echo "ERROR: Cannot determine LLVM version (llvm-config won't run and headers not found)"
    exit 1
  fi
fi
echo "=== Using zig-llvm from ${ZIG_LLVM_ROOT} ==="
echo "  LLVM version: ${_llvm_ver}"

EXTRA_CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_PREFIX_PATH="${ZIG_LLVM_ROOT}"
  -DCMAKE_LIBRARY_PATH="${ZIG_LLVM_ROOT}/lib"
  -DCMAKE_AR="${ZIG_AR//\\//}"
  -DCMAKE_C_COMPILER="${ZIG_CC//\\//}"
  -DCMAKE_CXX_COMPILER="${ZIG_CXX//\\//}"
  -DCMAKE_RANLIB="${ZIG_RANLIB//\\//}"
  -DZIG_SHARED_LLVM=ON
  -DZIG_SYSTEM_LIBCXX=c++
  -DZIG_TARGET_MCPU=baseline
  -DZIG_TARGET_TRIPLE=${ZIG_TRIPLET}
)

# Remember: CPU MUST be baseline, otherwise it create non-portable zig code (optimized for a given hardware)
EXTRA_ZIG_ARGS=(
  --search-prefix "${ZIG_LLVM_ROOT}"
  --search-prefix "${PREFIX}"
  -fallow-so-scripts
  -Dconfig_h="${cmake_build_dir}"/config.h
  -Dcpu=baseline
  -Denable-llvm
  -Doptimize=ReleaseSafe
  -Dstatic-llvm=false
  -Dstrip=true
  -Dtarget=${ZIG_TRIPLET}
  -Duse-zig-libcxx=false
)

# --- Platform Configuration ---

if is_osx; then
  # Determine correct macOS arch from target (not host) to prevent CMake
  # from injecting -arch for the build machine when cross-compiling
  _osx_arch="arm64"
  [[ "${cross_target_platform_}" == "osx-64" ]] && _osx_arch="x86_64"
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SYSTEM_LIBCXX=c++
    -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
    -DCMAKE_OSX_ARCHITECTURES="${_osx_arch}"
    # cmake fallback for zig2 link: zig's paths_first linker only searches the
    # -L paths cmake adds; CMAKE_LIBRARY_PATH covers ZIG_LLVM_ROOT/lib but not
    # $PREFIX/lib where libz/libzstd/libxml2 from conda-forge live.
    -DCMAKE_EXE_LINKER_FLAGS="-L${PREFIX}/lib"
  )

  # Cross-builds: zig_$cross_target_platform_ activation provides wrappers
  # targeting the host platform (e.g. x86_64 for osx-64). No custom wrappers needed.
fi

# Override zig's default max_rss (7.8GB) which exceeds CI runner memory
if [[ "${target_platform}" == osx-* ]]; then
  # macos-14 runner has ~14 GB RAM; 7.5 GB is the proven-working value for
  # zig 0.15.2 ReleaseSafe (the compile-exe-zig step declares a 7 GB internal
  # upper bound, so anything below 7 GB triggers a build-runner assert panic).
  EXTRA_ZIG_ARGS+=(--maxrss 7500000000)
else
  EXTRA_ZIG_ARGS+=(--maxrss 7500000000)
fi


# zig-llvm builds a monolithic shared library on all platforms.
# ZIG_USE_LLVM_CONFIG=ON is mandatory -the OFF path in Findllvm.cmake only
# searches for ~191 individual static libs and doesn't support shared LLVM.
EXTRA_CMAKE_ARGS+=(-DZIG_SHARED_LLVM=ON -DZIG_USE_LLVM_CONFIG=ON)
if [[ ${_llvm_config_works} -ne 1 ]]; then
  echo "ERROR: llvm-config is required (zig-llvm uses shared LLVM) but no working llvm-config found"
  echo "  LLVM_CONFIG=${LLVM_CONFIG:-NOT SET}"
  echo "  Ensure BUILD_PREFIX has llvm-tools or zig-llvm has a runnable llvm-config"
  exit 1
fi

# Exclude BUILD_PREFIX and system LLVM paths from cmake search.
# On cross-builds, BUILD_PREFIX contains host-arch (e.g. x64) LLVM libs that
# cmake must not link into the target-arch binary -even when llvm-config works,
# cmake's find_library() can still find stray libs in BUILD_PREFIX.
_ignore_paths="/opt/homebrew/lib;/usr/local/lib"
[[ -d "${BUILD_PREFIX}/lib" ]] && _ignore_paths="${_ignore_paths};${BUILD_PREFIX}/lib"
[[ -d "${BUILD_PREFIX}/${_library}lib" ]] && _ignore_paths="${_ignore_paths};${BUILD_PREFIX}/${_library}lib"
# Also block bin/ so cmake's find_program() doesn't find BUILD_PREFIX's llvm-config
[[ -d "${BUILD_PREFIX}/bin" ]] && _ignore_paths="${_ignore_paths};${BUILD_PREFIX}/bin"
[[ -d "${BUILD_PREFIX}/${_library}bin" ]] && _ignore_paths="${_ignore_paths};${BUILD_PREFIX}/${_library}bin"
EXTRA_CMAKE_ARGS+=(-DCMAKE_IGNORE_PATH="${_ignore_paths}")


if is_linux && is_cross; then
  if is_riscv64; then
    EXTRA_ZIG_ARGS+=(-fqemu)
  else
    EXTRA_ZIG_ARGS+=(
      -fqemu
      --libc "${zig_build_dir}"/libc_file
      --libc-runtimes "${CONDA_BUILD_SYSROOT}/lib64"
    )
  fi
fi

# riscv64/s390x: conda-forge does not ship zlib/zstd/libxml2 for these arches.
# Instead, custom zig-zlib/zig-zstd/zig-libxml2 outputs install shared libs under
# $PREFIX/lib/zig-{zlib,zstd,xml2}/lib/. Zig's paths_first library search uses
# --search-prefix roots, so add these subdirs explicitly so -lz/-lzstd/-lxml2 resolve.
if [[ "${target_platform}" == "linux-riscv64" || "${target_platform}" == "linux-s390x" ]]; then
  for _zigpkg in zig-zlib zig-zstd zig-xml2; do
    _zigpkg_dir="${PREFIX}/lib/${_zigpkg}"
    if [[ -d "${_zigpkg_dir}" ]]; then
      EXTRA_ZIG_ARGS+=(--search-prefix "${_zigpkg_dir}")
      echo "  riscv64/s390x: added --search-prefix ${_zigpkg_dir}"
    fi
  done
  unset _zigpkg _zigpkg_dir
fi

# --- libzigcpp Configuration ---

if is_linux; then
  is_cross && is_osx && ${INSTALL_NAME_TOOL:-install_name_tool} -add_rpath "${BUILD_PREFIX}"/lib "${PREFIX}"/bin/llvm-config
fi

mkdir -p "${PREFIX}/${_library}bin"
rm -f "${PREFIX}/${_library}bin"/llvm-config*
if is_not_unix; then
  # On Windows: remove bash wrapper, restore real exe for native builds.
  # For cross-builds, remove ALL llvm-config from ZIG_LLVM_ROOT/bin so cmake's
  # find_program doesn't find the wrong-arch exe. BUILD_PREFIX llvm-config is
  # used directly via -DLLVM_CONFIG.
  rm -f "${ZIG_LLVM_ROOT}/bin/llvm-config"
  if is_cross; then
    # Remove wrong-arch binaries, copy native BUILD_PREFIX llvm-config so
    # cmake's find_program (which searches ZIG_LLVM_ROOT via CMAKE_PREFIX_PATH)
    # finds a runnable one.
    rm -f "${ZIG_LLVM_ROOT}/bin/llvm-config.exe" "${ZIG_LLVM_ROOT}/bin/llvm-config.real.exe"
    cp "${LLVM_CONFIG}" "${ZIG_LLVM_ROOT}/bin/llvm-config.exe"
    echo "  Copied native llvm-config to ${ZIG_LLVM_ROOT}/bin/ for cmake"

    # This copied binary is conda-forge llvmdev's static-only native-arch
    # llvm-config - it cannot answer --link-shared queries for zig-llvm's
    # actual (shared) target build, so Findllvm.cmake's runtime probe of
    # it fails with "does not support linking as a shared library". Compute
    # the values manually instead (mirrors the answer the --link-shared
    # bash wrapper above gives on unix cross builds) and hand them to
    # Findllvm.cmake's override branch via the cmake cache-seed below.
    _zig_llvm_implib="$(find "${ZIG_LLVM_ROOT}/lib" -maxdepth 1 \( -iname 'libLLVM*.dll.a' -o -iname 'LLVM*.dll.a' \) 2>/dev/null | head -1)"
    if [[ -z "${_zig_llvm_implib}" ]]; then
      echo "ERROR: could not find zig-llvm's shared-library import lib under ${ZIG_LLVM_ROOT}/lib"
      exit 1
    fi
    export ZIG_LLVM_MANUAL_OVERRIDE=1
    export ZIG_LLVM_MANUAL_LIBRARIES="${_zig_llvm_implib}"
    export ZIG_LLVM_MANUAL_LIBDIRS="${ZIG_LLVM_ROOT}/lib"
    export ZIG_LLVM_MANUAL_INCLUDE_DIRS="${ZIG_LLVM_ROOT}/include"
    echo "  ZIG_LLVM_MANUAL_LIBRARIES: ${ZIG_LLVM_MANUAL_LIBRARIES}"
  elif [[ -f "${ZIG_LLVM_ROOT}/bin/llvm-config.real.exe" ]]; then
    cp "${ZIG_LLVM_ROOT}/bin/llvm-config.real.exe" "${ZIG_LLVM_ROOT}/bin/llvm-config.exe"
  fi
else
  cp "${ZIG_LLVM_ROOT}"/bin/llvm-config* "${PREFIX}/${_library}bin/"
fi

# On Windows, CMake detects zig-cc as ClangCL and injects MSVC-style linker flags
# (/MANIFEST:EMBED, /subsystem:console, -fuse-ld=lld-link) that zig doesn't support.
# Tell CMake this is GNU-style Clang (not MSVC) and set the correct system.
if is_not_unix; then
  # On Windows, zig-cc is detected as Clang but CMake's compiler test fails
  # because zig doesn't support MSVC-style linker args (/MANIFEST:EMBED etc).
  # Pre-seed the cmake cache so CMake skips the compiler test entirely.
  _cache_seed="${SRC_DIR}/zig-cmake-cache.cmake"
  _zig_cc_cmake="${ZIG_CC//\\//}"
  _zig_cxx_cmake="${ZIG_CXX//\\//}"
  _zig_ar_cmake="${ZIG_AR//\\//}"
  _zig_ranlib_cmake="${ZIG_RANLIB//\\//}"
  cat > "${_cache_seed}" << TCEOF
# Pre-seed compiler identification so CMake skips the test program
set(CMAKE_C_COMPILER "${_zig_cc_cmake}" CACHE FILEPATH "")
set(CMAKE_CXX_COMPILER "${_zig_cxx_cmake}" CACHE FILEPATH "")
set(CMAKE_AR "${_zig_ar_cmake}" CACHE FILEPATH "")
set(CMAKE_RANLIB "${_zig_ranlib_cmake}" CACHE FILEPATH "")
set(CMAKE_C_COMPILER_ID "Clang" CACHE STRING "")
set(CMAKE_CXX_COMPILER_ID "Clang" CACHE STRING "")
set(CMAKE_C_COMPILER_VERSION "${_llvm_ver}" CACHE STRING "")
set(CMAKE_CXX_COMPILER_VERSION "${_llvm_ver}" CACHE STRING "")
set(CMAKE_C_COMPILER_WORKS TRUE CACHE BOOL "")
set(CMAKE_CXX_COMPILER_WORKS TRUE CACHE BOOL "")
set(CMAKE_C_ABI_COMPILED TRUE CACHE BOOL "")
set(CMAKE_CXX_ABI_COMPILED TRUE CACHE BOOL "")
set(CMAKE_C_STANDARD_COMPUTED_DEFAULT "11" CACHE STRING "")
set(CMAKE_CXX_STANDARD_COMPUTED_DEFAULT "14" CACHE STRING "")
set(CMAKE_CXX_COMPILE_FEATURES "cxx_std_14;cxx_std_17;cxx_std_20" CACHE STRING "")
set(CMAKE_C_COMPILE_FEATURES "c_std_11;c_std_17" CACHE STRING "")
# Standard flag mappings for target_compile_features
set(CMAKE_CXX14_STANDARD_COMPILE_OPTION "-std=c++14" CACHE STRING "")
set(CMAKE_CXX17_STANDARD_COMPILE_OPTION "-std=c++17" CACHE STRING "")
set(CMAKE_CXX20_STANDARD_COMPILE_OPTION "-std=c++20" CACHE STRING "")
set(CMAKE_C11_STANDARD_COMPILE_OPTION "-std=c11" CACHE STRING "")
set(CMAKE_C17_STANDARD_COMPILE_OPTION "-std=c17" CACHE STRING "")
set(CMAKE_CXX14_EXTENSION_COMPILE_OPTION "-std=gnu++14" CACHE STRING "")
set(CMAKE_CXX17_EXTENSION_COMPILE_OPTION "-std=gnu++17" CACHE STRING "")
set(CMAKE_CXX20_EXTENSION_COMPILE_OPTION "-std=gnu++20" CACHE STRING "")
# Force zig-cc to target windows-gnu (not native windows-msvc).
# Without this, zig-cc defaults to native target which defines _MSC_VER,
# causing zig.h to use MSVC intrinsics (_InterlockedOr64 etc.) that
# aren't available in zig-cc's Clang frontend.
set(CMAKE_C_FLAGS "-target ${ZIG_TRIPLET}" CACHE STRING "")
set(CMAKE_CXX_FLAGS "-target ${ZIG_TRIPLET}" CACHE STRING "")
# Pin llvm-config so cmake doesn't find BUILD_PREFIX's conda-forge copy
set(LLVM_CONFIG "${LLVM_CONFIG//\\//}" CACHE FILEPATH "")
TCEOF
  if [[ -n "${ZIG_LLVM_MANUAL_OVERRIDE:-}" ]]; then
    # Windows cross-build: bypass Findllvm.cmake's llvm-config --link-shared
    # probe entirely (see cmake/Findllvm.cmake patch) since the only
    # runnable llvm-config on the build machine can't answer it for
    # zig-llvm's actual build.
    cat >> "${_cache_seed}" << OVEOF
set(ZIG_LLVM_MANUAL_OVERRIDE ON CACHE BOOL "")
set(ZIG_LLVM_MANUAL_LIBRARIES "${ZIG_LLVM_MANUAL_LIBRARIES//\\//}" CACHE STRING "")
set(ZIG_LLVM_MANUAL_LIBDIRS "${ZIG_LLVM_MANUAL_LIBDIRS//\\//}" CACHE STRING "")
set(ZIG_LLVM_MANUAL_INCLUDE_DIRS "${ZIG_LLVM_MANUAL_INCLUDE_DIRS//\\//}" CACHE STRING "")
OVEOF
  fi
  EXTRA_CMAKE_ARGS+=(-C "${_cache_seed}")
fi

# Findllvm.cmake: find_program searches CMAKE_PREFIX_PATH (which includes
# ZIG_LLVM_ROOT) and hardcoded MSYS2 paths. For cross-builds, we copied
# the native llvm-config.exe into ZIG_LLVM_ROOT/bin above so it's found.


_cmake_configure_rc=0
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}" || _cmake_configure_rc=$?

# Dump llvm-config wrapper invocation log so we can see what CMake actually called.
# Gated to cross-unix builds where the wrapper exists.
if [[ ${_cmake_configure_rc} -ne 0 ]]; then
  exit ${_cmake_configure_rc}
fi

rm -f "${PREFIX}/${_library}bin"/llvm-config*

# --- Post CMake Configuration ---

# Replace individual liblld*.a archive paths in ZIG_LLVM_LIBRARIES with the
# single liblldZig bundle produced by zig-llvm's build_lld_bundle step.
# cmake's LLDConfig.cmake populates ZIG_LLVM_LIBRARIES with absolute paths to
# each of the six lld archives.  We substitute them all with the bundle path.
# Add zig-llvm's bundled libc++ to ensure same C++ stdlib is used
if is_linux; then
  _lld_lib="${PREFIX}/lib/zig-llvm/lib"
  if [[ "${target_platform}" == "linux-riscv64" || "${target_platform}" == "linux-s390x" ]]; then
    # liblldZig.so is not built on these platforms; link the 6 lld static archives
    # directly without --whole-archive.
    # --whole-archive is intentionally omitted: zig's build.zig passes ZIG_LLVM_LIBRARIES
    # tokens via addLinkArgs (direct ELF-linker args, not through the CC driver), so
    # -Wl,--whole-archive reaches zig's self-hosted ELF linker as a literal flag which
    # it does not recognise ("unrecognized parameter: '-Wl,--whole-archive'").  Symbol
    # inclusion is safe without the flag because zig's build.zig explicitly references
    # all lld driver entry points, so the ELF linker pulls them from the archives.
    #
    # Use absolute paths for libz/libzstd/libxml2 instead of bare -l flags.
    # riscv64/s390x use custom outputs that install shared libs under subdirs:
    #   $PREFIX/lib/zig-zstd/lib/libzstd.so
    #   $PREFIX/lib/zig-xml2/lib/libxml2.so
    #   $PREFIX/lib/zig-zlib/lib/libz.so
    # (conda-forge top-level $PREFIX/lib/libz.so etc. do not exist on these arches.)
    _lld_static_tokens=""
    for _a in liblldELF.a liblldCOFF.a liblldMachO.a liblldWasm.a liblldMinGW.a liblldCommon.a; do
      _lld_static_tokens="${_lld_static_tokens:+${_lld_static_tokens};}${_lld_lib}/${_a}"
    done
    _lld_static_tokens="${_lld_static_tokens};${PREFIX}/lib/zig-zstd/lib/libzstd.so;${PREFIX}/lib/zig-xml2/lib/libxml2.so;${PREFIX}/lib/zig-zlib/lib/libz.so;-lpthread;-L${PREFIX}/lib/zig-zlib/lib;-L${PREFIX}/lib/zig-zstd/lib;-L${PREFIX}/lib/zig-xml2/lib;-L${_lld_lib};-lc++;-lc++abi;-lunwind"
    # Remove all six individual liblld*.a references (cmake wrote them with full paths);
    # then append the static-archive token list.
    perl -pi -e "s@[^;\"]*liblld(?:ELF|COFF|MachO|Wasm|MinGW|Common)\.a@@g" "${cmake_build_dir}"/config.h
    # Collapse duplicate semicolons left by the removal, then append the token list.
    perl -pi -e "s@;{2,}@;@g; s@(ZIG_LLVM_LIBRARIES \")([^\"]*);\"@\${1}\${2}\"@" "${cmake_build_dir}"/config.h
    perl -pi -e "s@(ZIG_LLVM_LIBRARIES \")(.*)\"@\$1\$2;${_lld_static_tokens}\"@" "${cmake_build_dir}"/config.h
  else
    _lld_bundle_path="${_lld_lib}/liblldZig.so"
    # Remove all six individual liblld*.a references; then append the bundle path.
    perl -pi -e "s@[^;\"]*liblld(?:ELF|COFF|MachO|Wasm|MinGW|Common)\.a@@g" "${cmake_build_dir}"/config.h
    # Collapse duplicate semicolons left by the removal, then append the bundle.
    perl -pi -e "s@;{2,}@;@g; s@(ZIG_LLVM_LIBRARIES \")([^\"]*);\"@\${1}\${2}\"@" "${cmake_build_dir}"/config.h
    perl -pi -e "s@(ZIG_LLVM_LIBRARIES \")(.*)\"@\$1\$2;${_lld_bundle_path};-lzstd;-lxml2;-lz;-L${_lld_lib};-lc++;-lc++abi;-lunwind\"@" "${cmake_build_dir}"/config.h
  fi
elif is_osx; then
  _lld_bundle_path="${PREFIX}/lib/zig-llvm/lib/liblldZig.dylib"
  perl -pi -e "s@[^;\"]*liblld(?:ELF|COFF|MachO|Wasm|MinGW|Common)\.a@@g" "${cmake_build_dir}"/config.h
  perl -pi -e "s@;{2,}@;@g; s@(ZIG_LLVM_LIBRARIES \")([^\"]*);\"@\${1}\${2}\"@" "${cmake_build_dir}"/config.h
  perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${_lld_bundle_path};-lzstd;-lxml2;-lz;-L${PREFIX}/lib/zig-llvm/lib;${PREFIX}/lib/zig-llvm/lib/libc++.dylib\"@" "${cmake_build_dir}"/config.h
elif is_not_unix; then
  # cmake finds libLLVM-20.dll in bin/ and records "zig-llvm/bin/libLLVM-20" (no
  # extension). Zig needs the import lib in lib/ with proper extension. Fix the
  # path and add libc++ + dependencies.
  _zig_llvm_lib="${ZIG_LLVM_ROOT//\\//}/lib"
  _lld_bundle_path="${_zig_llvm_lib}/liblldZig.dll.a"
  echo "=== Windows config.h patching ==="
  echo "  BEFORE ZIG_LLVM_LIBRARIES:"
  grep 'ZIG_LLVM_LIBRARIES' "${cmake_build_dir}"/config.h | head -1
  # bin/libLLVM-20 → lib/libLLVM-20.dll.a (handle both / and \ separators)
  perl -pi -e 's@zig-llvm[/\\\\]bin[/\\\\](libLLVM-\d+)@zig-llvm/lib/$1.dll.a@g' "${cmake_build_dir}"/config.h
  # Replace individual lld archives with the single bundle import lib.
  perl -pi -e "s@[^;\"]*liblld(?:ELF|COFF|MachO|Wasm|MinGW|Common)\.(?:a|dll\.a)@@g" "${cmake_build_dir}"/config.h
  perl -pi -e "s@;{2,}@;@g; s@(ZIG_LLVM_LIBRARIES \")([^\"]*);\"@\${1}\${2}\"@" "${cmake_build_dir}"/config.h
  perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${_lld_bundle_path};-lzstd;-lxml2;-lz;-L${_zig_llvm_lib};-lc++\"@" "${cmake_build_dir}"/config.h
fi

# Create a C++ compiler wrapper that responds to -print-file-name queries.
# zig c++ doesn't support -print-file-name, so addCxxKnownPath in build.zig
# falls back to mod.link_libcpp=true (zig's bundled static hidden-vis libc++).
# This wrapper intercepts -print-file-name=libc++.so and returns the real path
# to zig-llvm's shared libc++, so zig links against it dynamically -giving all
# DSOs the same generic_category() singleton address.
# Create a C++ compiler wrapper that responds to -print-file-name queries.
# zig c++ doesn't support -print-file-name, so addCxxKnownPath in build.zig
# falls back to link_libcpp=true (zig's bundled static hidden-vis libc++).
# This wrapper intercepts those queries and returns zig-llvm's shared libc++.
# On Windows, cmake runs via cmd.exe so bash wrappers don't work; Windows
# relies on the libcxx_shared.zig probe (Lld.zig-prefer-shared-libcxx.patch)
# with libc++ files copied to BUILD_PREFIX above.
if is_unix; then
  mkdir -p "${SRC_DIR}/build-wrappers"
  _cxx_wrapper="${SRC_DIR}/build-wrappers/zig-cxx-print"
  if is_linux; then
    _libcxx_shared="${PREFIX}/lib/zig-llvm/lib/libc++.so"
    _libcxx_static="${PREFIX}/lib/zig-llvm/lib/libc++.a"
  else
    _libcxx_shared="${PREFIX}/lib/zig-llvm/lib/libc++.dylib"
    _libcxx_static="${PREFIX}/lib/zig-llvm/lib/libc++.a"
  fi
  cat > "${_cxx_wrapper}" << CXXEOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    -print-file-name=libc++.so|-print-file-name=libc++.dylib)
      echo "${_libcxx_shared}"
      exit 0 ;;
    -print-file-name=libc++.a)
      echo "${_libcxx_static}"
      exit 0 ;;
    -print-file-name=*)
      echo "\${arg#-print-file-name=}"
      exit 0 ;;
  esac
done
exec "${zig}" c++ "\$@"
CXXEOF
  chmod +x "${_cxx_wrapper}"
  perl -pi -e "s@(ZIG_CXX_COMPILER \").*\"@\$1${_cxx_wrapper}\"@" "${cmake_build_dir}"/config.h
  echo "Patched ZIG_CXX_COMPILER in config.h to use -print-file-name wrapper"
fi

is_debug && echo "=== DEBUG ===" && cat "${cmake_build_dir}"/config.h && echo "=== DEBUG ==="

if is_linux && is_cross; then
  source "${RECIPE_DIR}/build_scripts/_cross.sh"
  source "${RECIPE_DIR}/build_scripts/_atfork.sh"
  source "${RECIPE_DIR}/build_scripts/_sysroot_fix.sh"
  fix_sysroot_libc_scripts "${BUILD_PREFIX}"

  if ! is_riscv64; then
    create_zig_linux_libc_file "${zig_build_dir}/libc_file"
  fi

  remove_failing_langref "${zig_build_dir}"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"
  create_pthread_atfork_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}" "${ZIG_TRIPLET}" "${zig}"
  # __libc_single_threaded stub for glibc < 2.32 (GCC 15 libstdc++ references it)
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/libc_single_threaded_stub.o\"|g" "${cmake_build_dir}/config.h"
  create_libc_single_threaded_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}" "${ZIG_TRIPLET}" "${zig}"
fi

# Workaround for ziglang/zig#14919: add synchronization.def so zig can generate
# libsynchronization.a when cross-compiling to Windows (e.g. OCaml BYTECCLIBS uses -lsynchronization).
# IMPORTANT: LIBRARY must be api-ms-win-core-synch-l1-2-0.dll, NOT synchronization.dll.
# "synchronization.dll" is neither a real DLL on disk nor a valid API Set Schema name — it doesn't
# exist as a physical file in Windows or MSYS2. The real MinGW-w64 alias points to
# libapi-ms-win-core-synch-l1-2-0.a, whose LIBRARY directive is api-ms-win-core-synch-l1-2-0.dll.
# Windows API Set Schema resolves api-ms-win-* names to the actual host DLL at runtime.
if is_not_unix; then
  _zig_lib="${PREFIX}/Library/lib/zig"
  _mingw_common="${_zig_lib}/libc/mingw/lib-common"
else
  _zig_lib="${PREFIX}/lib/zig"
  _mingw_common="${_zig_lib}/libc/mingw/lib-common"
fi
if [[ -d "${_mingw_common}" ]]; then
  cat > "${_mingw_common}/synchronization.def" << 'SYNCHRONIZATION_DEF'
LIBRARY api-ms-win-core-synch-l1-2-0.dll

EXPORTS

DeleteSynchronizationBarrier
EnterSynchronizationBarrier
InitializeConditionVariable
InitializeSynchronizationBarrier
InitOnceBeginInitialize
InitOnceComplete
InitOnceExecuteOnce
InitOnceInitialize
SignalObjectAndWait
Sleep
SleepConditionVariableCS
SleepConditionVariableSRW
WaitOnAddress
WakeAllConditionVariable
WakeByAddressAll
WakeByAddressSingle
WakeConditionVariable
SYNCHRONIZATION_DEF
fi

# Pre-generate Windows PE import libraries (.a) from zig's MinGW .def/.def.in files.
# flexlink (OCaml's Windows linker) calls -print-search-dirs to find library
# search paths, then looks for libXXX.a files at those paths.  zig generates
# import libs internally at link time (cached in ~/.cache/zig/), but flexlink
# needs them at a fixed, known location.
#
# Two types of source files exist in lib-common/:
#   .def     — ready to use directly with dlltool (e.g. shlwapi.def)
#   .def.in  — C preprocessor templates that conditionally include exports by
#              architecture using macros from def-include/func.def.in
#              (e.g. kernel32.def.in, ws2_32.def.in, ole32.def.in)
#
# uuid is special: compiled from libsrc/uuid.c (no DLL import lib needed).
# Only generates files that are missing; safe to re-run.
#
# Target arch detection for dlltool machine type and zig cc -target.
# ZIG_TRIPLET is e.g. "x86_64-windows-gnu" or "aarch64-windows-gnu".
_win_arch="${ZIG_TRIPLET%%-*}"
case "${_win_arch}" in
  x86_64)       _dlltool_machine="i386:x86-64"; _win_target="x86_64-windows-gnu" ;;
  aarch64)      _dlltool_machine="arm64";        _win_target="aarch64-windows-gnu" ;;
  *)            _dlltool_machine="i386:x86-64"; _win_target="x86_64-windows-gnu"
                echo "WARN: unknown Windows arch '${_win_arch}', defaulting to x86_64" ;;
esac
if [[ -d "${_mingw_common}" ]]; then
  # Use the resolved zig binary (full path already set in ${zig}).
  _def_include="${_mingw_common}/../def-include"
  _mingw_libsrc="${_mingw_common}/../libsrc"

  _dlltool=""
  for _cand in \
      "${BUILD_PREFIX}/bin/llvm-dlltool" \
      "${BUILD_PREFIX}/bin/llvm-dlltool.exe" \
      "${BUILD_PREFIX}/Library/bin/llvm-dlltool.exe" \
      "${BUILD_PREFIX}/Library/bin/llvm-dlltool" \
      "$(command -v llvm-dlltool 2>/dev/null || true)"; do
    if [[ -x "${_cand}" ]]; then
      _dlltool="${_cand}"
      break
    fi
  done

  is_debug && echo "=== MinGW import lib generation: zig=${zig} dlltool=${_dlltool:-not found} ==="
  if [[ -n "${_dlltool}" ]] && [[ -x "${zig}" ]]; then
    is_debug && echo "=== Generating MinGW import libs (dlltool=${_dlltool}) ==="
    _gen_count=0

    # Helper: generate .a from a processed .def file
    _gen_implib() {
      local stem="$1" def="$2"
      local lib="${_mingw_common}/lib${stem}.a"
      [[ -f "${lib}" ]] && return 0
      local dll
      dll="$(awk '/^LIBRARY/{gsub(/"/, "", $2); print $2; exit}' "${def}")"
      [[ -z "${dll}" ]] && dll="${stem}.dll"
      "${_dlltool}" -m "${_dlltool_machine}" -D "${dll}" -d "${def}" -l "${lib}" 2>/dev/null || true
      _gen_count=$(( _gen_count + 1 ))
    }

    # Step 1: plain .def files (shlwapi.def, version.def, synchronization.def, etc.)
    for _def in "${_mingw_common}"/*.def; do
      [[ -f "${_def}" ]] || continue
      _stem="$(basename "${_def%.def}")"
      _gen_implib "${_stem}" "${_def}"
    done

    # Step 2: .def.in template files (ws2_32, kernel32, ole32, advapi32, user32, ...)
    # Process through zig's C preprocessor with x86_64 defines so architecture
    # macros (F_X64, F_I386, F64, F32, etc.) expand correctly.
    for _def_in in "${_mingw_common}"/*.def.in; do
      [[ -f "${_def_in}" ]] || continue
      _stem="$(basename "${_def_in%.def.in}")"
      _lib="${_mingw_common}/lib${_stem}.a"
      [[ -f "${_lib}" ]] && continue
      _def="${_mingw_common}/${_stem}.def"
      if [[ ! -f "${_def}" ]]; then
        "${zig}" cc -E -P \
          -target "${_win_target}" \
          -x assembler-with-cpp \
          -I"${_def_include}" \
          "${_def_in}" 2>/dev/null > "${_def}" || { rm -f "${_def}"; continue; }
      fi
      _gen_implib "${_stem}" "${_def}"
    done

    # Step 3: uuid — compiled from C source (no DLL, no import lib needed).
    # zig compiles libsrc/uuid.c into a static archive.
    _uuid_lib="${_mingw_common}/libuuid.a"
    _uuid_src="${_mingw_libsrc}/uuid.c"
    if [[ ! -f "${_uuid_lib}" ]] && [[ -f "${_uuid_src}" ]]; then
      _uuid_obj="${_mingw_common}/_uuid.o"
      "${zig}" cc -target "${_win_target}" -c "${_uuid_src}" \
          -o "${_uuid_obj}" 2>/dev/null && \
        "${zig}" ar rcs "${_uuid_lib}" "${_uuid_obj}" 2>/dev/null || true
      rm -f "${_uuid_obj}"
      _gen_count=$(( _gen_count + 1 ))
    fi

    is_debug && echo "=== Generated ${_gen_count} import libs in ${_mingw_common} ==="

    # Step 4: Supplemental import libs from mingw-w64 .def.in templates.
    # Zig doesn't ship msvcrt.def or ucrtbase.def -- we provide complete
    # mingw-w64 versions that cover all exports (stdio, math, POSIX I/O, etc.).
    # These use #include "func.def.in" for arch macros, so -I must point to
    # our mingw-defs/ directory (NOT zig's def-include/).
    _supp_defs="${RECIPE_DIR}/building/mingw-defs"
    if [[ -d "${_supp_defs}" ]]; then
      is_debug && echo "=== Processing supplemental mingw-w64 .def.in templates ==="
      for _supp_in in "${_supp_defs}"/*.def.in; do
        [[ -f "${_supp_in}" ]] || continue
        _supp_stem="$(basename "${_supp_in%.def.in}")"
        # Skip support files (included by other .def.in, not standalone libs)
        case "${_supp_stem}" in
          func|ucrtbase-common|crt-aliases) continue ;;
        esac
        _supp_lib="${_mingw_common}/lib${_supp_stem}.a"
        [[ -f "${_supp_lib}" ]] && continue
        _supp_def="${_mingw_common}/${_supp_stem}.def"
        if [[ ! -f "${_supp_def}" ]]; then
          "${zig}" cc -E -P \
            -target "${_win_target}" \
            -x assembler-with-cpp \
            -I"${_supp_defs}" \
            "${_supp_in}" 2>/dev/null > "${_supp_def}" || { rm -f "${_supp_def}"; continue; }
        fi
        _gen_implib "${_supp_stem}" "${_supp_def}"
      done
      # Also process plain .def files (no preprocessing needed)
      for _supp_def in "${_supp_defs}"/*.def; do
        [[ -f "${_supp_def}" ]] || continue
        _supp_stem="$(basename "${_supp_def%.def}")"
        _supp_lib="${_mingw_common}/lib${_supp_stem}.a"
        [[ -f "${_supp_lib}" ]] && continue
        _gen_implib "${_supp_stem}" "${_supp_def}"
      done
      is_debug && echo "=== Supplemental import libs done (total ${_gen_count}) ==="
    fi

    # Step 5: ARM64 intrinsic stubs (only for aarch64-windows-gnu).
    # ___chkstk_ms (3 underscores on ARM64) -- stack probe called by MSVC ABI.
    # __intrinsic_setjmpex -- setjmp variant used by MSVC exception handling.
    # These are tiny asm/C stubs compiled into .o files in lib-common/.
    if [[ "${_win_arch}" == "aarch64" ]]; then
      is_debug && echo "=== Compiling ARM64 intrinsic stubs ==="

      # ___chkstk_ms: ARM64 uses 3 underscores (not 2 like x86_64)
      _chkstk_obj="${_mingw_common}/___chkstk_ms.o"
      if [[ ! -f "${_chkstk_obj}" ]]; then
        cat > "${_mingw_common}/_chkstk_ms_arm64.S" << 'CHKSTK_EOF'
// ARM64 ___chkstk_ms stub -- probes stack pages for guard page support.
// On ARM64, the ABI uses 3 underscores. This minimal stub just returns
// (no-op probe), which is safe when stack size < guard page distance.
    .text
    .globl ___chkstk_ms
    .def ___chkstk_ms; .scl 2; .type 32; .endef
___chkstk_ms:
    ret
CHKSTK_EOF
        "${zig}" cc -target "${_win_target}" -c \
          "${_mingw_common}/_chkstk_ms_arm64.S" \
          -o "${_chkstk_obj}" 2>/dev/null || true
        rm -f "${_mingw_common}/_chkstk_ms_arm64.S"
        is_debug && echo "=== Compiled ___chkstk_ms stub ==="
      fi

      # __intrinsic_setjmpex: setjmp variant for structured exception handling
      _setjmpex_obj="${_mingw_common}/__intrinsic_setjmpex.o"
      if [[ ! -f "${_setjmpex_obj}" ]]; then
        cat > "${_mingw_common}/_setjmpex_arm64.c" << 'SETJMPEX_EOF'
// Weak stub for __intrinsic_setjmpex on ARM64.
// Real implementation is in the CRT; this provides a link-time fallback.
typedef void *jmp_buf[32];
__attribute__((weak))
int __intrinsic_setjmpex(jmp_buf env, void *frame) {
    (void)env;
    (void)frame;
    return 0;
}
SETJMPEX_EOF
        "${zig}" cc -target "${_win_target}" -c \
          "${_mingw_common}/_setjmpex_arm64.c" \
          -o "${_setjmpex_obj}" 2>/dev/null || true
        rm -f "${_mingw_common}/_setjmpex_arm64.c"
        is_debug && echo "=== Compiled __intrinsic_setjmpex stub ==="
      fi

      # _fpreset: ARM64 has no x87 FPU — _fpreset is a no-op. The MinGW CRT
      # objects (crt2.obj, libmingw32.lib) call _fpreset via BL instruction
      # (IMAGE_REL_ARM64_BRANCH26), but lld-link cannot auto-import through
      # branch relocations on ARM64. This static stub satisfies the symbol
      # at link time without dllimport. Expected fix in zig 0.15.x/0.16.
      _fpreset_obj="${_mingw_common}/_fpreset.o"
      if [[ ! -f "${_fpreset_obj}" ]]; then
        cat > "${_mingw_common}/_fpreset_arm64.c" << 'FPRESET_EOF'
// _fpreset no-op stub for ARM64.
// ARM64 has no x87 FPU — _fpreset is meaningless. Satisfies CRT refs
// that use BL (BRANCH26), avoiding lld-link auto-import limitation.
void _fpreset(void) {}
FPRESET_EOF
        "${zig}" cc -target "${_win_target}" -c \
          "${_mingw_common}/_fpreset_arm64.c" \
          -o "${_fpreset_obj}" 2>/dev/null || true
        rm -f "${_mingw_common}/_fpreset_arm64.c"
        is_debug && echo "=== Compiled _fpreset stub ==="
      fi
    fi

    # Pre-compile Windows CRT startup objects for flexlink.
    # flexlink explicitly links crt2.o (console exe), crt2win.o (GUI exe),
    # and dllcrt2.o (DLL) as the first object file.  Zig compiles these
    # internally, but flexlink searches for them on disk via -print-search-dirs
    # paths.  Compile from zig's bundled MinGW CRT sources.
    _mingw_crt="${_mingw_common}/../crt"
    _mingw_inc="${_mingw_common}/../include"
    _win_inc="${_zig_lib}/libc/include/any-windows-any"

    if [[ -d "${_mingw_crt}" ]]; then
      is_debug && echo "=== Compiling MinGW CRT startup objects from ${_mingw_crt} ==="
      is_debug && echo "=== CRT sources: $(ls "${_mingw_crt}" | tr '\n' ' ') ==="

      _crt_flags=(-target "${_win_target}" -mcpu=baseline
                  -I"${_mingw_inc}" -I"${_win_inc}"
                  -D_CRTIMP= -D__USE_MINGW_ACCESS -c)

      # crt2.o — console application entry (main)
      _crt2_obj="${_mingw_common}/crt2.o"
      if [[ ! -f "${_crt2_obj}" ]] && [[ -f "${_mingw_crt}/crtexe.c" ]]; then
        "${zig}" cc "${_crt_flags[@]}" \
          "${_mingw_crt}/crtexe.c" -o "${_crt2_obj}" 2>&1 | \
          { is_debug && cat || true; } && \
          is_debug && echo "=== Compiled crt2.o ==" || true
      fi

      # crt2win.o — GUI application entry (WinMain)
      _crt2win_obj="${_mingw_common}/crt2win.o"
      if [[ ! -f "${_crt2win_obj}" ]] && [[ -f "${_mingw_crt}/crtexewin.c" ]]; then
        "${zig}" cc "${_crt_flags[@]}" -D_WINDOWS \
          "${_mingw_crt}/crtexewin.c" -o "${_crt2win_obj}" 2>&1 | \
          { is_debug && cat || true; } && \
          is_debug && echo "=== Compiled crt2win.o ===" || true
      fi

      # dllcrt2.o — DLL entry (DllMain)
      _dllcrt2_obj="${_mingw_common}/dllcrt2.o"
      if [[ ! -f "${_dllcrt2_obj}" ]] && [[ -f "${_mingw_crt}/crtdll.c" ]]; then
        "${zig}" cc "${_crt_flags[@]}" \
          "${_mingw_crt}/crtdll.c" -o "${_dllcrt2_obj}" 2>&1 | \
          { is_debug && cat || true; } && \
          is_debug && echo "=== Compiled dllcrt2.o ===" || true
      fi
    else
      is_debug && echo "=== MinGW CRT sources not found at ${_mingw_crt} ==="
    fi

  else
    is_debug && echo "=== llvm-dlltool or zig not found; skipping import lib pre-generation ==="
  fi
fi

# On Windows, zig-llvm produces MinGW-style import libs with .dll.a extension
# (libLLVM-20.dll.a, libc++.dll.a). Zig's gnu-target linker searches for .a
# (libLLVM-20.a) but not .dll.a. Create .a copies so zig can find them.
# Both are ar archives; the import lib works identically with either extension.
if is_not_unix; then
  echo "=== Creating .a import library aliases for zig gnu-target linker ==="
  for _implib in "${ZIG_LLVM_ROOT}/lib/"*.dll.a; do
    [[ ! -f "${_implib}" ]] && continue
    _base=$(basename "${_implib}")
    _a_name="${_base%.dll.a}.a"
    cp "${_implib}" "${ZIG_LLVM_ROOT}/lib/${_a_name}"
    echo "  ${_a_name} <- ${_base}"
  done
  # Zig's link_libcpp constructs "lib" + "libc++" + ".a" = "liblibc++.a" (double
  # lib prefix). Create alias so the linker finds it.
  if [[ -f "${ZIG_LLVM_ROOT}/lib/libc++.a" ]]; then
    cp "${ZIG_LLVM_ROOT}/lib/libc++.a" "${ZIG_LLVM_ROOT}/lib/liblibc++.a"
    echo "  liblibc++.a <- libc++.a (double-prefix alias for link_libcpp)"
  fi
  # libxml2 lives in PREFIX (host env, not zig-llvm/lib). zig's gnu-target linker
  # searches for xml2.dll/xml2.lib/libxml2.a (no 'lib' prefix on the .dll/.lib).
  # Copy whatever libxml2 ships (MinGW .dll.a or MSVC .lib) into zig-llvm/lib
  # under the names zig expects.
  _libxml2_src=""
  for _xml2_cand in \
    "${PREFIX}/${_library}lib/libxml2.dll.a" \
    "${PREFIX}/${_library}lib/libxml2.lib"; do
    [[ -f "${_xml2_cand}" ]] && _libxml2_src="${_xml2_cand}" && break
  done
  if [[ -n "${_libxml2_src}" ]]; then
    cp "${_libxml2_src}" "${ZIG_LLVM_ROOT}/lib/libxml2.a"
    cp "${_libxml2_src}" "${ZIG_LLVM_ROOT}/lib/xml2.lib"
    echo "  libxml2.a + xml2.lib <- $(basename "${_libxml2_src}")"
  else
    echo "  WARNING: libxml2 import lib not found in ${PREFIX}/${_library}lib/ — zig-zig link may fail on -lxml2"
  fi
fi

# Lld.zig-prefer-shared-libcxx.patch probes for shared libc++ relative to
# zig_lib_dir (BUILD_PREFIX/lib/zig/ at build time). Create symlinks so the
# probe finds zig-llvm's shared libc++ and links against it instead of the
# bundled static copy (which causes "separate copies of libc++" RTTI errors).
_probe_dir="${BUILD_PREFIX}/${_library}lib/zig-llvm/lib"
if [[ -d "${ZIG_LLVM_ROOT}/lib" ]] && [[ ! -d "${_probe_dir}" ]]; then
  mkdir -p "${_probe_dir}"
  # Copy only the libc++ files needed for the probe (not all of zig-llvm/lib)
  for _f in "${ZIG_LLVM_ROOT}/lib/"libc++*; do
    [[ -f "${_f}" ]] && cp "${_f}" "${_probe_dir}/"
  done
  echo "  libc++ probe: copied libc++ files to ${_probe_dir}"
fi

# Quick-fail: verify the libc++ probe will work at build time.
# zig_lib_dir is BUILD_PREFIX/<lib>/zig/, probe checks ../../lib/zig-llvm/lib/
if is_not_unix; then
  _probe_check="${BUILD_PREFIX}/${_library}lib/zig-llvm/lib/libc++.dll.a"
  if [[ ! -f "${_probe_check}" ]]; then
    echo "ERROR: libc++ probe file missing: ${_probe_check}"
    echo "  zig will fall back to static libc++ and fail with 'separate copies' error"
    echo "  Ensure zig-llvm's libc++.dll.a is available at BUILD_PREFIX"
    ls -la "${BUILD_PREFIX}/${_library}lib/zig-llvm/lib/" 2>/dev/null || echo "  Directory does not exist"
    exit 1
  fi
  echo "=== Quick-fail: libc++ probe OK (${_probe_check}) ==="
fi

echo "=== Building with ZIG ==="
if [[ "${force_cmake:-0}" != "1" ]] && build_zig_with_zig "${zig_build_dir}" "${zig}" "${PREFIX}"; then
  echo "SUCCESS: zig build completed successfully"
elif [[ "${cross_target_platform_}" == "osx-arm64" ]]; then
  echo "***"
  echo "* ERROR: We cannot build cross-target osx-arm64 with CMake without an emulator"
  echo "* Temporarily skip and rebuild with the new ZIG from osx-64"
  echo "***"
  exit 1
elif [[ "${cross_target_platform_}" == "linux-ppc64le" ]]; then
  echo "***"
  echo "* ERROR: zig build fails to complete cross-target linux-ppc64le with CMake (>6hrs)"
  echo "* Temporarily skip and rebuild with the new ZIG from linux-64"
  echo "***"
  exit 1
else
  source "${RECIPE_DIR}/build_scripts/_cmake.sh"  # apply_cmake_patches, cmake_build_install
  CMAKE_PATCHES=()

  if is_linux; then
    CMAKE_PATCHES+=(
      CMakeLists.txt-01-linux-maxrss.patch
      0002-linux-pthread-atfork-stub-zig2-CMakeLists.txt.patch
      0004-linux-link-zlib-zstd-zig2-CMakeLists.txt.patch
    )
    if is_cross; then
      CMAKE_PATCHES+=(0003-cross-CMakeLists.txt.patch)
      perl -pi -e 's/( | ")${ZIG_EXECUTABLE}/ ${CROSSCOMPILING_EMULATOR}\1${ZIG_EXECUTABLE}/' "${cmake_source_dir}"/cmake/install.cmake
      export ZIG_CROSS_TARGET_TRIPLE="${ZIG_TRIPLET}"
      export ZIG_CROSS_TARGET_MCPU="baseline"
    fi
  elif is_osx; then
    CMAKE_PATCHES+=(
      0006-osx-link-lldzig-zig2-CMakeLists.txt.patch
    )
  fi
  if is_not_unix; then
    _version=$(ls -1v "${VSINSTALLDIR}/VC/Tools/MSVC" | tail -n 1)
    _UCRT_LIB_PATH="C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\um\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\ucrt\x64;C:\Windows\System32"
    _MSVC_LIB_PATH="${VSINSTALLDIR//\\/\/}/VC/Tools/MSVC/${_version}/lib/x64"
    EXTRA_CMAKE_ARGS+=(
      -DZIG_CMAKE_PREFIX_PATH="${_MSVC_LIB_PATH};${_UCRT_LIB_PATH};${LIBPATH}"
    )
    CMAKE_PATCHES+=(
      0001-win-deprecations-zig_llvm.cpp.patch
      0001-win-deprecations-zig_llvm-ar.cpp.patch
      0005-win-remove-libm-CMakeLists.txt.patch
    )
  fi

  echo "Applying CMake patches..."
  apply_cmake_patches "${cmake_source_dir}"

  if cmake_build_install "${cmake_build_dir}" "${PREFIX}"; then
    echo "SUCCESS: cmake fallback build completed successfully"
  else
    echo "ERROR: Both zig build and cmake build failed"
    exit 1
  fi
fi

# Clean up .pdb debug files (zig build + shim compilation may produce these)
rm -f "${PREFIX}"/bin/*.pdb "${PREFIX}/${_library}bin"/*.pdb

# Quick-fail: verify the just-built zig doesn't have separate libc++ copies.
# This catches the RTTI error immediately instead of waiting for test phase.
# Skip on cross-builds (can't execute the target binary on the build machine).
if ! is_cross; then
  _zig_exe="${PREFIX}/bin/zig"
  [[ -f "${PREFIX}/${_library}bin/${CONDA_TRIPLET}-zig" ]] && _zig_exe="${PREFIX}/${_library}bin/${CONDA_TRIPLET}-zig"
  [[ -f "${PREFIX}/${_library}bin/${CONDA_TRIPLET}-zig.exe" ]] && _zig_exe="${PREFIX}/${_library}bin/${CONDA_TRIPLET}-zig.exe"
  echo "=== Quick-fail: libc++ isolation check ==="
  _zig_output=$("${_zig_exe}" version 2>&1) || true
  if echo "${_zig_output}" | grep -q "separate copies of libc++"; then
    echo "ERROR: zig has separate copies of libc++ (RTTI check failed)"
    echo "  Output: ${_zig_output}"
    echo "  The libcxx_shared.zig probe did not find shared libc++ at build time."
    echo "  Check that BUILD_PREFIX/<lib>/zig-llvm/lib/ has libc++ files."
    exit 1
  fi
  echo "  OK: zig version = ${_zig_output}"
fi

echo "Post-install implementation package: ${PKG_NAME}"

# macOS: rewrite zig binary's dylib references to use @loader_path so it always
# loads zig-llvm's dylibs, not conda-forge's copies that may be in $PREFIX/lib/.
# The zig binary is in $PREFIX/bin/, zig-llvm is in $PREFIX/lib/zig-llvm/lib/,
# so the relative path is @loader_path/../lib/zig-llvm/lib/<dylib>.
if is_osx; then
  _zig_bin="${PREFIX}/bin/zig"
  _zig_llvm_rel="@loader_path/../lib/zig-llvm/lib"
  echo "=== Fixing zig binary dylib refs to @loader_path (macOS) ==="
  while IFS= read -r _dep_line; do
    _dep=$(echo "${_dep_line}" | awk '{print $1}')
    _dep_base=$(basename "${_dep}")
    case "${_dep_base}" in
      # Match LLVM/libc++ refs regardless of prefix (@rpath/, @loader_path/, or bare name)
      libLLVM*|libclang*|libc++*|libunwind*|liblldZig*)
        _new="${_zig_llvm_rel}/${_dep_base}"
        # Only rewrite if this dylib exists in zig-llvm and isn't already correct
        if [[ "${_dep}" != "${_new}" ]] && { [[ -f "${PREFIX}/lib/zig-llvm/lib/${_dep_base}" ]] || [[ -L "${PREFIX}/lib/zig-llvm/lib/${_dep_base}" ]]; }; then
          install_name_tool -change "${_dep}" "${_new}" "${_zig_bin}"
          echo "  ${_dep} -> ${_new}"
        fi
        ;;
    esac
  done < <(otool -L "${_zig_bin}" 2>/dev/null | tail -n +2)

  # Verify: no @rpath or bare-name refs to zig-llvm libraries remain
  echo "=== Verifying zig binary dylib isolation (macOS) ==="
  _bad_refs=$(otool -L "${_zig_bin}" 2>/dev/null | awk '{print $1}' | grep -E '^(@rpath/|@loader_path/[^.])?(libLLVM|libclang|libc\+\+|libunwind|liblldZig)' | grep -v '@loader_path/../lib/zig-llvm/lib/' || true)
  if [[ -n "${_bad_refs}" ]]; then
    echo "ERROR: zig binary still has non-isolated refs to zig-llvm libraries:"
    echo "${_bad_refs}" | sed 's/^/  /'
    echo "These must use @loader_path/../lib/zig-llvm/lib/ to survive rattler-build packaging."
    exit 1
  fi
  # Show final state
  echo "  OK: all zig-llvm refs use @loader_path"
  otool -L "${_zig_bin}" 2>/dev/null | grep -E '(libLLVM|libclang|libc\+\+|libunwind)' | sed 's/^/  /' || true

  # libc++.1.0.dylib references @rpath/libc++abi.1.dylib, but the rpath resolves
  # to $PREFIX/lib/ (conda-forge) instead of $PREFIX/lib/zig-llvm/lib/ where it lives.
  # Rewrite to @loader_path so it finds its sibling directly.
  # TODO: remove once zig-llvm integrates abi into libc++ (LIBCXX_STATICALLY_LINK_ABI_IN_SHARED_LIBRARY=ON)
  _zigllvm_lib="${PREFIX}/lib/zig-llvm/lib"
  _libcxx="${_zigllvm_lib}/libc++.1.0.dylib"
  if [[ -f "${_libcxx}" ]]; then
    _abi_ref=$(otool -L "${_libcxx}" 2>/dev/null | awk '{print $1}' | grep 'libc++abi' || true)
    if [[ -n "${_abi_ref}" ]] && [[ "${_abi_ref}" != "@loader_path/"* ]]; then
      _abi_base=$(basename "${_abi_ref}")
      install_name_tool -change "${_abi_ref}" \
        "@loader_path/${_abi_base}" "${_libcxx}"
      echo "  libc++: ${_abi_ref} -> @loader_path/${_abi_base}"
    fi
  fi
fi

mv "${PREFIX}"/bin/zig "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig

# Windows conda convention: artifacts go under Library/
if is_not_unix; then
  echo "Relocating to Library/ for Windows conda convention"
  mkdir -p "${PREFIX}/Library/bin" "${PREFIX}/Library/lib" "${PREFIX}/Library/doc"
  mv "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig "${PREFIX}"/Library/bin/"${CONDA_TRIPLET}"-zig
  mv "${PREFIX}"/lib/zig "${PREFIX}"/Library/lib/zig
  [[ -d "${PREFIX}/doc" ]] && mv "${PREFIX}"/doc/* "${PREFIX}"/Library/doc/

  # DLL isolation wrapper: compile a small .exe shim that prepends zig-llvm/bin
  # to PATH then exec's the real binary. .bat wrappers break CMake's compiler
  # detection, so we need a real .exe.
  echo "=== Creating DLL isolation wrapper (Windows) ==="
  _zig_bin="${PREFIX}/Library/bin"
  _shim_c="${RECIPE_DIR}/building/zig_dll_shim.c"
  # MSYS2 bash strips the inner escaped quotes from -DREAL_EXE_NAME="\"...\""
  # so the preprocessor sees bare identifiers with hyphens. Inject via -include
  # of a generated header instead.
  _shim_hdr="${SRC_DIR}/shim_name.h"
  for _exe in "${_zig_bin}/"*-zig.exe; do
    [[ ! -f "${_exe}" ]] && continue
    _base=$(basename "${_exe}" .exe)
    mv "${_exe}" "${_zig_bin}/${_base}.real.exe"
    echo "  Compiling shim: ${_base}.exe -> ${_base}.real.exe"
    printf '#define REAL_EXE_NAME "%s.real.exe"\n' "${_base}" > "${_shim_hdr}"
    "${zig}" cc -target x86_64-windows-gnu \
      -include "${_shim_hdr}" \
      -o "${_zig_bin}/${_base}.exe" "${_shim_c}" \
      -lkernel32 -lshell32 || {
        echo "ERROR: Failed to compile DLL shim for ${_base}"
        echo "  Restoring original exe"
        mv "${_zig_bin}/${_base}.real.exe" "${_exe}"
        rm -f "${_shim_hdr}"
        exit 1
      }
    echo "  ${_base}.exe (shim) -> ${_base}.real.exe (DLL path: zig-llvm/bin)"
  done
  rm -f "${_shim_hdr}"
  # DIAG (win-arm64 .real investigation): show what the shim loop actually produced
  echo "=== DIAG: ${_zig_bin} contents after shim loop ==="
  ls -la "${_zig_bin}" || true
  # Clean .pdb from shim compilation. MinGW-target zig cc builds typically
  # don't emit .pdb files (PDB is an MSVC/PE debug format) so the glob may
  # not match anything -- guard with || true since set -e would otherwise
  # abort the whole script on a no-match ls.
  ls "${_zig_bin}"/*.pdb || true
  rm -f "${_zig_bin}"/*.pdb
fi

# Clean up build-time artifacts from zig-llvm that shouldn't be in the final package.
# The .a aliases were created for zig's gnu-target linker; the .dll.a originals
# remain (they're part of zig-llvm). llvm-config.exe is only needed during cmake.
# liblldZig.a and xml2.lib were staged for link-time use; installed binary uses
# the DLL at runtime, so remove them to satisfy package_contents: strict.
if is_not_unix; then
  echo "=== Cleaning build-time artifacts from zig-llvm ==="
  for _a in "${ZIG_LLVM_ROOT}/lib/"*.a; do
    [[ ! -f "${_a}" ]] && continue
    _base=$(basename "${_a}")
    # Keep .dll.a (real import libs) and liblld*.a (static lld archives)
    [[ "${_base}" == *.dll.a ]] && continue
    [[ "${_base}" == liblld*.a ]] && continue
    rm -v "${_a}"
  done
  rm -f "${ZIG_LLVM_ROOT}/bin/llvm-config.exe" "${ZIG_LLVM_ROOT}/bin/llvm-config"
  # Clean up build-time-only staging files (link inputs); installed binary
  # uses the DLL at runtime, not these .a/.lib copies. Avoids package_contents
  # strict-mode rejection for zig-zig_impl.
  rm -f "${ZIG_LLVM_ROOT}/lib/liblldZig.a"
  rm -f "${ZIG_LLVM_ROOT}/lib/xml2.lib"
fi

# Workaround for ziglang/zig#14919: add synchronization.def so zig can generate
# libsynchronization.a when cross-compiling to Windows (e.g. OCaml BYTECCLIBS uses -lsynchronization).
# IMPORTANT: LIBRARY must be api-ms-win-core-synch-l1-2-0.dll, NOT synchronization.dll.
# "synchronization.dll" is neither a real DLL on disk nor a valid API Set Schema name — it doesn't
# exist as a physical file in Windows or MSYS2. The real MinGW-w64 alias points to
# libapi-ms-win-core-synch-l1-2-0.a, whose LIBRARY directive is api-ms-win-core-synch-l1-2-0.dll.
# Windows API Set Schema resolves api-ms-win-* names to the actual host DLL at runtime.
if is_not_unix; then
  _zig_lib="${PREFIX}/Library/lib/zig"
  _mingw_common="${_zig_lib}/libc/mingw/lib-common"
else
  _zig_lib="${PREFIX}/lib/zig"
  _mingw_common="${_zig_lib}/libc/mingw/lib-common"
fi
if [[ -d "${_mingw_common}" ]]; then
  cat > "${_mingw_common}/synchronization.def" << 'SYNCHRONIZATION_DEF'
LIBRARY api-ms-win-core-synch-l1-2-0.dll

EXPORTS

DeleteSynchronizationBarrier
EnterSynchronizationBarrier
InitializeConditionVariable
InitializeSynchronizationBarrier
InitOnceBeginInitialize
InitOnceComplete
InitOnceExecuteOnce
InitOnceInitialize
SignalObjectAndWait
Sleep
SleepConditionVariableCS
SleepConditionVariableSRW
WaitOnAddress
WakeAllConditionVariable
WakeByAddressAll
WakeByAddressSingle
WakeConditionVariable
SYNCHRONIZATION_DEF
fi

# Pre-generate Windows PE import libraries (.a) from zig's MinGW .def/.def.in files.
# flexlink (OCaml's Windows linker) calls -print-search-dirs to find library
# search paths, then looks for libXXX.a files at those paths.  zig generates
# import libs internally at link time (cached in ~/.cache/zig/), but flexlink
# needs them at a fixed, known location.
#
# Two types of source files exist in lib-common/:
#   .def     — ready to use directly with dlltool (e.g. shlwapi.def)
#   .def.in  — C preprocessor templates that conditionally include exports by
#              architecture using macros from def-include/func.def.in
#              (e.g. kernel32.def.in, ws2_32.def.in, ole32.def.in)
#
# uuid is special: compiled from C source (no DLL import lib needed).
# Only generates files that are missing; safe to re-run.
#
# Target arch detection for dlltool machine type and zig cc -target.
# ZIG_TRIPLET is e.g. "x86_64-windows-gnu" or "aarch64-windows-gnu".
_win_arch="${ZIG_TRIPLET%%-*}"
case "${_win_arch}" in
  x86_64)       _dlltool_machine="i386:x86-64"; _win_target="x86_64-windows-gnu" ;;
  aarch64)      _dlltool_machine="arm64";        _win_target="aarch64-windows-gnu" ;;
  *)            _dlltool_machine="i386:x86-64"; _win_target="x86_64-windows-gnu"
                echo "WARN: unknown Windows arch '${_win_arch}', defaulting to x86_64" ;;
esac
if [[ -d "${_mingw_common}" ]]; then
  _zig_bin="${zig}"
  _def_include="${_mingw_common}/../def-include"
  _mingw_libsrc="${_mingw_common}/../libsrc"

  _dlltool=""
  for _cand in \
      "${ZIG_LLVM_ROOT}/bin/llvm-dlltool" \
      "${ZIG_LLVM_ROOT}/bin/llvm-dlltool.exe" \
      "${BUILD_PREFIX}/bin/llvm-dlltool" \
      "${BUILD_PREFIX}/bin/llvm-dlltool.exe" \
      "${BUILD_PREFIX}/Library/bin/llvm-dlltool.exe" \
      "${BUILD_PREFIX}/Library/bin/llvm-dlltool" \
      "$(command -v llvm-dlltool 2>/dev/null || true)"; do
    if [[ -x "${_cand}" ]]; then
      _dlltool="${_cand}"
      break
    fi
  done

  is_debug && echo "=== MinGW import lib generation: zig=${_zig_bin} dlltool=${_dlltool:-not found} ==="
  if [[ -n "${_dlltool}" ]] && [[ -x "${_zig_bin}" ]]; then
    is_debug && echo "=== Generating MinGW import libs (dlltool=${_dlltool}) ==="
    _gen_count=0

    # Helper: generate .a from a processed .def file
    _gen_implib() {
      local stem="$1" def="$2"
      local lib="${_mingw_common}/lib${stem}.a"
      [[ -f "${lib}" ]] && return 0
      local dll
      dll="$(awk '/^LIBRARY/{gsub(/"/, "", $2); print $2; exit}' "${def}")"
      [[ -z "${dll}" ]] && dll="${stem}.dll"
      "${_dlltool}" -m "${_dlltool_machine}" -D "${dll}" -d "${def}" -l "${lib}" 2>/dev/null || true
      _gen_count=$(( _gen_count + 1 ))
    }

    # Step 1: plain .def files (shlwapi.def, version.def, synchronization.def, etc.)
    for _def in "${_mingw_common}"/*.def; do
      [[ -f "${_def}" ]] || continue
      _stem="$(basename "${_def%.def}")"
      _gen_implib "${_stem}" "${_def}"
    done

    # Step 2: .def.in template files (ws2_32, kernel32, ole32, advapi32, user32, ...)
    # Process through zig's C preprocessor with x86_64 defines so architecture
    # macros (F_X64, F_I386, F64, F32, etc.) expand correctly.
    for _def_in in "${_mingw_common}"/*.def.in; do
      [[ -f "${_def_in}" ]] || continue
      _stem="$(basename "${_def_in%.def.in}")"
      _lib="${_mingw_common}/lib${_stem}.a"
      [[ -f "${_lib}" ]] && continue
      _def="${_mingw_common}/${_stem}.def"
      if [[ ! -f "${_def}" ]]; then
        "${_zig_bin}" cc -E -P \
          -target "${_win_target}" \
          -x assembler-with-cpp \
          -I"${_def_include}" \
          "${_def_in}" 2>/dev/null > "${_def}" || { rm -f "${_def}"; continue; }
      fi
      _gen_implib "${_stem}" "${_def}"
    done

    # Step 3: uuid — compiled from C source (no DLL, no import lib needed).
    # zig compiles libsrc/uuid.c into a static archive.
    _uuid_lib="${_mingw_common}/libuuid.a"
    _uuid_src="${_mingw_libsrc}/uuid.c"
    if [[ ! -f "${_uuid_lib}" ]] && [[ -f "${_uuid_src}" ]]; then
      _uuid_obj="${_mingw_common}/_uuid.o"
      "${_zig_bin}" cc -target "${_win_target}" -c "${_uuid_src}" \
          -o "${_uuid_obj}" 2>/dev/null && \
        "${_zig_bin}" ar rcs "${_uuid_lib}" "${_uuid_obj}" 2>/dev/null || true
      rm -f "${_uuid_obj}"
      _gen_count=$(( _gen_count + 1 ))
    fi

    is_debug && echo "=== Generated ${_gen_count} import libs in ${_mingw_common} ==="

    # Step 4: Supplemental import libs from mingw-w64 .def.in templates.
    # Zig doesn't ship msvcrt.def or ucrtbase.def -- we provide complete
    # mingw-w64 versions that cover all exports (stdio, math, POSIX I/O, etc.).
    # These use #include "func.def.in" for arch macros, so -I must point to
    # our mingw-defs/ directory (NOT zig's def-include/).
    _supp_defs="${RECIPE_DIR}/building/mingw-defs"
    if [[ -d "${_supp_defs}" ]]; then
      is_debug && echo "=== Processing supplemental mingw-w64 .def.in templates ==="
      for _supp_in in "${_supp_defs}"/*.def.in; do
        [[ -f "${_supp_in}" ]] || continue
        _supp_stem="$(basename "${_supp_in%.def.in}")"
        # Skip support files (included by other .def.in, not standalone libs)
        case "${_supp_stem}" in
          func|ucrtbase-common|crt-aliases) continue ;;
        esac
        _supp_lib="${_mingw_common}/lib${_supp_stem}.a"
        [[ -f "${_supp_lib}" ]] && continue
        _supp_def="${_mingw_common}/${_supp_stem}.def"
        if [[ ! -f "${_supp_def}" ]]; then
          "${_zig_bin}" cc -E -P \
            -target "${_win_target}" \
            -x assembler-with-cpp \
            -I"${_supp_defs}" \
            "${_supp_in}" 2>/dev/null > "${_supp_def}" || { rm -f "${_supp_def}"; continue; }
        fi
        _gen_implib "${_supp_stem}" "${_supp_def}"
      done
      # Also process plain .def files (no preprocessing needed)
      for _supp_def in "${_supp_defs}"/*.def; do
        [[ -f "${_supp_def}" ]] || continue
        _supp_stem="$(basename "${_supp_def%.def}")"
        _supp_lib="${_mingw_common}/lib${_supp_stem}.a"
        [[ -f "${_supp_lib}" ]] && continue
        _gen_implib "${_supp_stem}" "${_supp_def}"
      done
      is_debug && echo "=== Supplemental import libs done (total ${_gen_count}) ==="
    fi

    # Step 5: ARM64 intrinsic stubs (only for aarch64-windows-gnu).
    # ___chkstk_ms (3 underscores on ARM64) -- stack probe called by MSVC ABI.
    # __intrinsic_setjmpex -- setjmp variant used by MSVC exception handling.
    # These are tiny asm/C stubs compiled into .o files in lib-common/.
    if [[ "${_win_arch}" == "aarch64" ]]; then
      is_debug && echo "=== Compiling ARM64 intrinsic stubs ==="

      # ___chkstk_ms: ARM64 uses 3 underscores (not 2 like x86_64)
      _chkstk_obj="${_mingw_common}/___chkstk_ms.o"
      if [[ ! -f "${_chkstk_obj}" ]]; then
        cat > "${_mingw_common}/_chkstk_ms_arm64.S" << 'CHKSTK_EOF'
// ARM64 ___chkstk_ms stub -- probes stack pages for guard page support.
// On ARM64, the ABI uses 3 underscores. This minimal stub just returns
// (no-op probe), which is safe when stack size < guard page distance.
    .text
    .globl ___chkstk_ms
    .def ___chkstk_ms; .scl 2; .type 32; .endef
___chkstk_ms:
    ret
CHKSTK_EOF
        "${_zig_bin}" cc -target "${_win_target}" -c \
          "${_mingw_common}/_chkstk_ms_arm64.S" \
          -o "${_chkstk_obj}" 2>/dev/null || true
        rm -f "${_mingw_common}/_chkstk_ms_arm64.S"
        is_debug && echo "=== Compiled ___chkstk_ms stub ==="
      fi

      # __intrinsic_setjmpex: setjmp variant for structured exception handling
      _setjmpex_obj="${_mingw_common}/__intrinsic_setjmpex.o"
      if [[ ! -f "${_setjmpex_obj}" ]]; then
        cat > "${_mingw_common}/_setjmpex_arm64.c" << 'SETJMPEX_EOF'
// Weak stub for __intrinsic_setjmpex on ARM64.
// Real implementation is in the CRT; this provides a link-time fallback.
typedef void *jmp_buf[32];
__attribute__((weak))
int __intrinsic_setjmpex(jmp_buf env, void *frame) {
    (void)env;
    (void)frame;
    return 0;
}
SETJMPEX_EOF
        "${_zig_bin}" cc -target "${_win_target}" -c \
          "${_mingw_common}/_setjmpex_arm64.c" \
          -o "${_setjmpex_obj}" 2>/dev/null || true
        rm -f "${_mingw_common}/_setjmpex_arm64.c"
        is_debug && echo "=== Compiled __intrinsic_setjmpex stub ==="
      fi

      # _fpreset: ARM64 has no x87 FPU — _fpreset is a no-op. The MinGW CRT
      # objects (crt2.obj, libmingw32.lib) call _fpreset via BL instruction
      # (IMAGE_REL_ARM64_BRANCH26), but lld-link cannot auto-import through
      # branch relocations on ARM64. This static stub satisfies the symbol
      # at link time without dllimport. Expected fix in zig 0.15.x/0.16.
      _fpreset_obj="${_mingw_common}/_fpreset.o"
      if [[ ! -f "${_fpreset_obj}" ]]; then
        cat > "${_mingw_common}/_fpreset_arm64.c" << 'FPRESET_EOF'
// _fpreset no-op stub for ARM64.
// ARM64 has no x87 FPU — _fpreset is meaningless. Satisfies CRT refs
// that use BL (BRANCH26), avoiding lld-link auto-import limitation.
void _fpreset(void) {}
FPRESET_EOF
        "${_zig_bin}" cc -target "${_win_target}" -c \
          "${_mingw_common}/_fpreset_arm64.c" \
          -o "${_fpreset_obj}" 2>/dev/null || true
        rm -f "${_mingw_common}/_fpreset_arm64.c"
        is_debug && echo "=== Compiled _fpreset stub ==="
      fi
    fi

    # Pre-compile Windows CRT startup objects for flexlink.
    # flexlink explicitly links crt2.o (console exe), crt2win.o (GUI exe),
    # and dllcrt2.o (DLL) as the first object file.  Zig compiles these
    # internally, but flexlink searches for them on disk via -print-search-dirs
    # paths.  Compile from zig's bundled MinGW CRT sources.
    _mingw_crt="${_mingw_common}/../crt"
    _mingw_inc="${_mingw_common}/../include"
    _win_inc="${_zig_lib}/libc/include/any-windows-any"

    if [[ -d "${_mingw_crt}" ]]; then
      is_debug && echo "=== Compiling MinGW CRT startup objects from ${_mingw_crt} ==="
      is_debug && echo "=== CRT sources: $(ls "${_mingw_crt}" | tr '\n' ' ') ==="

      _crt_flags=(-target "${_win_target}" -mcpu=baseline
                  -I"${_mingw_inc}" -I"${_win_inc}"
                  -D_CRTIMP= -D__USE_MINGW_ACCESS -c)

      # crt2.o — console application entry (main)
      _crt2_obj="${_mingw_common}/crt2.o"
      if [[ ! -f "${_crt2_obj}" ]] && [[ -f "${_mingw_crt}/crtexe.c" ]]; then
        "${_zig_bin}" cc "${_crt_flags[@]}" \
          "${_mingw_crt}/crtexe.c" -o "${_crt2_obj}" 2>&1 | \
          { is_debug && cat || true; } && \
          is_debug && echo "=== Compiled crt2.o ==" || true
      fi

      # crt2win.o — GUI application entry (WinMain)
      _crt2win_obj="${_mingw_common}/crt2win.o"
      if [[ ! -f "${_crt2win_obj}" ]] && [[ -f "${_mingw_crt}/crtexewin.c" ]]; then
        "${_zig_bin}" cc "${_crt_flags[@]}" -D_WINDOWS \
          "${_mingw_crt}/crtexewin.c" -o "${_crt2win_obj}" 2>&1 | \
          { is_debug && cat || true; } && \
          is_debug && echo "=== Compiled crt2win.o ===" || true
      fi

      # dllcrt2.o — DLL entry (DllMain)
      _dllcrt2_obj="${_mingw_common}/dllcrt2.o"
      if [[ ! -f "${_dllcrt2_obj}" ]] && [[ -f "${_mingw_crt}/crtdll.c" ]]; then
        "${_zig_bin}" cc "${_crt_flags[@]}" \
          "${_mingw_crt}/crtdll.c" -o "${_dllcrt2_obj}" 2>&1 | \
          { is_debug && cat || true; } && \
          is_debug && echo "=== Compiled dllcrt2.o ===" || true
      fi
    else
      is_debug && echo "=== MinGW CRT sources not found at ${_mingw_crt} ==="
    fi

  else
    is_debug && echo "=== llvm-dlltool or zig not found; skipping import lib pre-generation ==="
  fi
fi

echo "=== Build installed for package: ${PKG_NAME} ==="

# Build musl shared libraries for cross-compilation targets
# This enables sysroot-free cross-compilation with dynamic linking
source "${RECIPE_DIR}/build_scripts/_post_install.sh"
post_install

# Cache successful build (saves before rattler-build cleanup)
if [[ "${ZIG_USE_CACHE:-}" == "0" ]] || [[ "${ZIG_USE_CACHE:-}" == "1" ]]; then
  # stub_cache.sh already sourced at the top if ZIG_USE_CACHE=1
  [[ "$(type -t stub_cache_save)" != "function" ]] && source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
  stub_cache_save
  echo "=== Build cached for future restoration ==="
fi
