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

source "${RECIPE_DIR}/build_scripts/_build.sh"  # configure_cmake_zigcpp, build_zig_with_zig, remove_failing_langref

build_platform="${build_platform:-${target_platform}}"

is_linux() { [[ "${target_platform}" == "linux-"* ]]; }
is_osx() { [[ "${target_platform}" == "osx-"* ]]; }
is_unix() { [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; }
is_not_unix() { ! is_unix; }
is_cross() { [[ "${build_platform}" != "${target_platform}" ]]; }

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
# CC, CXX, AR, RANLIB are set by zig_$build_platform activation
# zig binary is on PATH via the activation package
zig="$(find ${BUILD_PREFIX}/bin \( -name ${CONDA_ZIG_BUILD} -o -name zig \) -type f | tail -1)"

# Configure zig to use zig-llvm from ${BUILD_PREFIX}/lib/zig-llvm
export ZIG_LLVM_ROOT="${PREFIX}/lib/zig-llvm"
export PATH="${ZIG_LLVM_ROOT}/bin:${PATH}"
export LLVM_CONFIG=$(find "${BUILD_PREFIX}"/lib/zig-llvm/bin "${ZIG_LLVM_ROOT}"/bin/ -name llvm-config -type f | head -1)

is_debug && objdump -T "${ZIG_LLVM_ROOT}"/lib/libLLVM-20.so | grep GLIBC | awk '{print $5}' | sort -u | sort -V

# Verify zig-llvm is available
if [[ ! -x "${LLVM_CONFIG}" ]]; then
  echo "ERROR: zig-llvm llvm-config not found at ${LLVM_CONFIG}"
  echo "  Ensure zig-llvm package is installed"
  exit 1
fi
echo "=== Using zig-llvm from ${ZIG_LLVM_ROOT} ==="
echo "  LLVM version: $(${LLVM_CONFIG} --version)"

EXTRA_CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_PREFIX_PATH="${ZIG_LLVM_ROOT}"
  -DCMAKE_AR="${zig}"
  -DCMAKE_C_COMPILER="${zig};cc"
  -DCMAKE_CXX_COMPILER="${zig};c++"
  -DCMAKE_RANLIB="${zig};ranlib"
  -DZIG_AR_WORKAROUND=ON
  -DZIG_SHARED_LLVM=ON
  -DZIG_SYSTEM_LIBCXX=c++
  -DZIG_TARGET_MCPU=baseline
  -DZIG_TARGET_TRIPLE=${ZIG_TRIPLET}
  -DZIG_USE_LLVM_CONFIG=ON
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
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SYSTEM_LIBCXX=c++
    -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
  )
else
  EXTRA_CMAKE_ARGS+=()
  EXTRA_ZIG_ARGS+=(--maxrss 7500000000)
fi

if is_not_unix; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SHARED_LLVM=OFF
  )
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SHARED_LLVM=ON)
fi

if is_linux && is_cross; then
  EXTRA_ZIG_ARGS+=(
    -fqemu
    --libc "${zig_build_dir}"/libc_file
  )
fi

# --- libzigcpp Configuration ---

if is_linux; then
  source "${RECIPE_DIR}/build_scripts/_libc_tuning.sh"
  modify_libc_libm_for_zig "${BUILD_PREFIX}"
  create_gcc14_glibc28_compat_lib

  is_cross && is_osx && ${INSTALL_NAME_TOOL:-install_name_tool} -add_rpath "${BUILD_PREFIX}"/lib "${PREFIX}"/bin/llvm-config
fi

rm -f "${PREFIX}"/bin/llvm-config
cp "${ZIG_LLVM_ROOT}"/bin/llvm-config* "${PREFIX}"/bin/

configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

rm -f "${PREFIX}"/bin/llvm-config*

# --- Post CMake Configuration ---

# Add conda separated library dependencies to config.h - This seems to be doing the same thing ... odd
# perl -pi -e "s@(ZIG_(CLANG|CMAKE_PREFIX|LLD|LLVM)_\w+ \")${BUILD_PREFIX}/lib/zig-llvm@\$1${PREFIX}/lib/zig-llvm@" "${cmake_build_dir}"/config.h
perl -pi -e "s@${BUILD_PREFIX}/lib/zig-llvm@${PREFIX}/lib/zig-llvm@g" "${cmake_build_dir}"/config.h

# Add zig-llvm's bundled libc++ to ensure same C++ stdlib is used
if is_linux; then
  perl -pi -e "s@(ZIG_LLVM_LIBRARIES \")(.*)\"@\$1\$2;-lzstd;-lxml2;-lz;-L${PREFIX}/lib/zig-llvm/lib;-lc++;-lc++abi;-lunwind\"@" "${cmake_build_dir}"/config.h
elif is_osx; then
  perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${PREFIX}/lib/libc++.dylib\"@" "${cmake_build_dir}"/config.h
fi

# Create a C++ compiler wrapper that responds to -print-file-name queries.
# zig c++ doesn't support -print-file-name, so addCxxKnownPath in build.zig
# falls back to mod.link_libcpp=true (zig's bundled static hidden-vis libc++).
# This wrapper intercepts -print-file-name=libc++.so and returns the real path
# to zig-llvm's shared libc++, so zig links against it dynamically — giving all
# DSOs the same generic_category() singleton address.
if is_linux; then
  mkdir -p "${SRC_DIR}/build-wrappers"
  _cxx_wrapper="${SRC_DIR}/build-wrappers/zig-cxx-print"
  cat > "${_cxx_wrapper}" << CXXEOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    -print-file-name=libc++.so)
      echo "${PREFIX}/lib/zig-llvm/lib/libc++.so"
      exit 0 ;;
    -print-file-name=libc++.a)
      echo "${PREFIX}/lib/zig-llvm/lib/libc++.a"
      exit 0 ;;
    -print-file-name=*)
      # For anything else, echo back the name (not found)
      echo "\${arg#-print-file-name=}"
      exit 0 ;;
  esac
done
# Not a -print-file-name query — delegate to zig c++
exec "${zig}" c++ "\$@"
CXXEOF
  chmod +x "${_cxx_wrapper}"
  # Patch config.h so build.zig's addCxxKnownPath uses our wrapper
  perl -pi -e "s@(ZIG_CXX_COMPILER \").*\"@\$1${_cxx_wrapper}\"@" "${cmake_build_dir}"/config.h
  echo "Patched ZIG_CXX_COMPILER in config.h to use -print-file-name wrapper"
fi

is_debug && echo "=== DEBUG ===" && cat "${cmake_build_dir}"/config.h && echo "=== DEBUG ==="

if is_linux && is_cross; then
  source "${RECIPE_DIR}/build_scripts/_cross.sh"
  source "${RECIPE_DIR}/build_scripts/_atfork.sh"

  # Create sysroot-free libc config - zig uses its bundled headers for cross-compilation
  # This allows cross-compiling to riscv64/aarch64/ppc64le without target sysroot installed
  echo "Creating sysroot-free libc configuration for cross-compilation"
  cat > "${zig_build_dir}/libc_file" << 'EOF'
# Zig self-contained cross-compilation configuration
# Empty paths = use zig's bundled libc headers and musl
# This enables cross-compilation without target sysroot
include_dir=
sys_include_dir=
crt_dir=
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF

  remove_failing_langref "${zig_build_dir}"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"
  create_pthread_atfork_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
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
      0001-linux-maxrss-CMakeLists.txt.patch
      0002-linux-pthread-atfork-stub-zig2-CMakeLists.txt.patch
    )
    if is_cross; then
      CMAKE_PATCHES+=(0003-cross-CMakeLists.txt.patch)
      perl -pi -e 's/( | ")${ZIG_EXECUTABLE}/ ${CROSSCOMPILING_EMULATOR}\1${ZIG_EXECUTABLE}/' "${cmake_source_dir}"/cmake/install.cmake
      export ZIG_CROSS_TARGET_TRIPLE="${ZIG_TRIPLET}"
      export ZIG_CROSS_TARGET_MCPU="baseline"
    fi
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

# Odd random occurence of zig.pdb
rm -f ${PREFIX}/bin/zig.pdb

echo "Post-install implementation package: ${PKG_NAME}"
mv "${PREFIX}"/bin/zig "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig

# Windows conda convention: artifacts go under Library/
if is_not_unix; then
  echo "Relocating to Library/ for Windows conda convention"
  mkdir -p "${PREFIX}/Library/bin" "${PREFIX}/Library/lib" "${PREFIX}/Library/doc"
  mv "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig "${PREFIX}"/Library/bin/"${CONDA_TRIPLET}"-zig
  mv "${PREFIX}"/lib/zig "${PREFIX}"/Library/lib/zig
  [[ -d "${PREFIX}/doc" ]] && mv "${PREFIX}"/doc/* "${PREFIX}"/Library/doc/
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
