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
if is_linux; then
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
# Cross-build llvm-config wrapper: runs the host llvm-config (BUILD_PREFIX)
# but rewrites all paths to point at the target zig-llvm installation.
output="\$("${_real_llvm_config}" "\$@" 2>&1)" || { echo "\$output" >&2; exit 1; }
# Rewrite BUILD_PREFIX paths → ZIG_LLVM_ROOT
output="\${output//${BUILD_PREFIX//\//\\/}/${ZIG_LLVM_ROOT//\//\\/}}"
# Filter flags unsupported by zig's linker (same as zig-llvm wrapper)
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
  )

  # Cross-builds: zig_$cross_target_platform_ activation provides wrappers
  # targeting the host platform (e.g. x86_64 for osx-64). No custom wrappers needed.
fi

# Override zig's default max_rss (7.8GB) which exceeds CI runner memory
EXTRA_ZIG_ARGS+=(--maxrss 7500000000)


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
  EXTRA_CMAKE_ARGS+=(-C "${_cache_seed}")
fi

# Findllvm.cmake: find_program searches CMAKE_PREFIX_PATH (which includes
# ZIG_LLVM_ROOT) and hardcoded MSYS2 paths. For cross-builds, we copied
# the native llvm-config.exe into ZIG_LLVM_ROOT/bin above so it's found.

# Diagnostic: show zig-llvm cmake config availability
echo "=== zig-llvm cmake config check ==="
for _cm_dir in llvm clang lld; do
  _cm_path="${ZIG_LLVM_ROOT}/lib/cmake/${_cm_dir}"
  if [[ -d "${_cm_path}" ]]; then
    echo "  ${_cm_dir}: $(ls "${_cm_path}"/*.cmake 2>/dev/null | wc -l) cmake files"
  else
    echo "  ${_cm_dir}: MISSING (${_cm_path})"
  fi
done
echo "  Libraries: $(ls "${ZIG_LLVM_ROOT}/lib/"*.a "${ZIG_LLVM_ROOT}/lib/"*.dll.a "${ZIG_LLVM_ROOT}/lib/"*.dylib "${ZIG_LLVM_ROOT}/lib/"*.so* 2>/dev/null | wc -l) files"

configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

rm -f "${PREFIX}/${_library}bin"/llvm-config*

# --- Post CMake Configuration ---

# Add zig-llvm's bundled libc++ to ensure same C++ stdlib is used
if is_linux; then
  perl -pi -e "s@(ZIG_LLVM_LIBRARIES \")(.*)\"@\$1\$2;-lzstd;-lxml2;-lz;-L${PREFIX}/lib/zig-llvm/lib;-lc++;-lc++abi;-lunwind\"@" "${cmake_build_dir}"/config.h
elif is_osx; then
  perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;-lzstd;-lxml2;-lz;-L${PREFIX}/lib/zig-llvm/lib;${PREFIX}/lib/zig-llvm/lib/libc++.dylib\"@" "${cmake_build_dir}"/config.h
elif is_not_unix; then
  # cmake finds libLLVM-20.dll in bin/ and records "zig-llvm/bin/libLLVM-20" (no
  # extension). Zig needs the import lib in lib/ with proper extension. Fix the
  # path and add libc++ + dependencies.
  _zig_llvm_lib="${ZIG_LLVM_ROOT//\\//}/lib"
  echo "=== Windows config.h patching ==="
  echo "  BEFORE ZIG_LLVM_LIBRARIES:"
  grep 'ZIG_LLVM_LIBRARIES' "${cmake_build_dir}"/config.h | head -1
  # bin/libLLVM-20 → lib/libLLVM-20.dll.a (handle both / and \ separators)
  perl -pi -e 's@zig-llvm[/\\\\]bin[/\\\\](libLLVM-\d+)@zig-llvm/lib/$1.dll.a@g' "${cmake_build_dir}"/config.h
  perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;-lzstd;-lxml2;-lz;-L${_zig_llvm_lib};-lc++\"@" "${cmake_build_dir}"/config.h
  echo "  AFTER ZIG_LLVM_LIBRARIES:"
  grep 'ZIG_LLVM_LIBRARIES' "${cmake_build_dir}"/config.h | head -1
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
      libLLVM*|libclang*|libc++*|libunwind*)
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
  _bad_refs=$(otool -L "${_zig_bin}" 2>/dev/null | awk '{print $1}' | grep -E '^(@rpath/|@loader_path/[^.])?(libLLVM|libclang|libc\+\+|libunwind)' | grep -v '@loader_path/../lib/zig-llvm/lib/' || true)
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
  for _exe in "${_zig_bin}/"*-zig.exe; do
    [[ ! -f "${_exe}" ]] && continue
    _base=$(basename "${_exe}" .exe)
    mv "${_exe}" "${_zig_bin}/${_base}.real.exe"
    echo "  Compiling shim: ${_base}.exe -> ${_base}.real.exe"
    "${zig}" cc -target x86_64-windows-gnu \
      -DREAL_EXE_NAME="\"${_base}.real.exe\"" \
      -o "${_zig_bin}/${_base}.exe" "${_shim_c}" \
      -lkernel32 -lshell32 || {
        echo "ERROR: Failed to compile DLL shim for ${_base}"
        echo "  Restoring original exe"
        mv "${_zig_bin}/${_base}.real.exe" "${_exe}"
        exit 1
      }
    echo "  ${_base}.exe (shim) -> ${_base}.real.exe (DLL path: zig-llvm/bin)"
  done
  # Clean .pdb from shim compilation
  ls "${_zig_bin}"/*.pdb
  rm -f "${_zig_bin}"/*.pdb
  ls "${_zig_bin}"/*.pdb || true
fi

# Clean up build-time artifacts from zig-llvm that shouldn't be in the final package.
# The .a aliases were created for zig's gnu-target linker; the .dll.a originals
# remain (they're part of zig-llvm). llvm-config.exe is only needed during cmake.
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
