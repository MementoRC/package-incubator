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
# zig_$build_platform activation sets:
#   CONDA_ZIG_BUILD, CONDA_ZIG_HOST
#   ZIG_CC, ZIG_CXX, ZIG_AR, ZIG_RANLIB, ZIG_ASM, ZIG_RC (wrapper scripts)
zig="$(find "${BUILD_PREFIX}/bin" "${BUILD_PREFIX}/Library/bin" \( -name "${CONDA_ZIG_BUILD}" -o -name "${CONDA_ZIG_BUILD}.exe" -o -name "${CONDA_ZIG_HOST}" -o -name "${CONDA_ZIG_HOST}.exe" \) 2>/dev/null | head -1 || true)"

# Fallback: search for any *-zig binary in PATH
if [[ -z "${zig}" ]]; then
  zig="$(find "${BUILD_PREFIX}/bin" "${BUILD_PREFIX}/Library/bin" -name '*-zig' -o -name '*-zig.exe' 2>/dev/null | head -1 || true)"
fi

echo "CONDA_ZIG_BUILD: ${CONDA_ZIG_BUILD:-NOT FOUND}"
echo "CONDA_ZIG_HOST: ${CONDA_ZIG_HOST:-NOT FOUND}"
echo "zig binary: ${zig:-NOT FOUND}"
echo "ZIG_CC: ${ZIG_CC:-NOT SET}"
echo "ZIG_CXX: ${ZIG_CXX:-NOT SET}"
echo "ZIG_AR: ${ZIG_AR:-NOT SET}"
echo "ZIG_RANLIB: ${ZIG_RANLIB:-NOT SET}"

if [[ -z "${ZIG_CC:-}" ]]; then
  echo "Activation did not set ZIG_CC, using zig binary directly"
  export ZIG_CC="${zig} cc"
  export ZIG_CXX="${zig} c++"
  export ZIG_AR="${zig} ar"
  export ZIG_RANLIB="${zig} ranlib"
fi

export CC="${ZIG_CC}"
export CXX="${ZIG_CXX}"
export AR="${ZIG_AR}"
export RANLIB="${ZIG_RANLIB}"

# CONDA_BUILD_SYSROOT is normally set by compiler("c") activation (gcc/clang).
# Since we use zig as compiler, set it manually from stdlib("c") sysroot.
if is_linux; then
  export CONDA_BUILD_SYSROOT="${BUILD_PREFIX}/${CONDA_TRIPLET}/sysroot"
fi

# Configure zig to use zig-llvm from ${PREFIX}/lib/zig-llvm (Unix) or ${PREFIX}/Library/lib/zig-llvm (Windows)
if is_not_unix; then
  _library="Library/"
else
  _library=""
fi
export ZIG_LLVM_ROOT="${PREFIX}/${_library}lib/zig-llvm"
export PATH="${ZIG_LLVM_ROOT}/bin:${PATH}"
# On Windows, use llvm-config.real.exe (the actual binary) not the bash wrapper
# which CMake can't execute from cmd.exe
export LLVM_CONFIG=$(find "${BUILD_PREFIX}/${_library}lib/zig-llvm/bin" "${ZIG_LLVM_ROOT}"/bin/ \( -name 'llvm-config.real.exe' -o -name 'llvm-config.real' -o -name 'llvm-config' -o -name 'llvm-config.exe' \) -type f 2>/dev/null | head -1)

is_debug && is_linux && objdump -T "${ZIG_LLVM_ROOT}"/lib/libLLVM-20.so | grep GLIBC | awk '{print $5}' | sort -u | sort -V

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
  )

  # For cross-target macOS, the build platform's zig-cc wrapper targets the wrong
  # architecture (e.g. arm64 when we need x86_64). Create local wrappers with the
  # correct target triple for CMake.
  if is_cross; then
    mkdir -p "${SRC_DIR}/build-wrappers"
    for _mode in cc c++; do
      _wrapper="${SRC_DIR}/build-wrappers/zig-${_mode}"
      cat > "${_wrapper}" << ZIGEOF
#!/usr/bin/env bash
exec "${zig}" ${_mode} -target ${ZIG_TRIPLET} -mcpu=baseline "\$@"
ZIGEOF
      chmod +x "${_wrapper}"
    done
    export ZIG_CC="${SRC_DIR}/build-wrappers/zig-cc"
    export ZIG_CXX="${SRC_DIR}/build-wrappers/zig-c++"
    export CC="${ZIG_CC}"
    export CXX="${ZIG_CXX}"
    # Override CMAKE_C/CXX_COMPILER (later -D wins over earlier)
    EXTRA_CMAKE_ARGS+=(
      -DCMAKE_C_COMPILER="${ZIG_CC}"
      -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
    )
  fi
fi

# Override zig's default max_rss (7.8GB) which exceeds CI runner memory
EXTRA_ZIG_ARGS+=(--maxrss 7000000000)


if is_not_unix; then
  EXTRA_CMAKE_ARGS+=(-DZIG_SHARED_LLVM=OFF)
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SHARED_LLVM=ON)
fi
EXTRA_CMAKE_ARGS+=(-DZIG_USE_LLVM_CONFIG=ON)

if is_linux && is_cross; then
  EXTRA_ZIG_ARGS+=(
    -fqemu
    --libc "${zig_build_dir}"/libc_file
  )
fi

# --- libzigcpp Configuration ---

if is_linux; then
  is_cross && is_osx && ${INSTALL_NAME_TOOL:-install_name_tool} -add_rpath "${BUILD_PREFIX}"/lib "${PREFIX}"/bin/llvm-config
fi

rm -f "${PREFIX}/${_library}bin"/llvm-config*
if is_not_unix; then
  # On Windows, the bash wrapper llvm-config can't be executed by CMake.
  # Replace it with the real binary in zig-llvm's bin dir so llvm-config's
  # prefix auto-detection still works (it computes prefix from its own location).
  rm -f "${ZIG_LLVM_ROOT}/bin/llvm-config"
  cp "${ZIG_LLVM_ROOT}/bin/llvm-config.real.exe" "${ZIG_LLVM_ROOT}/bin/llvm-config.exe"
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
set(CMAKE_C_COMPILER_VERSION "20.1.8" CACHE STRING "")
set(CMAKE_CXX_COMPILER_VERSION "20.1.8" CACHE STRING "")
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
TCEOF
  EXTRA_CMAKE_ARGS+=(-C "${_cache_seed}")
fi

configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

rm -f "${PREFIX}/${_library}bin"/llvm-config*

# --- Post CMake Configuration ---

# Add conda separated library dependencies to config.h - This seems to be doing the same thing ... odd
# perl -pi -e "s@(ZIG_(CLANG|CMAKE_PREFIX|LLD|LLVM)_\w+ \")${BUILD_PREFIX}/lib/zig-llvm@\$1${PREFIX}/lib/zig-llvm@" "${cmake_build_dir}"/config.h
perl -pi -e "s@${BUILD_PREFIX}/${_library}lib/zig-llvm@${PREFIX}/${_library}lib/zig-llvm@g" "${cmake_build_dir}"/config.h

# Add zig-llvm's bundled libc++ to ensure same C++ stdlib is used
if is_linux; then
  perl -pi -e "s@(ZIG_LLVM_LIBRARIES \")(.*)\"@\$1\$2;-lzstd;-lxml2;-lz;-L${PREFIX}/lib/zig-llvm/lib;-lc++;-lc++abi;-lunwind\"@" "${cmake_build_dir}"/config.h
elif is_osx; then
  perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;-lzstd;-lxml2;-lz;-L${PREFIX}/lib/zig-llvm/lib;${PREFIX}/lib/zig-llvm/lib/libc++.dylib\"@" "${cmake_build_dir}"/config.h
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
      0004-linux-link-zlib-zstd-zig2-CMakeLists.txt.patch
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
