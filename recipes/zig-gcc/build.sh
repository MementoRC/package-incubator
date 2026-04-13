#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi

# --- Functions ---

source "${RECIPE_DIR}/building/_build.sh"  # configure_cmake_zigcpp, build_zig_with_zig

build_platform="${build_platform:-${target_platform}}"

is_linux() { [[ "${target_platform}" == "linux-"* ]]; }
is_osx() { [[ "${target_platform}" == "osx-"* ]]; }
is_unix() { [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; }
is_not_unix() { ! is_unix; }
is_cross() { [[ "${build_platform}" != "${target_platform}" ]]; }

is_debug() { [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]]; }
dbg() { [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]] && "$@" || true; }

# --- Early exits ---

[[ -z "${CONDA_TRIPLET:-}" ]] && { echo "CONDA_TRIPLET must be specified in recipe.yaml env"; exit 1; }
[[ -z "${CONDA_ZIG_BUILD:-}" ]] && { echo "CONDA_ZIG_BUILD undefined, use zig_<arch> instead of _impl"; exit 1; }
[[ -z "${ZIG_TRIPLET:-}" ]] && { echo "ZIG_TRIPLET must be specified in recipe.yaml env"; exit 1; }

if [[ "${PKG_NAME:-}" != "zig-gcc_impl_"* ]]; then
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
    exit 0
  fi
  echo "=== No cache found - will build and cache result ==="
  # Continue with normal build, cache will be saved at the end
fi

# --- Main ---

# Bootstrap zig runs on the build machine — always use CONDA_ZIG_BUILD
BUILD_ZIG="${CONDA_ZIG_BUILD}"

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

# --- Common CMake/zig configuration ---

EXTRA_CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DZIG_TARGET_MCPU=baseline
  -DZIG_TARGET_TRIPLE=${ZIG_TRIPLET}
  -DZIG_USE_LLVM_CONFIG=ON
)

# Remember: CPU MUST be baseline, otherwise it create non-portable zig code (optimized for a given hardware)
EXTRA_ZIG_ARGS=(
  --search-prefix "${PREFIX}"
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

# Tell the prefer-shared-libcxx patch where to find target-arch libc++.so.
# On cross-builds, zig_lib_dir points to the build host, so the patch's
# default probe finds wrong-arch libraries. This env var bypasses the
# arch guard and probes the target prefix directly.
export ZIG_SHARED_LIBCXX_DIR="${PREFIX}/lib/zig-llvm/lib"

# Patch 0007 adds -Ddoctest-target to build.zig (Linux only)
is_linux && EXTRA_ZIG_ARGS+=(-Ddoctest-target=${ZIG_TRIPLET})

# ppc64le cross: skip docgen — qemu-ppc64le doesn't faithfully emulate traps,
# and the ppc64le GCC linker has __tls_get_addr DSO ordering issues with doctests
[[ "${target_platform}" == "linux-ppc64le" ]] && is_cross && EXTRA_ZIG_ARGS+=(-Dno-langref)

if is_osx; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SYSTEM_LIBCXX=c++
    -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
  )
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SYSTEM_LIBCXX=stdc++)
fi

# CI runners have limited memory (~7.5GB); zig defaults to 7.8GB
EXTRA_ZIG_ARGS+=(--maxrss 7500000000)

if is_not_unix; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SHARED_LLVM=OFF
  )
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SHARED_LLVM=ON)
fi

if is_linux && is_cross; then
  EXTRA_ZIG_ARGS+=(
    --libc "${zig_build_dir}"/libc_file
    --libc-runtimes "${CONDA_BUILD_SYSROOT}"/lib64
  )
  # Enable qemu for running cross-compiled doctests at build time.
  # qemu-execve-<arch> from conda-forge installs qemu-<arch> to PATH.
  _target_arch="${target_platform#linux-}"
  if command -v "qemu-${_target_arch}" &>/dev/null; then
    # QEMU_LD_PREFIX: sysroot for target's dynamic linker and shared libs
    export QEMU_LD_PREFIX="${CONDA_BUILD_SYSROOT}"
    EXTRA_ZIG_ARGS+=(-fqemu)
    echo "=== qemu-${_target_arch} found: $(command -v "qemu-${_target_arch}") ==="
    echo "=== QEMU_LD_PREFIX=${QEMU_LD_PREFIX} ==="
  else
    echo "=== WARNING: qemu-${_target_arch} not found on PATH, doctests will be skipped ==="
    EXTRA_ZIG_ARGS+=(-Dno-langref)
  fi
fi

# --- libzigcpp Configuration ---

if is_linux; then
  source "${RECIPE_DIR}/building/_libc_tuning.sh"
  create_gcc14_glibc28_compat_lib
  
  is_cross && rm "${PREFIX}"/bin/llvm-config && cp "${BUILD_PREFIX}"/bin/llvm-config "${PREFIX}"/bin/llvm-config
fi

configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

# --- Post CMake Configuration ---
is_debug && echo "=== POST-CMAKE: starting post-cmake configuration ==="

# Append extra link deps to config.h (cmake doesn't know about conda's split packaging)
is_debug && echo "=== POST-CMAKE: perl config.h edits ==="
is_linux && is_cross && perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;-lzstd;-lxml2;-lz\"@" "${cmake_build_dir}"/config.h
is_osx && is_cross &&   perl -pi -e "s@(ZIG_LLVM_\w+ \")${BUILD_PREFIX}@\$1${PREFIX}@" "${cmake_build_dir}"/config.h
is_osx &&               perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${PREFIX}/lib/libc++.dylib\"@" "${cmake_build_dir}"/config.h

is_debug && echo "=== DEBUG ===" && cat "${cmake_build_dir}"/config.h && echo "=== DEBUG ==="

# --- Cross-build setup (must happen BEFORE Stage 1 since EXTRA_ZIG_ARGS has --libc) ---

if is_linux && is_cross; then
  is_debug && echo "=== POST-CMAKE: linux cross-build setup ==="
  source "${RECIPE_DIR}/building/_cross.sh"
  source "${RECIPE_DIR}/building/_atfork.sh"
  source "${RECIPE_DIR}/building/_sysroot_fix.sh"

  is_debug && echo "=== POST-CMAKE: fix_sysroot_libc_scripts ==="
  fix_sysroot_libc_scripts "${BUILD_PREFIX}"

  is_debug && echo "=== POST-CMAKE: create_zig_linux_libc_file ==="
  create_zig_linux_libc_file "${zig_build_dir}/libc_file"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"
  is_debug && echo "=== POST-CMAKE: create_pthread_atfork_stub ==="
  create_pthread_atfork_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/libc_single_threaded_stub.o\"|g" "${cmake_build_dir}/config.h"
  is_debug && echo "=== POST-CMAKE: create_libc_single_threaded_stub ==="
  create_libc_single_threaded_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
  is_debug && echo "=== POST-CMAKE: cross-build setup DONE ==="
fi

# Optional: build native zig from source when conda bootstrap can't compile new version.
# Set BUILD_NATIVE_ZIG=1 to enable. Not needed since build 12 (ld script patch in package).
if is_linux && [[ "${BUILD_NATIVE_ZIG:-0}" == "1" ]]; then
  build_native_zig "${SRC_DIR}/native-zig-install"
fi


is_debug && echo "=== ZIG BUILD: starting zig build ==="
is_debug && echo "=== ZIG BUILD: zig=${BUILD_ZIG} dir=${zig_build_dir} ==="
if build_zig_with_zig "${zig_build_dir}" "${BUILD_ZIG}" "${PREFIX}"; then
  is_debug && echo "=== ZIG BUILD: SUCCESS ==="
elif [[ "${CMAKE_FALLBACK:-1}" == "1" ]]; then
  is_debug && echo "=== ZIG BUILD: FAILED, trying cmake fallback ==="
  source "${RECIPE_DIR}/building/_cmake.sh"  # cmake_fallback_build
  cmake_fallback_build "${cmake_source_dir}" "${cmake_build_dir}" "${PREFIX}"
else
  echo "Build zig with zig failed and CMake fallback disabled"
  exit 1
fi


# Odd random occurence of zig.pdb
rm -f ${PREFIX}/bin/zig.pdb

is_debug && echo "=== POST-INSTALL: mv zig to ${CONDA_TRIPLET}-zig ==="
mv "${PREFIX}"/bin/zig "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig
is_debug && echo "=== POST-INSTALL: mv done ==="

# Non-unix conda convention: artifacts go under Library/
if is_not_unix; then
  is_debug && echo "Relocating to Library/ for non-unix conda convention"
  mkdir -p "${PREFIX}/Library/bin" "${PREFIX}/Library/lib" "${PREFIX}/Library/doc"
  mv "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig "${PREFIX}"/Library/bin/"${CONDA_TRIPLET}"-zig
  mv "${PREFIX}"/lib/zig "${PREFIX}"/Library/lib/zig
  [[ -d "${PREFIX}/doc" ]] && mv "${PREFIX}"/doc/* "${PREFIX}"/Library/doc/
fi

# MinGW import lib + CRT pre-generation (synchronization.def, PE import libs, CRT objects)
source "${RECIPE_DIR}/building/_mingw.sh"
generate_mingw_import_libs

is_debug && echo "=== Build installed for package: ${PKG_NAME} ==="

# Cache successful build (saves before rattler-build cleanup)
if [[ "${ZIG_USE_CACHE:-}" == "0" ]] || [[ "${ZIG_USE_CACHE:-}" == "1" ]]; then
  # stub_cache.sh already sourced at the top if ZIG_USE_CACHE=1
  [[ "$(type -t stub_cache_save)" != "function" ]] && source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
  stub_cache_save
  is_debug && echo "=== Build cached for future restoration ==="
fi
