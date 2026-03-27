#!/usr/bin/env bash
# Build LLVM with zig cc for zig-llvmdev package
# This produces LLVM/Clang/LLD shared libraries with libc++ ABI
# compatible with zig-cc-built zigcpp

set -euxo pipefail
IFS=$'\n\t'

if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  echo "Attempting to re-exec with conda bash..."
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  elif [[ -x "${BUILD_PREFIX}/Library/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/Library/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi

source ${RECIPE_DIR}/building/post-install.sh
source ${RECIPE_DIR}/building/remove-unneeded.sh
source ${RECIPE_DIR}/building/strip_atexit_from_implib.sh

build_platform="${build_platform:-${target_platform}}"

is_linux() { [[ "${target_platform}" == "linux-"* ]]; }
is_osx() { [[ "${target_platform}" == "osx-"* ]]; }
is_unix() { [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; }
is_not_unix() { [[ "${target_platform}" != "linux-"* && "${target_platform}" != "osx-"* ]]; }
is_cross() { [[ "${build_platform}" != "${target_platform}" ]]; }

# Debug output: ZIG_LLVM_DEBUG=1 in recipe.yaml env
_debug() { [[ "${ZIG_LLVM_DEBUG:-0}" == "1" ]]; }
dbg() { _debug && echo "  [DBG] $*" || true; }

echo "=== Building zig-llvmdev with zig cc ==="
echo "  LLVM source: ${SRC_DIR}/llvm-source"
echo "  Target: ${target_platform}"

LLVM_SRC="${SRC_DIR}/llvm"
LLVM_BUILD="${SRC_DIR}/conda-llvm-build"
# Windows: conda convention is $PREFIX/Library/ for non-Python artifacts
if [[ "${target_platform}" == win-* ]]; then
  LLVM_INSTALL="${PREFIX}/Library/lib/zig-llvm"
else
  LLVM_INSTALL="${PREFIX}/lib/zig-llvm"
fi

# Cross-compilation detection and setup
# CONDA_BUILD_CROSS_COMPILATION is set by conda-build when build_platform != target_platform
CMAKE_CROSS_FLAGS=()
if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
  echo "=== Cross-compilation detected ==="
  echo "  Build platform: ${build_platform}"
  echo "  Target platform: ${target_platform}"

  # Determine target system name for cmake
  is_linux && CMAKE_SYSTEM_NAME="Linux"
  is_osx && CMAKE_SYSTEM_NAME="Darwin"
  is_not_unix && CMAKE_SYSTEM_NAME="Windows"

  CMAKE_CROSS_FLAGS=(
    -DCMAKE_CROSSCOMPILING=True
    -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}"
    -DCMAKE_INSTALL_INCLUDEDIR=include
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_INSTALL_BINDIR=bin
    -DCMAKE_SYSTEM_NAME="${CMAKE_SYSTEM_NAME}"
    -DLLVM_DEFAULT_TARGET_TRIPLE="${LLVM_TRIPLET}"
    -DLLVM_HOST_TRIPLE="${LLVM_TRIPLET}"
  )


  # Tablegen tools run on the BUILD host, not target.
  # Provided by zig-llvm itself (build dep for cross-compilation).
  LLVM_TBLGEN=$(find "${BUILD_PREFIX}" \( -name llvm-tblgen -o -name llvm-tblgen.exe \) -type f 2>/dev/null | head -1)
  CLANG_TBLGEN=$(find "${BUILD_PREFIX}" \( -name clang-tblgen -o -name clang-tblgen.exe \) -type f 2>/dev/null | head -1)
  # Append tblgen paths if found (use += to preserve existing flags).
  # LLVM 20 uses CLANG_TABLEGEN_EXE (not CLANG_TABLEGEN).
  [[ -n "${LLVM_TBLGEN}" ]] && CMAKE_CROSS_FLAGS+=(-DLLVM_TABLEGEN="${LLVM_TBLGEN}")
  [[ -n "${CLANG_TBLGEN}" ]] && CMAKE_CROSS_FLAGS+=(-DCLANG_TABLEGEN_EXE="${CLANG_TBLGEN}")

  # Pre-built tablegen tools from zig-llvm build dep (if available).
  if [[ -n "${LLVM_TBLGEN}" ]]; then
    _tblgen_dir=$(dirname "${LLVM_TBLGEN}")
    CMAKE_CROSS_FLAGS+=(-DLLVM_NATIVE_TOOL_DIR="${_tblgen_dir}")
  fi

  # CROSS_TOOLCHAIN_FLAGS_NATIVE: tells LLVM's NATIVE sub-project which
  # compiler to use for building host tools (tablegen etc.).
  # Without this, NATIVE inherits CMAKE_C/CXX_COMPILER which target the
  # cross architecture (e.g. aarch64), producing .exe that can't run on
  # the build host (x86_64).
  # Use the same zig binary but targeting the BUILD host architecture.
  # Create .bat wrappers (NATIVE sub-project uses cmd.exe, not bash).
  if is_not_unix; then
    _host_zig="${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe"
    _host_zig_win=$(echo "${_host_zig}" | sed 's|/|\\|g')
    _host_target="x86_64-windows-gnu"

    _host_cc_bat="${SRC_DIR}/_host_cc.bat"
    cat > "${_host_cc_bat}" << HOSTCC
@echo off
"${_host_zig_win}" cc -target ${_host_target} -mcpu=baseline %*
HOSTCC

    _host_cxx_bat="${SRC_DIR}/_host_cxx.bat"
    cat > "${_host_cxx_bat}" << HOSTCXX
@echo off
"${_host_zig_win}" c++ -target ${_host_target} -mcpu=baseline %*
HOSTCXX

    # AR/RANLIB for NATIVE sub-project — must also use native zig.
    # Can't reference ZIG_AR/ZIG_RANLIB here (set later in the script).
    _host_ar_bat="${SRC_DIR}/_host_ar.bat"
    cat > "${_host_ar_bat}" << HOSTAR
@echo off
"${_host_zig_win}" ar %*
HOSTAR

    _host_ranlib_bat="${SRC_DIR}/_host_ranlib.bat"
    cat > "${_host_ranlib_bat}" << HOSTRANLIB
@echo off
"${_host_zig_win}" ranlib %*
HOSTRANLIB

    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${_host_cc_bat};-DCMAKE_CXX_COMPILER=${_host_cxx_bat};-DCMAKE_AR=${_host_ar_bat};-DCMAKE_RANLIB=${_host_ranlib_bat};-DLLVM_ENABLE_ZSTD=OFF;-DCMAKE_OBJECT_PATH_MAX=1024"
    )
    echo "  HOST_CC: ${_host_cc_bat}"
    echo "  HOST_CXX: ${_host_cxx_bat}"
  fi

  echo "  CMAKE_SYSTEM_NAME: ${CMAKE_SYSTEM_NAME}"
  echo "  LLVM_TABLEGEN: ${LLVM_TBLGEN}"
  echo "  CLANG_TABLEGEN: ${CLANG_TBLGEN}"
  echo "  LLVM_NATIVE_TOOL_DIR: ${_tblgen_dir:-<not set>}"
fi

# Use zig compiler wrappers provided by the zig-compiler package.
# These are pre-built wrappers with flag filtering, sysroot detection, and
# zig-cxx-shared (ld.lld bypass for shared libraries).
# On Windows, conda packages install under Library/
ZIG_WRAPPERS="${BUILD_PREFIX}/share/zig/wrappers"
is_not_unix && ZIG_WRAPPERS="${BUILD_PREFIX}/Library/share/zig/wrappers"
if [[ ! -d "${ZIG_WRAPPERS}" ]]; then
  echo "ERROR: zig wrappers not found at ${ZIG_WRAPPERS}"
  echo "  Is zig-compiler installed as a build dependency?"
  exit 1
fi

if is_not_unix; then
  # Always use the native .exe — zig is a cross-compiler by design.
  # The -target flag handles cross-compilation (e.g. -target aarch64-windows-gnu).
  # .bat/.cmd wrappers break CMake's compiler detection (no version, no ABI info,
  # missing STANDARD_COMPUTED_DEFAULT etc.) so we bypass them entirely.
  _native_zig="${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe"
  if [[ ! -x "${_native_zig}" ]]; then
    echo "ERROR: native zig not found at ${_native_zig}"
    ls "${BUILD_PREFIX}/Library/bin/"*zig* 2>/dev/null || true
    exit 1
  fi
  _zig="${_native_zig}"
  "${_zig}" version

  _target="${ZIG_TRIPLET}"
  export ZIG_CC="${_zig};cc;-target;${_target};-mcpu=baseline"
  export ZIG_CXX="${_zig};c++;-target;${_target};-mcpu=baseline"
  export ZIG_ASM="${_zig};cc;-target;${_target};-mcpu=baseline"
  # AR/RANLIB/RC/CXX_SHARED: use zig _11 activation wrappers directly.
  # zig _11 provides zig-ar.bat, zig-ranlib.bat, zig-rc.bat, and
  # zig-cxx-shared.exe (compiled C, native, arch-aware) via activation.
  export ZIG_AR="${ZIG_WRAPPERS}/zig-ar.bat"
  export ZIG_RANLIB="${ZIG_WRAPPERS}/zig-ranlib.bat"
  export ZIG_RC="${_zig};rc"
  export ZIG_CXX_SHARED="${ZIG_WRAPPERS}/zig-cxx-shared.exe"
else
  export ZIG_CC="${ZIG_WRAPPERS}/zig-cc"
  export ZIG_CXX="${ZIG_WRAPPERS}/zig-cxx"
  export ZIG_CXX_SHARED="${ZIG_WRAPPERS}/zig-cxx-shared"
  export ZIG_AR="${ZIG_WRAPPERS}/zig-ar"
  export ZIG_RANLIB="${ZIG_WRAPPERS}/zig-ranlib"
  export ZIG_ASM="${ZIG_WRAPPERS}/zig-asm"
  export ZIG_RC="${ZIG_WRAPPERS}/zig-rc"
fi

# macOS force-load wrapper: zig _12+ provides zig-force-load-cxx which handles
# -Wl,-all_load/-Wl,-force_load by extracting archives to .o files, in c++ mode.
# Set as CMAKE_CXX_COMPILER so it handles both compile and link commands;
# force-load logic only activates when those flags are present.
#
# TEMPORARY: if zig-force-load-cxx is not yet available (pre-_12), generate it
# from zig-force-load-cc by switching _ZIG_MODE to c++.
# Remove this fallback once zig _12 is live on conda-forge.
if is_osx; then
    if [[ -x "${ZIG_WRAPPERS}/zig-force-load-cxx" ]]; then
        export ZIG_CXX="${ZIG_WRAPPERS}/zig-force-load-cxx"
    elif [[ -x "${ZIG_WRAPPERS}/zig-force-load-cc" ]]; then
        echo "  zig-force-load-cxx not found, generating from zig-force-load-cc (pre-_12 fallback)"
        _fl_cxx="${ZIG_WRAPPERS}/zig-force-load-cxx"
        sed 's/_ZIG_MODE="cc"/_ZIG_MODE="c++"/' "${ZIG_WRAPPERS}/zig-force-load-cc" > "${_fl_cxx}"
        chmod +x "${_fl_cxx}"
        export ZIG_CXX="${_fl_cxx}"
    else
        echo "ERROR: neither zig-force-load-cxx nor zig-force-load-cc found"
        exit 1
    fi

    # MACOS_LINK: system clang for the shared library LINK step.
    # zig cc (BOTH cc and c++ modes) unconditionally injects its bundled static
    # libc++ into every Mach-O .dylib — regardless of -nostdlib++ or driver mode.
    # CI confirmed: zig-force-load-cc (cc mode) still produces LOCAL generic_category.
    # The ONLY fix is to bypass zig entirely for the link step, same as Linux
    # (where zig-cxx-shared calls ld.lld directly).
    # On macOS, we use /usr/bin/clang (system clang) which:
    #   - Does NOT inject zig's bundled libc++
    #   - Handles -all_load/-force_load natively (Apple's ld64 supports these)
    #   - No force-load archive extraction wrapper needed
    #   - Correctly handles cross-arch via -arch flag
    _osx_arch="arm64"
    [[ "${target_platform}" == "osx-64" ]] && _osx_arch="x86_64"
    export MACOS_LINK="/usr/bin/clang"
    if [[ ! -x "${MACOS_LINK}" ]]; then
        echo "ERROR: system clang not found at ${MACOS_LINK}"
        exit 1
    fi
    echo "  MACOS_LINK: ${MACOS_LINK} (arch: ${_osx_arch})"

    # HOTFIX: zig-force-load-cxx has a bug where `ar x` is called after cd'ing
    # to a temp dir, but the archive paths from cmake are RELATIVE to the build dir.
    # `(cd "${_subdir}" && ar x "${_archive}")` — after cd, relative paths break.
    # Result: ALL 142 archives fail to extract silently, libLLVM.dylib ends up empty.
    # Fix: resolve archive paths to absolute before extracting.
    # This patch should be upstreamed to zig-feedstock.
    # NOTE: only ZIG_CXX needs patching now — MACOS_LINK (system clang) doesn't
    # use the force-load wrapper; Apple's ld handles -all_load natively.
    if [[ -f "${ZIG_CXX}" ]]; then
        echo "  Patching $(basename "${ZIG_CXX}"): resolve relative archive paths to absolute"
        python3 -c "
import sys
with open(sys.argv[1]) as f:
    content = f.read()
old = '(cd \"\${_subdir}\" && ar x \"\${_archive}\")'
new = '_abs=\"\${_archive}\"; [[ \"\$_abs\" != /* ]] && _abs=\"\$(pwd)/\$_abs\"; (cd \"\${_subdir}\" && ar x \"\$_abs\")'
if old in content:
    content = content.replace(old, new)
    with open(sys.argv[1], 'w') as f:
        f.write(content)
    print('    OK: patch applied')
else:
    print('    WARNING: target string not found in wrapper')
    sys.exit(1)
" "${ZIG_CXX}"
    fi

    # Patch deployment target in zig wrappers to match conda's MACOSX_DEPLOYMENT_TARGET.
    # _zig-cc-common.sh contains the actual `-target aarch64-macos-none` (or versioned
    # macos.13.0-none in zig 0.15+). zig-force-load-cxx sources this at runtime — it does
    # NOT embed the target itself. zig-cc and zig-cxx have the target in a comment only.
    # ld64 rejects ADRP relocations when objects compiled for a newer target are linked
    # against a .dylib built for an older one (e.g. zig compiles at 13.0, linker at 11.0).
    # Patch _zig-cc-common.sh FIRST (fixes all sourcing wrappers), then individual scripts.
    _deploy_target="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    echo "  Patching zig wrappers: setting macOS deployment target to ${_deploy_target}"
    # _zig-cc-common.sh is sourced by all wrappers and contains the actual
    # -target @ZIG_TARGET@ substitution. zig-force-load-cxx does NOT embed
    # the target directly — it sources _zig-cc-common.sh at runtime.
    # Patching the common script fixes ALL wrappers that source it.
    for _wrapper in "${ZIG_WRAPPERS}/_zig-cc-common.sh" "${ZIG_CXX}" "${ZIG_WRAPPERS}/zig-cc" "${ZIG_WRAPPERS}/zig-cxx"; do
        [[ -f "${_wrapper}" ]] || continue
        # Check if this is a text file (shell script) — binaries cannot be sed-patched
        if ! file "${_wrapper}" | grep -q 'text\|script\|ASCII'; then
            echo "  SKIP $(basename "${_wrapper}"): not a text file (binary?), cannot patch deployment target"
            continue
        fi
        # grep -oE extracts the current macos*-none target triple (if any) for logging
        _before=$(grep -oE 'macos(\.[0-9]+\.[0-9]+)?-none' "${_wrapper}" | head -1 || true)
        # Replace macos-none (unversioned) OR macos.X.Y-none (versioned) with the correct target.
        # Two-pass: versioned first (more specific), then unversioned fallback.
        sed -i.deplbak \
            -e "s/macos\.[0-9][0-9]*\.[0-9][0-9]*-none/macos.${_deploy_target}-none/g" \
            -e "s/macos-none/macos.${_deploy_target}-none/g" \
            "${_wrapper}"
        _after=$(grep -oE 'macos(\.[0-9]+\.[0-9]+)?-none' "${_wrapper}" | head -1 || true)
        if [[ "${_before}" == "${_after}" ]] && [[ -n "${_before}" ]]; then
            echo "  $(basename "${_wrapper}"): no change needed (already: ${_before})"
        elif [[ -z "${_before}" ]]; then
            echo "  $(basename "${_wrapper}"): no macos*-none pattern found (wrapper may use a different format)"
        else
            echo "  $(basename "${_wrapper}"): patched ${_before} -> ${_after}"
        fi
    done

    # Diagnostic: show the macOS target triple in each wrapper used as a compiler
    echo "  === macOS wrapper deployment targets (after patching) ==="
    for _diag_wrapper in "${ZIG_WRAPPERS}/_zig-cc-common.sh" "${ZIG_CXX}" "${ZIG_WRAPPERS}/zig-cc" "${ZIG_WRAPPERS}/zig-cxx" "${ZIG_WRAPPERS}/zig-cxx-shared"; do
        [[ -f "${_diag_wrapper}" ]] || continue
        _diag_target=$(grep -oE 'macos(\.[0-9]+\.[0-9]+)?-none' "${_diag_wrapper}" | head -1 || true)
        echo "  $(basename "${_diag_wrapper}"): ${_diag_target:-<no macos*-none target found>}"
    done
fi

# Clear conda's compiler flags — zig handles optimization internally.
# CMAKE_ARGS: conda-build sets this with architecture-specific flags (e.g.
# -DCMAKE_OSX_ARCHITECTURES=x86_64, -mcpu=core2 for osx-64 cross-builds)
# that conflict with zig's own target/CPU handling.
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS CMAKE_ARGS
export CFLAGS="" CXXFLAGS="" LDFLAGS="" CPPFLAGS=""

dbg "ZIG_TRIPLET: ${ZIG_TRIPLET}"
dbg "ZIG_CC: ${ZIG_CC}"
dbg "ZIG_CXX: ${ZIG_CXX}"
dbg "MACOS_LINK: ${MACOS_LINK:-}"
dbg "ZIG_CXX_SHARED: ${ZIG_CXX_SHARED}"
dbg "ZIG_AR: ${ZIG_AR}"

# LLVM_TRIPLET is set by recipe.yaml env (standard LLVM triple, no glibc version suffix)
dbg "LLVM_TRIPLET: ${LLVM_TRIPLET}"

# Platform-specific CMake flags
CMAKE_PLATFORM_FLAGS=()

is_linux && CMAKE_PLATFORM_FLAGS=(
  -DHAVE_DECL_ARC4RANDOM=0
  -DHAVE_MALLINFO2=0
  -DHAVE_PTHREAD_GETNAME_NP=0
  -DHAVE_PTHREAD_SETNAME_NP=0
  -DLLVM_ENABLE_ZSTD=ON
)
if is_osx; then
  # Determine the correct macOS architecture from the target platform.
  # cmake auto-detects from the host (build) machine, which is wrong for
  # cross-builds (e.g. build=osx-arm64, target=osx-64 → need x86_64).
  _osx_arch="arm64"
  [[ "${target_platform}" == "osx-64" ]] && _osx_arch="x86_64"
  CMAKE_PLATFORM_FLAGS=(
    -DLLVM_ENABLE_ZSTD=ON
    -Dzstd_ROOT="${PREFIX}"
    -DCMAKE_OSX_ARCHITECTURES="${_osx_arch}"
    # zig's Mach-O linker dead-strips LLVMInitialize* and LLVM C API symbols from
    # libLLVM.dylib because nothing inside the dylib references them — they're only
    # called by external consumers (libclang-cpp.dylib, tools). LLVM's own cmake
    # adds -Wl,-dead_strip via add_link_opts(); this knob prevents that.
    -DLLVM_NO_DEAD_STRIP=ON
  )
fi

# non-Unix: path-length workaround, zstd config, and symbol export fixes
is_not_unix && {
    # zstd on conda-forge Windows: only libzstd.dll exists (no import library).
    # conda's zstdConfig.cmake declares zstd::libzstd_shared with IMPORTED_IMPLIB
    # pointing to a non-existent .lib file, causing cmake to error.
    # Disable zstd to avoid the broken cmake config.
    #
    # Symbol export fixes (two patches + dlltool post-processing):
    # - Patch 0004: adds --export-all-symbols to libLLVM (backport from LLVM 22.1.0)
    #   Without this, data symbols (vtables, ::ID) aren't exported.
    # - build.sh Phase 1.5/2.5: zig dlltool regenerates import libs without atexit
    #   (zig's driver rejects --exclude-symbols, so we post-process instead)
    # - CMAKE_SHARED_LINKER_FLAGS: force --export-all-symbols on ALL shared libs
    #   as a belt-and-suspenders with the CMakeLists.txt guards. This ensures
    #   libclang-cpp.dll exports all symbols even if CMake's MINGW detection
    #   doesn't trigger the if(MINGW OR CYGWIN) block.
    CMAKE_PLATFORM_FLAGS=(
      -DCMAKE_OBJECT_PATH_MAX=1024
      -DLLVM_USE_INTEL_JITEVENTS=ON
      -DLLVM_ENABLE_DUMP=ON
      -DLLVM_ENABLE_ZSTD=OFF
      -DLLVM_EXPORT_SYMBOLS_FOR_PLUGINS=OFF
      "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--export-all-symbols"
    )
}

# === BUILD CACHE ===
# For faster iteration on packaging/tests, cache built artifacts in recipe folder
# Cache location: ${RECIPE_DIR}/cache/zig-llvm/
#
# To populate cache from a successful build:
#   cp -r output/bld/rattler-build_zig-llvm_*/host_env_*/lib/zig-llvm recipes/zig-llvm/cache/
#   cp output/bld/rattler-build_zig-llvm_*/host_env_*/lib/zig-llvm-path.txt recipes/zig-llvm/cache/
#
# Set ZIG_LLVM_FORCE_BUILD=1 to ignore cache and rebuild

CACHE_DIR="${RECIPE_DIR}/cache"

if [[ "${ZIG_LLVM_SKIP_BUILD:-0}" == "1" ]] && [[ -d "${CACHE_DIR}" ]] && \
   [[ -x "${CACHE_DIR}/bin/llvm-config" ]] && \
   [[ -n "$(ls "${CACHE_DIR}/lib/"libLLVM*.{dll,dylib,so}* 2>/dev/null | head -1)" ]]; then
  echo "=== USING CACHED LLVM BUILD ==="
  echo "  Cache found at: ${CACHE_DIR}"
  echo "  llvm-config version: $("${CACHE_DIR}/bin/llvm-config" --version)"
  echo ""
  echo "  Copying cache to: ${LLVM_INSTALL}"

  mkdir -p "${PREFIX}/lib"
  cp -a "${CACHE_DIR}" "${LLVM_INSTALL}"
  post_install
  remove_unneeded
  fix_lld_cmake_deps

  # Create marker file
  echo "${LLVM_INSTALL}" > "$(dirname "${LLVM_INSTALL}")/zig-llvm-path.txt"

  echo "  Cache installed successfully!"
  echo "  Set ZIG_LLVM_FORCE_BUILD=1 to rebuild from source"
  ls -la "${LLVM_INSTALL}/lib/"*.so* | head -10
  exit 0
fi

if [[ "${ZIG_LLVM_SKIP_BUILD:-0}" != "1" ]]; then
  echo "=== LLVM Full BUILD (ZIG_LLVM_SKIP_BUILD=0) ==="
elif [[ -d "${CACHE_DIR}" ]]; then
  echo "=== Cache found but incomplete, rebuilding ==="
else
  echo "=== No cache found, building from source ==="
  dbg "To speed up future builds, populate cache after successful build:"
  dbg "  mkdir -p ${RECIPE_DIR}/cache"
  dbg "  cp -r \${PREFIX}/lib/zig-llvm ${RECIPE_DIR}/cache/"
fi

# === Fast flag compatibility test (Unix only) ===
# Simulate the linker flags LLVM's build system will pass on each platform.
# Catches unsupported flags in seconds instead of hours.
# Skipped on Windows: ZIG_CC uses CMake semicolon syntax (zig;cc;-target;...)
# which only works inside CMake, not as a direct bash command.
if is_unix; then
echo "=== Fast flag compatibility test ==="
_test_dir="${SRC_DIR}/_flag_test"
mkdir -p "${_test_dir}"
cat > "${_test_dir}/test.c" << 'TESTC'
int test_func(void) { return 42; }
TESTC

echo "  Compiling test.c..."
"${ZIG_CC}" -c -fPIC -o "${_test_dir}/test.o" "${_test_dir}/test.c"

# Test 1: basic shared library link
echo "  Test 1: basic shared lib link..."
"${ZIG_CC}" -shared -o "${_test_dir}/test.so" "${_test_dir}/test.o" && echo "  OK" || {
    echo "  FAIL: basic shared library link"
    exit 1
}

# Test 2: flags that LLVM's CMake will pass (platform-specific)
_link_flags=()
if is_linux; then
    echo "  Test 2: Linux linker flags (should be silently filtered)..."
    _link_flags=(
        -Wl,--version-script,/dev/null
        -Wl,-z,defs
        -Wl,--gc-sections
        -Wl,--build-id=sha1
        -Wl,-Bsymbolic-functions
    )
elif is_osx; then
    echo "  Test 2a: macOS -all_load via force-load wrapper..."
    # -all_load requires an archive; ZIG_CXX on macOS is the force-load
    # wrapper which extracts archive members and passes .o files to zig
    "${ZIG_AR}" rcs "${_test_dir}/libtest.a" "${_test_dir}/test.o"
    if "${ZIG_CXX}" -shared -Wl,-all_load -o "${_test_dir}/test_allload.dylib" "${_test_dir}/libtest.a" 2>"${_test_dir}/flag_err.txt"; then
        echo "    -Wl,-all_load via wrapper ... OK"
    else
        echo "    -Wl,-all_load via wrapper ... FAIL"
        cat "${_test_dir}/flag_err.txt" | head -5 | sed 's/^/      /'
        _flag_fail=1
    fi
    echo "  Test 2b: macOS flags that should be filtered by hotfix..."
    echo "_test_func" > "${_test_dir}/exports.txt"
    _link_flags=(
        -Wl,-exported_symbols_list,"${_test_dir}/exports.txt"
        -Wl,-force_symbols_not_weak_list,"${_test_dir}/exports.txt"
        -Wl,-force_symbols_weak_list,/dev/null
        -Wl,-reexported_symbols_list,/dev/null
        -Wl,-unexported_symbols_list,/dev/null
    )
fi

# Run each flag individually to identify which one fails
_flag_fail=0
for _flag in "${_link_flags[@]}"; do
    echo -n "    ${_flag} ... "
    if "${ZIG_CC}" -shared -o "${_test_dir}/test_flag.so" "${_test_dir}/test.o" "${_flag}" 2>"${_test_dir}/flag_err.txt"; then
        echo "OK"
    else
        echo "FAIL"
        cat "${_test_dir}/flag_err.txt" | head -5 | sed 's/^/      /'
        _flag_fail=1
    fi
done

if [[ ${_flag_fail} -ne 0 ]]; then
    echo ""
    echo "  ============================================================"
    echo "  EARLY ABORT: linker flag compatibility test failed."
    echo "  One or more flags that LLVM's CMake will pass are not"
    echo "  supported by the zig wrapper. Fix the wrapper filters."
    echo "  ============================================================"
    echo "  Wrapper: ${ZIG_CC}"
    cat "${ZIG_CC}" 2>/dev/null || echo "  (semicolon syntax, no wrapper file)"
    exit 1
fi
echo "  === Flag compatibility test PASSED ==="
rm -rf "${_test_dir}"
fi  # is_unix

# Windows: fast-fail test (~5 seconds) BEFORE any slow builds.
# Validates tools, patches, and (on x86_64) the full DLL export + dlltool pipeline.
#
# DLL creation approaches and their limitations:
#   zig cc -shared:     works on x86_64, but hangs ~100s with empty implibs on aarch64
#   zig ld.lld:         routes to ELF driver, rejects MinGW PE flags (-m i386pep)
#   zig-cxx-shared.exe: thin ld.lld wrapper, needs CRT objects (cmake provides them,
#                        but standalone calls fail with missing DllMainCRTStartup)
#
# Strategy: full DLL pipeline test on x86_64 (zig cc -shared handles CRT).
# On aarch64: validate tools + patches only; cmake handles DLL creation with
# zig-cxx-shared.exe and full CRT context during the real build.
if is_not_unix; then
  echo "=== Fast Windows data-symbol export test ==="
  _stub_dir="${SRC_DIR}/_stub_test"
  mkdir -p "${_stub_dir}"
  _stub_fail=0

  IFS=';' read -ra _zig_cc_args <<< "${ZIG_CC}"
  IFS=';' read -ra _zig_cxx_args <<< "${ZIG_CXX}"
  dbg "ZIG_CC parsed: ${_zig_cc_args[*]}"
  dbg "ZIG_CXX parsed: ${_zig_cxx_args[*]}"

  _zig_bin="${_native_zig:-${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe}"

  # Pre-build tool validation: catch missing tools in ~1 second, before any compilation.
  echo "  Pre-build tool validation..."
  _tools_ok=1
  for _tool in nm awk sed sort; do
    if command -v "${_tool}" >/dev/null 2>&1; then
      dbg "  ${_tool}: OK"
    else
      echo "    ${_tool}: MISSING"
      _tools_ok=0
    fi
  done
  # zig dlltool --help exits non-zero; just check binary is callable
  if _dlltool_out=$("${_zig_bin}" dlltool 2>&1) || [[ "${_dlltool_out}" =~ [Uu]sage|dlltool|error ]]; then
    dbg "  zig dlltool: OK"
  else
    echo "    zig dlltool (${_zig_bin}): MISSING or non-functional"
    _tools_ok=0
  fi
  if [[ ${_tools_ok} -eq 0 ]]; then
    echo "  EARLY ABORT: required tools missing for Windows import lib processing."
    exit 1
  fi
  echo "  Pre-build tool validation PASSED"

  # Verify --export-all-symbols is present in both DLL CMakeLists after patching.
  # Without it, data symbols (vtables, ::ID statics) are silently dropped on MinGW.
  for _shlib_cmake in \
    "${SRC_DIR}/llvm/tools/llvm-shlib/CMakeLists.txt" \
    "${SRC_DIR}/clang/tools/clang-shlib/CMakeLists.txt"; do
    if [[ -f "${_shlib_cmake}" ]]; then
      if grep -q 'export-all-symbols' "${_shlib_cmake}"; then
        echo "    $(basename "$(dirname "${_shlib_cmake}")")/CMakeLists.txt: --export-all-symbols OK"
      else
        echo "  EARLY ABORT: ${_shlib_cmake} missing --export-all-symbols!"
        echo "  Patch 0004 or upstream source must provide this for MinGW DLL builds."
        exit 1
      fi
    fi
  done

  # Full DLL pipeline test: only on x86_64 where zig cc -shared works correctly.
  # On aarch64, zig cc -shared hangs ~100s and produces empty implibs (known zig issue).
  # The aarch64 build uses zig-cxx-shared.exe via cmake which provides full CRT context.
  if [[ "${ZIG_TRIPLET}" != aarch64-* ]]; then
    # a.c: data symbol + function, no dllexport (like libLLVM with auto-export)
    cat > "${_stub_dir}/a.c" << 'ASRC'
int func_a(void) { return 42; }
int global_data = 99;
ASRC
    # b.cpp: imports both function and data from libA, like libclang-cpp from libLLVM
    cat > "${_stub_dir}/b.cpp" << 'BSRC'
extern "C" __declspec(dllimport) int func_a(void);
extern "C" __declspec(dllimport) int global_data;
extern "C" __declspec(dllexport) int func_b(void) { return func_a() + global_data; }
BSRC

    echo "  Compiling..."
    "${_zig_cc_args[@]}" -c -o "${_stub_dir}/a.o" "${_stub_dir}/a.c"
    "${_zig_cxx_args[@]}" -c -o "${_stub_dir}/b.o" "${_stub_dir}/b.cpp"

    # Step 1: Create libA.dll with --export-all-symbols via zig cc -shared.
    # zig cc handles CRT linkage (DllMainCRTStartup) automatically.
    echo "  Step 1: Creating libA.dll with --export-all-symbols (zig cc -shared)..."
    if ! "${_zig_cc_args[@]}" -shared \
        -Wl,--export-all-symbols \
        -Wl,--out-implib,"${_stub_dir}/libA.dll.a" \
        -o "${_stub_dir}/libA.dll" \
        "${_stub_dir}/a.o" 2>"${_stub_dir}/a_err.txt"; then
      echo "    FAIL: cannot create libA.dll"
      head -10 "${_stub_dir}/a_err.txt" | sed 's/^/      /'
      _stub_fail=1
    else
      echo "    OK: libA.dll created"
    fi

    # Step 2: Verify data symbols present, check atexit status
    if [[ ${_stub_fail} -eq 0 ]]; then
      echo "  Step 2: Checking import lib symbols..."
      if _debug; then nm "${_stub_dir}/libA.dll.a" 2>/dev/null | grep -i 'global_data\|func_a\|atexit' | awk 'NR<=10' | sed 's/^/      /' || true; fi
      if nm "${_stub_dir}/libA.dll.a" 2>/dev/null | grep -qi 'global_data'; then
        echo "    OK: data symbol (global_data) present in import lib"
      else
        echo "    FAIL: data symbol missing from import lib!"
        _stub_fail=1
      fi
    fi

    # Step 3: Remove atexit from import lib via strip_atexit_from_implib().
    # The shared function tests the same logic that Phase 1.5 will use on libLLVM —
    # any bug here surfaces in ~5 s instead of ~90 min after the real LLVM build.
    if [[ ${_stub_fail} -eq 0 ]]; then
      echo "  Step 3: Removing atexit from import lib via dlltool (shared function)..."
      if ! strip_atexit_from_implib "${_stub_dir}/libA.dll.a" "${_zig_bin}" "libA"; then
        echo "    FAIL: strip_atexit_from_implib reported an error"
        _stub_fail=1
      else
        # Verify data symbol survived in-place
        if nm "${_stub_dir}/libA.dll.a" 2>/dev/null | grep -qi 'global_data'; then
          echo "    OK: data symbol preserved in regenerated import lib"
        else
          echo "    FAIL: data symbol lost in dlltool regeneration!"
          if _debug; then nm "${_stub_dir}/libA.dll.a" 2>/dev/null | awk 'NR<=20' | sed 's/^/      /' || true; fi
          _stub_fail=1
        fi
      fi
    fi

    # Step 4: Link libB.dll against CLEANED import lib (in-place) — no atexit collision
    if [[ ${_stub_fail} -eq 0 ]]; then
      echo "  Step 4: Linking libB.dll against cleaned import lib (atexit collision test)..."
      if "${_zig_cxx_args[@]}" -shared \
          -o "${_stub_dir}/libB.dll" \
          "${_stub_dir}/b.o" "${_stub_dir}/libA.dll.a" 2>"${_stub_dir}/b_err.txt"; then
        echo "    OK: libB.dll links successfully (no atexit collision, data symbols resolved)"
      else
        echo "    FAIL: libB.dll link failed!"
        awk 'NR<=10' "${_stub_dir}/b_err.txt" | sed 's/^/      /'
        _stub_fail=1
      fi
    fi

    # Step 5: C++ visibility test — catches the 104 missing clang symbols issue.
    # zig cc uses -fvisibility=hidden by default.  --export-all-symbols does NOT
    # export hidden symbols.  Without -fvisibility=default, internal C++ symbols
    # (like clang::SourceManager::getSpellingLocSlowCase) are missing from the
    # import lib, causing 104 undefined symbol errors when zig links against
    # libclang-cpp.dll — after a 3-hour build.  This test catches it in ~2 seconds.
    if [[ ${_stub_fail} -eq 0 ]]; then
      echo "  Step 5: C++ visibility export test (-fvisibility=default)..."
      cat > "${_stub_dir}/cxx_vis.cpp" << 'CXXVIS'
namespace test {
  class Internal {
  public:
    int method() const;
  };
  int Internal::method() const { return 42; }
}
int public_func() { test::Internal i; return i.method(); }
CXXVIS
      # Compile WITH -fvisibility=default (matches our CMAKE_CXX_FLAGS)
      if "${_zig_cxx_args[@]}" -fvisibility=default -c \
          -o "${_stub_dir}/cxx_vis.o" "${_stub_dir}/cxx_vis.cpp" 2>"${_stub_dir}/cxx_vis_err.txt"; then
        echo "    OK: compiled with -fvisibility=default"
      else
        echo "    FAIL: compile failed"
        head -5 "${_stub_dir}/cxx_vis_err.txt" | sed 's/^/      /'
        _stub_fail=1
      fi

      if [[ ${_stub_fail} -eq 0 ]]; then
        # Link DLL with --export-all-symbols (same as our CMAKE_SHARED_LINKER_FLAGS)
        if "${_zig_cc_args[@]}" -shared \
            -Wl,--export-all-symbols \
            -Wl,--out-implib,"${_stub_dir}/cxx_vis.dll.a" \
            -o "${_stub_dir}/cxx_vis.dll" \
            "${_stub_dir}/cxx_vis.o" 2>"${_stub_dir}/cxx_vis_link_err.txt"; then
          echo "    OK: cxx_vis.dll created"
        else
          echo "    FAIL: DLL link failed"
          head -5 "${_stub_dir}/cxx_vis_link_err.txt" | sed 's/^/      /'
          _stub_fail=1
        fi
      fi

      if [[ ${_stub_fail} -eq 0 ]]; then
        # Check that the C++ class method is exported in the import lib
        _method_sym=$(nm "${_stub_dir}/cxx_vis.dll.a" 2>/dev/null | grep 'Internal.*method\|method.*Internal' || true)
        _public_sym=$(nm "${_stub_dir}/cxx_vis.dll.a" 2>/dev/null | grep 'public_func' || true)
        dbg "method sym: ${_method_sym:-<none>}"
        dbg "public sym: ${_public_sym:-<none>}"
        if [[ -n "${_method_sym}" ]]; then
          echo "    OK: C++ class method (Internal::method) exported in import lib"
        else
          echo "    FAIL: C++ class method NOT in import lib!"
          echo "    This means -fvisibility=default is not working."
          echo "    Without it, libclang-cpp.dll will be missing ~104 internal clang symbols"
          echo "    and zig will fail to link with 'lld-link: undefined symbol: clang::SourceManager::...'"
          echo "    All symbols in import lib:"
          nm "${_stub_dir}/cxx_vis.dll.a" 2>/dev/null | head -20 | sed 's/^/      /' || true
          _stub_fail=1
        fi
        if [[ -n "${_public_sym}" ]]; then
          echo "    OK: public_func exported"
        else
          echo "    FAIL: even public_func missing — --export-all-symbols broken?"
          _stub_fail=1
        fi
      fi
    fi
  else
    # aarch64: zig cc -shared is broken, but we MUST test strip_atexit_from_implib
    # using the strings extraction path (nm can't read aarch64 import libs).
    # Create a synthetic import lib via zig dlltool, inject atexit, and verify the
    # strip function works. This catches extraction bugs in ~2s, not after 2hrs.
    echo "  aarch64: Testing strip_atexit_from_implib with synthetic import lib..."

    # Create a .def file with known symbols + atexit (simulating --export-all-symbols leak)
    cat > "${_stub_dir}/test.def" << 'DEFEOF'
LIBRARY libTest.dll
EXPORTS
  func_a
  global_data
  atexit
  LLVMInitializeAArch64Target
DEFEOF

    # Generate import lib from .def via zig dlltool
    # Compute machine type: zig dlltool defaults to host (x86_64), so pass -m for aarch64 targets.
    # IMPORTANT: use a bash array for _m_flag to avoid the ${var:+-m "${var}"} single-token bug.
    # The ${var:+-m "${var}"} expansion passes '-m arm64' as ONE argument (quotes prevent word
    # splitting inside :+word), causing zig dlltool to fail with "unknown target".
    _dlltool_m_flag=()
    if [[ "${ZIG_TRIPLET}" == aarch64-* ]]; then
      _dlltool_m_flag=(-m arm64)
    elif [[ "${ZIG_TRIPLET}" == x86_64-* ]]; then
      _dlltool_m_flag=(-m "i386:x86-64")
    fi
    if ! "${_zig_bin}" dlltool -d "${_stub_dir}/test.def" -l "${_stub_dir}/libTest.dll.a" \
        -D "libTest.dll" "${_dlltool_m_flag[@]}" 2>"${_stub_dir}/dlltool_err.txt"; then
      echo "    FAIL: zig dlltool cannot create test import lib"
      head -5 "${_stub_dir}/dlltool_err.txt" | sed 's/^/      /'
      _stub_fail=1
    fi

    # Verify atexit is in the synthetic import lib (sanity check)
    if [[ ${_stub_fail} -eq 0 ]]; then
      if strings -a "${_stub_dir}/libTest.dll.a" 2>/dev/null | grep -qx 'atexit'; then
        echo "    OK: synthetic import lib contains atexit (test precondition met)"
      else
        echo "    FAIL: synthetic import lib missing atexit — test is broken"
        _stub_fail=1
      fi
    fi

    # Run strip_atexit_from_implib (exercises strings detection + extraction path)
    if [[ ${_stub_fail} -eq 0 ]]; then
      echo "  Running strip_atexit_from_implib on synthetic import lib..."
      if ! strip_atexit_from_implib "${_stub_dir}/libTest.dll.a" "${_zig_bin}" "libTest" "arm64"; then
        echo "    FAIL: strip_atexit_from_implib reported an error"
        _stub_fail=1
      fi
    fi

    # Verify: atexit gone, other symbols preserved
    if [[ ${_stub_fail} -eq 0 ]]; then
      if strings -a "${_stub_dir}/libTest.dll.a" 2>/dev/null | grep -qx 'atexit'; then
        echo "    FAIL: atexit still present after strip!"
        _stub_fail=1
      else
        echo "    OK: atexit removed"
      fi
      if strings -a "${_stub_dir}/libTest.dll.a" 2>/dev/null | grep -qx 'func_a'; then
        echo "    OK: func_a preserved"
      else
        echo "    FAIL: func_a lost during strip!"
        _stub_fail=1
      fi
      if strings -a "${_stub_dir}/libTest.dll.a" 2>/dev/null | grep -qx 'LLVMInitializeAArch64Target'; then
        echo "    OK: LLVMInitializeAArch64Target preserved"
      else
        echo "    FAIL: LLVMInitializeAArch64Target lost during strip!"
        _stub_fail=1
      fi
    fi

    if [[ ${_stub_fail} -eq 0 ]]; then
      echo "  aarch64 strip_atexit_from_implib test PASSED"
    fi
  fi

  if [[ ${_stub_fail} -ne 0 ]]; then
    echo "  EARLY ABORT: Windows data-symbol export test failed."
    rm -rf "${_stub_dir}"
    exit 1
  fi
  echo "  === Windows data-symbol export test PASSED ==="
  rm -rf "${_stub_dir}"
fi

mkdir -p "${LLVM_BUILD}"

if is_unix || is_not_unix; then
  echo "=== Building libc++/libc++abi/libunwind with zig cc ==="
  # Build runtimes BEFORE LLVM so shared libraries (libLLVM.so/.dylib/.dll)
  # link against the already-installed shared libc++ instead of zig bundling
  # a static copy into each one.
  LIBCXX_SRC="${SRC_DIR}/runtimes"

  _RUNTIMES_CMAKE=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}"
    -DCMAKE_C_COMPILER="${ZIG_CC}"
    -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
    -DCMAKE_ASM_COMPILER="${ZIG_ASM}"
    -DCMAKE_AR="${ZIG_AR}"
    -DCMAKE_RANLIB="${ZIG_RANLIB}"
  )

  # Runtimes to build and platform-specific flags.
  # libc++abi is statically merged into libc++ on ALL platforms for consistency:
  #   - Windows REQUIRES it (circular dependency, no lazy binding)
  #   - Unix BENEFITS from it (fewer dylibs to manage, eliminates @rpath/libc++abi
  #     reference, simplifies post-install fixups, matches zig's own bundling model)
  _RUNTIMES_LIST="libcxxabi;libcxx"
  _RUNTIMES_FLAGS=(
    -DLIBCXXABI_ENABLE_SHARED=OFF
    -DLIBCXXABI_ENABLE_STATIC=ON
    -DLIBCXXABI_USE_COMPILER_RT=ON
    -DLIBCXX_ENABLE_SHARED=ON
    -DLIBCXX_ENABLE_STATIC=OFF
    -DLIBCXX_STATICALLY_LINK_ABI_IN_SHARED_LIBRARY=ON
    -DLIBCXX_USE_COMPILER_RT=ON
    -DLIBCXX_CXX_ABI=libcxxabi
  )

  # libunwind provides _Unwind_* symbols needed by libc++abi's exception handling.
  # On Unix: DWARF unwinding. On MinGW: SEH-based unwinding (libunwind has a SEH adapter).
  # Without it, -nostdlib++ (used by runtimes CMake) strips zig's bundled unwind.
  _RUNTIMES_LIST="libunwind;${_RUNTIMES_LIST}"
  _RUNTIMES_FLAGS+=(
    -DLIBUNWIND_ENABLE_SHARED=ON
    -DLIBUNWIND_ENABLE_STATIC=OFF
    -DLIBUNWIND_USE_COMPILER_RT=ON
    -DLIBCXXABI_USE_LLVM_UNWINDER=ON
  )

  if is_unix; then
    # Override zig cc's default -fvisibility=hidden so libc++ symbols are public
    # and genuinely shared between libLLVM.so and libclang-cpp.so.
    _RUNTIMES_CMAKE+=(
      -DCMAKE_C_FLAGS="-fvisibility=default"
      -DCMAKE_CXX_FLAGS="-fvisibility=default"
      -DCMAKE_SKIP_RPATH=ON
    )
    _RUNTIMES_CMAKE+=(-DLLVM_CONFIG_PATH="${BUILD_PREFIX}/bin/llvm-config")
  fi

  if is_not_unix; then
    # MinGW: Win32 threading API (no pthreads on Windows)
    _RUNTIMES_FLAGS+=(
      -DLIBCXX_HAS_WIN32_THREAD_API=ON
      -DLIBCXXABI_HAS_WIN32_THREAD_API=ON
      -DLIBCXX_HAS_PTHREAD_API=OFF
      -DLIBCXXABI_HAS_PTHREAD_API=OFF
    )
    _RUNTIMES_CMAKE+=(
      -DCMAKE_C_FLAGS="-fvisibility=default"
      -DCMAKE_CXX_FLAGS="-fvisibility=default"
    )
  fi

  # macOS: tell cmake the correct arch (prevents -mcpu=core2 on cross-builds)
  if is_osx; then
    _RUNTIMES_CMAKE+=(-DCMAKE_OSX_ARCHITECTURES="${_osx_arch}")
  fi

  echo "  Building runtimes: ${_RUNTIMES_LIST}..."
  mkdir -p "${SRC_DIR}/conda-runtimes-build"

  # Runtimes build is now fatal on all platforms — no silent failures.
  cmake -S "${LIBCXX_SRC}" -B "${SRC_DIR}/conda-runtimes-build" \
    "${_RUNTIMES_CMAKE[@]}" \
    -DLLVM_ENABLE_RUNTIMES="${_RUNTIMES_LIST}" \
    "${_RUNTIMES_FLAGS[@]}" \
    -G Ninja
  cmake --build "${SRC_DIR}/conda-runtimes-build" -j"${CPU_COUNT}"
  cmake --install "${SRC_DIR}/conda-runtimes-build"

  echo "  libc++ runtimes installed to ${LLVM_INSTALL}/lib"

  # === Verify libc++ runtimes ===
  echo "=== Verifying libc++ runtime installation ==="
  ls -la "${LLVM_INSTALL}/lib/"libc++* 2>/dev/null || true
  if is_not_unix; then
    # Windows: expect .dll + .dll.a (import library)
    ls -la "${LLVM_INSTALL}/bin/"libc++* 2>/dev/null || true
  fi

fi

# macOS: create a linker wrapper script that physically filters out zig's
# bundled static libc++.a and libc++abi.a from cmake's <LINK_LIBRARIES>
# expansion before calling system clang.
#
# WHY: cmake detects zig c++'s implicit link libraries (including the full path
# to zig's bundled libc++.a) and injects them into <LINK_LIBRARIES> for every
# shared library link rule.  When system clang receives zig's libc++.a as a
# positional argument it statically merges the archive — making
# generic_category LOCAL_DEFINED instead of imported from libc++.dylib.
#
# WHAT FAILED:
#   1. -DCMAKE_CXX_IMPLICIT_LINK_LIBRARIES="" — cmake stores the implicit link
#      libs as an INTERNAL cache variable during compiler detection; -D creates
#      a NORMAL entry that is silently ignored in favour of the INTERNAL one.
#   2. CMAKE_PROJECT_INCLUDE with CACHE INTERNAL FORCE — cmake's internal data
#      structure is separate from the cache; the FORCE override did not take.
#   3. Post-configure sed on build.ninja — unclear if pattern matched; fragile.
#
# FIX: wrapper script physically removes *libc++.a and *libc++abi.a from argv
# before exec-ing /usr/bin/clang.  This is 100% guaranteed to work regardless
# of cmake's internal cache behaviour.  The wrapper is baked into the cmake
# CMAKE_CXX_CREATE_SHARED_LIBRARY template (shell expands ${SRC_DIR} at cmake
# invocation time — cmake receives the fully expanded absolute path).
if is_osx; then
  # MACOS_LINK_LOG: file-based logging for the link wrapper.
  # ninja suppresses stderr of successful commands, so we cannot use >&2.
  # Writing to a file guarantees we can inspect ALL link invocations after the build.
  export MACOS_LINK_LOG="${SRC_DIR}/macos_link_commands.log"
  : > "${MACOS_LINK_LOG}"   # truncate / create empty

  cat > "${SRC_DIR}/macos-link-wrapper.sh" << 'LINKWRAP'
#!/bin/bash
# Wrapper around /usr/bin/clang for shared library linking on macOS.
# Filters out zig's bundled static libc++.a and libc++abi.a from cmake's
# <LINK_LIBRARIES> expansion. cmake injects these via CMAKE_CXX_IMPLICIT_LINK_LIBRARIES
# which we cannot reliably clear (tried -D, FORCE, sed — none worked).
#
# System clang gets -lc++ from the template (resolves to our shared
# libc++.dylib), so the static archives are redundant AND harmful (they cause
# LOCAL_DEFINED generic_category which breaks zig's RTTI check).
#
# NOTE: all output goes to MACOS_LINK_LOG (a file) because ninja eats stderr
# on success.  stderr messages appear only for failed commands.
_logfile="${MACOS_LINK_LOG:-/tmp/macos_link_commands.log}"
echo "=== $(date -u '+%H:%M:%S') ===" >> "$_logfile"
echo "ARGS: $*" >> "$_logfile"
echo "---" >> "$_logfile"
args=()
skipped=0
for arg in "$@"; do
  case "$arg" in
    *libc++.a|*libc++abi.a)
      echo "SKIPPED: $arg" >> "$_logfile"
      echo "  [macos-link-wrapper] skipping static libc++: $arg" >&2
      skipped=$((skipped + 1))
      ;;
    -Wl,--color-diagnostics|--color-diagnostics|-Wl,--no-color-diagnostics|--no-color-diagnostics)
      # LLVM's cmake detects zig as lld-capable and injects --color-diagnostics.
      # Apple's ld64-classic doesn't understand this flag.  Filter it out.
      echo "SKIPPED: $arg (lld-only flag)" >> "$_logfile"
      skipped=$((skipped + 1))
      ;;
    *)
      args+=("$arg")
      ;;
  esac
done
if [[ $skipped -gt 0 ]]; then
  echo "  [macos-link-wrapper] filtered $skipped static libc++ archive(s)" >&2
  echo "FILTERED: $skipped archive(s)" >> "$_logfile"
fi
echo "EXEC: /usr/bin/clang ${args[*]}" >> "$_logfile"
# Unset LIBRARY_PATH so system clang doesn't search conda prefix paths.
# conda-build sets LIBRARY_PATH=$BUILD_PREFIX/lib:$PREFIX/lib which contains
# the conda libcxx package's libc++.a — if ld64 finds it, it statically links
# libc++ instead of using our shared libc++.dylib from LLVM_INSTALL/lib.
unset LIBRARY_PATH
exec /usr/bin/clang "${args[@]}"
LINKWRAP
  chmod +x "${SRC_DIR}/macos-link-wrapper.sh"
  echo "  Created macos-link-wrapper.sh (logging to ${MACOS_LINK_LOG})"

  # Remove static libc++ archives from conda prefix paths.
  # conda-forge zig depends on libcxx which installs libc++.a in $BUILD_PREFIX/lib.
  # Even with our -L${LLVM_INSTALL}/lib first, LIBRARY_PATH=$BUILD_PREFIX/lib
  # (set by conda-build) causes ld64 to find the conda .a before our .dylib.
  # We also unset LIBRARY_PATH in the wrapper, but belt-and-suspenders.
  for _conda_lib_dir in "${BUILD_PREFIX}/lib" "${PREFIX}/lib"; do
    for _static_lib in libc++.a libc++abi.a; do
      if [[ -f "${_conda_lib_dir}/${_static_lib}" ]]; then
        echo "  Moving conda ${_static_lib} out of ${_conda_lib_dir}"
        mv "${_conda_lib_dir}/${_static_lib}" "/tmp/${_static_lib}.conda_bak_$$"
      fi
    done
  done
fi

_CLANG=(
  -DCLANG_ENABLE_OBJC_REWRITER=ON
  -DCLANG_LINK_CLANG_DYLIB=ON

  -DCLANG_BUILD_TOOLS=OFF
  -DCLANG_ENABLE_ARCMT=OFF
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF
  -DCLANG_INCLUDE_DOCS=OFF
  -DCLANG_INCLUDE_TESTS=OFF
  -DCLANG_TOOL_APINOTES_TEST_BUILD=OFF
  -DCLANG_TOOL_CLANG_DIFF_BUILD=OFF
  -DCLANG_TOOL_CLANG_IMPORT_TEST_BUILD=OFF
  -DCLANG_TOOL_CLANG_LINKER_WRAPPER_BUILD=OFF
  -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF
  -DCLANG_TOOL_LIBCLANG_BUILD=OFF
)

_LLVM=(
  # LLVM_BUILD_TOOLS=ON with individual disables. Both ON and OFF are "leaky":
  # ON requires explicit disables per tool (whack-a-mole on LLVM bumps).
  # OFF prevents cmake --install from installing even whitelisted tools.
  # ON + explicit list is the lesser evil — at least llvm-config gets installed.
  -DLLVM_BUILD_TOOLS=ON
  -DLLVM_TOOL_LLVM_CONFIG_BUILD=ON
  -DLLVM_BUILD_LLVM_DYLIB=ON
  -DLLVM_DYLIB_COMPONENTS="all"
  -DLLVM_ENABLE_LIBCXX=ON
  -DLLVM_ENABLE_LIBXML2=ON
  -DLLVM_ENABLE_PROJECTS="clang;lld"
  -DLLVM_ENABLE_RTTI=ON
  -DLLVM_ENABLE_ZLIB=ON
  -DLLVM_LINK_LLVM_DYLIB=ON
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64;ARM;PowerPC;RISCV;WebAssembly;SystemZ;AMDGPU;AVR;NVPTX"

  -DLLVM_DEFAULT_TARGET_TRIPLE="${LLVM_TRIPLET}"
  -DLLVM_BUILD_UTILS=OFF
  -DLLVM_ENABLE_ASSERTIONS=OFF
  -DLLVM_ENABLE_BACKTRACES=OFF
  -DLLVM_ENABLE_BINDINGS=OFF
  -DLLVM_ENABLE_CRASH_OVERRIDES=OFF
  -DLLVM_ENABLE_LIBEDIT=OFF
  -DLLVM_ENABLE_LIBPFM=OFF
  -DLLVM_ENABLE_OCAMLDOC=OFF
  -DLLVM_ENABLE_PLUGINS=OFF
  -DLLVM_ENABLE_Z3_SOLVER=OFF
  -DLLVM_HAS_LOGF128=OFF
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_DOCS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INCLUDE_UTILS=OFF
  -DLLVM_INSTALL_TOOLCHAIN_ONLY=OFF
  # Disable ALL tools except llvm-config and llvm-shlib (libLLVM.so/.dylib).
  # Generated from LLVM 20.1.8 llvm/tools/ source tree (add_llvm_implicit_projects
  # auto-discovers every subdirectory with CMakeLists.txt via file(GLOB)).
  # LLVM_BUILD_TOOLS=ON is REQUIRED — OFF prevents cmake --install from installing
  # even whitelisted tools. Individual LLVM_TOOL_*_BUILD=OFF skips add_subdirectory()
  # entirely (no configure, no build, no install).
  # On macOS: tools linking against libLLVM.dylib fail (zig cc visibility issue).
  # On Windows: saves ~60min build time.
  # KEEP: llvm-config (ON above), llvm-shlib (builds libLLVM shared library)
  -DLLVM_TOOL_BUGPOINT_BUILD=OFF
  -DLLVM_TOOL_BUGPOINT_PASSES_BUILD=OFF
  -DLLVM_TOOL_DSYMUTIL_BUILD=OFF
  -DLLVM_TOOL_DXIL_DIS_BUILD=OFF
  -DLLVM_TOOL_GOLD_BUILD=OFF
  -DLLVM_TOOL_LLC_BUILD=OFF
  -DLLVM_TOOL_LLI_BUILD=OFF
  -DLLVM_TOOL_LLVM_AR_BUILD=OFF
  -DLLVM_TOOL_LLVM_AS_BUILD=OFF
  -DLLVM_TOOL_LLVM_AS_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_BCANALYZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_C_TEST_BUILD=OFF
  -DLLVM_TOOL_LLVM_CAT_BUILD=OFF
  -DLLVM_TOOL_LLVM_CFI_VERIFY_BUILD=OFF
  -DLLVM_TOOL_LLVM_CGDATA_BUILD=OFF
  -DLLVM_TOOL_LLVM_COV_BUILD=OFF
  -DLLVM_TOOL_LLVM_CTXPROF_UTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_CVTRES_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXFILT_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXMAP_BUILD=OFF
  -DLLVM_TOOL_LLVM_DEBUGINFO_ANALYZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_DEBUGINFOD_BUILD=OFF
  -DLLVM_TOOL_LLVM_DEBUGINFOD_FIND_BUILD=OFF
  -DLLVM_TOOL_LLVM_DIFF_BUILD=OFF
  -DLLVM_TOOL_LLVM_DIS_BUILD=OFF
  -DLLVM_TOOL_LLVM_DIS_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_DLANG_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_DRIVER_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWARFDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWARFUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWP_BUILD=OFF
  -DLLVM_TOOL_LLVM_EXEGESIS_BUILD=OFF
  -DLLVM_TOOL_LLVM_EXTRACT_BUILD=OFF
  -DLLVM_TOOL_LLVM_GSYMUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_IFS_BUILD=OFF
  -DLLVM_TOOL_LLVM_ISEL_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_ITANIUM_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_JITLINK_BUILD=OFF
  -DLLVM_TOOL_LLVM_JITLISTENER_BUILD=OFF
  -DLLVM_TOOL_LLVM_LIBTOOL_DARWIN_BUILD=OFF
  -DLLVM_TOOL_LLVM_LINK_BUILD=OFF
  -DLLVM_TOOL_LLVM_LIPO_BUILD=OFF
  -DLLVM_TOOL_LLVM_LTO_BUILD=OFF
  -DLLVM_TOOL_LLVM_LTO2_BUILD=OFF
  -DLLVM_TOOL_LLVM_MC_BUILD=OFF
  -DLLVM_TOOL_LLVM_MC_ASSEMBLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_MC_DISASSEMBLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_MCA_BUILD=OFF
  -DLLVM_TOOL_LLVM_MICROSOFT_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_ML_BUILD=OFF
  -DLLVM_TOOL_LLVM_MODEXTRACT_BUILD=OFF
  -DLLVM_TOOL_LLVM_MT_BUILD=OFF
  -DLLVM_TOOL_LLVM_NM_BUILD=OFF
  -DLLVM_TOOL_LLVM_OBJCOPY_BUILD=OFF
  -DLLVM_TOOL_LLVM_OBJDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_OPT_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_OPT_REPORT_BUILD=OFF
  -DLLVM_TOOL_LLVM_PDBUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_PROFDATA_BUILD=OFF
  -DLLVM_TOOL_LLVM_PROFGEN_BUILD=OFF
  -DLLVM_TOOL_LLVM_RC_BUILD=OFF
  -DLLVM_TOOL_LLVM_READOBJ_BUILD=OFF
  -DLLVM_TOOL_LLVM_READTAPI_BUILD=OFF
  -DLLVM_TOOL_LLVM_REDUCE_BUILD=OFF
  -DLLVM_TOOL_LLVM_REMARKUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_RTDYLD_BUILD=OFF
  -DLLVM_TOOL_LLVM_RUST_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_SIM_BUILD=OFF
  -DLLVM_TOOL_LLVM_SIZE_BUILD=OFF
  -DLLVM_TOOL_LLVM_SPECIAL_CASE_LIST_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_SPLIT_BUILD=OFF
  -DLLVM_TOOL_LLVM_STRESS_BUILD=OFF
  -DLLVM_TOOL_LLVM_STRINGS_BUILD=OFF
  -DLLVM_TOOL_LLVM_SYMBOLIZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_TLI_CHECKER_BUILD=OFF
  -DLLVM_TOOL_LLVM_UNDNAME_BUILD=OFF
  -DLLVM_TOOL_LLVM_XRAY_BUILD=OFF
  -DLLVM_TOOL_LLVM_YAML_NUMERIC_PARSER_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_YAML_PARSER_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LTO_BUILD=OFF
  -DLLVM_TOOL_OBJ2YAML_BUILD=OFF
  -DLLVM_TOOL_OPT_BUILD=OFF
  -DLLVM_TOOL_OPT_VIEWER_BUILD=OFF
  -DLLVM_TOOL_REDUCE_CHUNK_LIST_BUILD=OFF
  -DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF
  -DLLVM_TOOL_SANCOV_BUILD=OFF
  -DLLVM_TOOL_SANSTATS_BUILD=OFF
  -DLLVM_TOOL_SPIRV_TOOLS_BUILD=OFF
  -DLLVM_TOOL_VERIFY_USELISTORDER_BUILD=OFF
  -DLLVM_TOOL_VFABI_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_XCODE_TOOLCHAIN_BUILD=OFF
  -DLLVM_TOOL_YAML2OBJ_BUILD=OFF
)

echo "=== Configuring LLVM ==="
echo "  Install prefix: ${LLVM_INSTALL} (separate from conda-forge llvmdev)"
_CMAKE=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}"
  -DCMAKE_PREFIX_PATH="${LLVM_INSTALL};${PREFIX};${BUILD_PREFIX}"
  -DCMAKE_LINK_DEPENDS_USE_LINKER=OFF

  -DCMAKE_AR="${ZIG_AR}"
  -DCMAKE_C_COMPILER="${ZIG_CC}"
  -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
  -DCMAKE_ASM_COMPILER="${ZIG_ASM}"
  -DCMAKE_RANLIB="${ZIG_RANLIB}"

  # Rpath settings - build tools (llvm-min-tblgen, etc) need to find conda libs at runtime
  # LLVM_BUILD/lib is where libLLVM.so lives during the build phase - required so
  # libclang-cpp.so links against it by bare soname (not a relative lib/ path).
  -DCMAKE_BUILD_RPATH="${LLVM_INSTALL}/lib;${LLVM_BUILD}/lib;${BUILD_PREFIX}/lib;${PREFIX}/lib"
  -DCMAKE_INSTALL_RPATH="${LLVM_INSTALL}/lib"

  # Shared library link rule override (Unix only): use zig-cxx-shared wrapper
  # instead of zig c++ for creating .so files.  zig cc/c++ ALWAYS auto-merge
  # zig's bundled static hidden-visibility libc++ into every .so at link time.
  # The zig-cxx-shared wrapper bypasses zig entirely and invokes ld.lld directly
  # for the shared library link step, so libc++.so.1 appears in NEEDED and
  # generic_category resolves from the single shared copy at runtime.
  # On non-Unix, zig c++ links .dll files normally (no libc++ dual-copy issue).
)

# RC compiler (resource compiler for Windows .exe version info).
# On Windows, Platform/Windows-GNU.cmake auto-enables RC language during
# project(). CMake 4.2 converts ALL paths to native backslashes, then chokes
# on escape sequences (\a from D:\a\..., \p from \package-..., etc.) when
# writing CMakeRCCompiler.cmake. EVERY Windows CI path triggers this.
# Semicolon syntax ("zig;rc") also fails — get_filename_component treats
# "rc" as a component arg.
#
# Since we use zig (Clang, not MSVC), the RC resource is never compiled
# (add_windows_version_resource_file guards on MSVC).
# Fix: use _BUILD_PREFIX (forward-slash unix path) in the -C initial-cache
# script. Forward slashes have no escape issues in CMake string literals.
# Two cmake script files:
#
# 1. _cmake_init.cmake: initial-cache file (-C). For CACHE variables only
#    (e.g. RC compiler). Loaded before project().
#
# 2. _cmake_project_include.cmake: project include file
#    (-DCMAKE_PROJECT_INCLUDE=...). Runs as the LAST step of project(),
#    AFTER all language initialization and platform modules.
#    Sets CMAKE_CXX_CREATE_SHARED_LIBRARY as a normal variable in the
#    top-level project scope — guaranteed to override any platform default.
#
#    Approaches that FAILED (CI confirmed):
#    - -D: creates :UNINITIALIZED cache entry, overridden by platform module
#      (win-64, 2026-03-21)
#    - -C with CACHE FORCE: cache var overridden by normal var from platform
#      module (osx-arm64, 2026-03-22)
#    - CMAKE_USER_MAKE_RULES_OVERRIDE: loaded during language init but
#      overridden by later platform module processing (osx-arm64, 2026-03-22)
_cmake_init="${SRC_DIR}/_cmake_init.cmake"
_cmake_project_include="${SRC_DIR}/_cmake_project_include.cmake"
: > "${_cmake_init}"
: > "${_cmake_project_include}"
# Diagnostic: cmake will print this message if the project include file is read.
cat >> "${_cmake_project_include}" << 'CMINIT'
message(STATUS ">>> CMAKE_PROJECT_INCLUDE: file loaded successfully")
CMINIT

CMAKE_RC_FLAGS=()
if is_not_unix; then
  # _BUILD_PREFIX: forward-slash unix path version of BUILD_PREFIX,
  # created by build.bat (e.g. /d/a/package-incubator/.../build_env).
  _rc_path="${_BUILD_PREFIX}/Library/share/zig/wrappers/zig-rc.bat"
  cat >> "${_cmake_init}" << CMINIT
# RC compiler with forward-slash path — avoids CMake 4.2 backslash escape bug.
set(CMAKE_RC_COMPILER "${_rc_path}" CACHE FILEPATH "RC compiler")
set(CMAKE_RC_COMPILER_WORKS TRUE CACHE BOOL "RC compiler works")
CMINIT
elif [[ -n "${ZIG_RC:-}" ]]; then
  CMAKE_RC_FLAGS=(-DCMAKE_RC_COMPILER="${ZIG_RC}")
fi

# All platforms: override shared library link rule to bypass zig for linking.
# zig cc (all modes) injects its bundled static libc++ into shared libraries,
# which breaks zig's own ZigClangIsLLVMUsingSeparateLibcxx() RTTI check.
# Linux: zig-cxx-shared calls ld.lld directly (ELF).
# macOS: system clang (/usr/bin/clang) calls Apple's ld64 directly.
# Windows: zig-cxx-shared.exe calls ld.lld directly (PE/COFF).
CMAKE_SHARED_FLAGS=()
if [[ -n "${ZIG_CXX_SHARED:-}" ]] && is_linux; then
    # Linux: override link rule (normal variable, not cache)
    cat >> "${_cmake_project_include}" << CMINIT
set(CMAKE_CXX_CREATE_SHARED_LIBRARY "${ZIG_CXX_SHARED} <CMAKE_SHARED_LIBRARY_CXX_FLAGS> <LINK_FLAGS> <CMAKE_SHARED_LIBRARY_CREATE_CXX_FLAGS> <SONAME_FLAG><TARGET_SONAME> -o <TARGET> <OBJECTS> <LINK_LIBRARIES>")
set(CMAKE_CXX_CREATE_SHARED_LIBRARY "\${CMAKE_CXX_CREATE_SHARED_LIBRARY}" CACHE STRING "CXX shared library link rule" FORCE)
message(STATUS ">>> CMAKE_CXX_CREATE_SHARED_LIBRARY set to: \${CMAKE_CXX_CREATE_SHARED_LIBRARY}")
CMINIT
    CMAKE_SHARED_FLAGS=(
      -DCMAKE_SHARED_LINKER_FLAGS="-L${LLVM_INSTALL}/lib -lc++"
      -DCMAKE_EXE_LINKER_FLAGS="-L${LLVM_INSTALL}/lib -lc++"
    )
elif is_osx; then
    # macOS: use macos-link-wrapper.sh for shared library linking.
    #
    # zig cc (BOTH cc and c++ modes) unconditionally injects its bundled static
    # libc++ into Mach-O .dylib files, regardless of -nostdlib++.  CI confirmed
    # on both osx-arm64 and osx-64.  The ONLY fix is to bypass zig entirely.
    #
    # macos-link-wrapper.sh (created above) filters out *libc++.a/*libc++abi.a
    # from argv before exec-ing /usr/bin/clang.  This handles cmake's injection
    # of zig's static libc++ via CMAKE_CXX_IMPLICIT_LINK_LIBRARIES into
    # <LINK_LIBRARIES>.  Approaches that FAILED to clear this variable:
    #   - -DCMAKE_CXX_IMPLICIT_LINK_LIBRARIES="" — creates a NORMAL cache entry,
    #     silently ignored in favour of the INTERNAL one set during compiler detection
    #   - CMAKE_PROJECT_INCLUDE with CACHE INTERNAL FORCE — cmake's internal data
    #     structure is separate from the cache; the override did not take effect
    #   - Post-configure sed on build.ninja — fragile; uncertain if it matched
    #
    # -fvisibility=default: zig compiles with hidden visibility by default.
    # On Mach-O, hidden symbols are truly invisible to other dylibs.
    # Without this, libclang-cpp.dylib can't see libLLVM.dylib's symbols.
    #
    # -arch: ensure correct target architecture for cross-builds (e.g. arm64 → x86_64).
    # cmake may not propagate CMAKE_OSX_ARCHITECTURES into custom link rules.
    #
    # Compilation still uses zig-force-load-cxx (c++ mode) via CMAKE_CXX_COMPILER.
    #
    # CRITICAL: -L -lc++ MUST be baked into the link template itself.
    # clang (not clang++) won't auto-link any C++ runtime on its own.
    # The wrapper filters zig's static libc++.a out; -lc++ here resolves
    # to the shared libc++.dylib we built in the runtimes phase.
    # macOS: override link rule (normal variable, not cache)
    cat >> "${_cmake_project_include}" << CMINIT
set(CMAKE_CXX_CREATE_SHARED_LIBRARY "${SRC_DIR}/macos-link-wrapper.sh -v -arch ${_osx_arch} -mmacosx-version-min=11.0 -Wl,-ld_classic <CMAKE_SHARED_LIBRARY_CXX_FLAGS> <LINK_FLAGS> <CMAKE_SHARED_LIBRARY_CREATE_CXX_FLAGS> <SONAME_FLAG> <TARGET_SONAME> -o <TARGET> <OBJECTS> -L${LLVM_INSTALL}/lib -lc++ <LINK_LIBRARIES>")
set(CMAKE_CXX_CREATE_SHARED_LIBRARY "\${CMAKE_CXX_CREATE_SHARED_LIBRARY}" CACHE STRING "CXX shared library link rule" FORCE)
message(STATUS ">>> CMAKE_CXX_CREATE_SHARED_LIBRARY set to: \${CMAKE_CXX_CREATE_SHARED_LIBRARY}")
CMINIT
    # zig cc defaults to macOS 13.0 target, emitting ADRP relocations that the
    # NEW ld64 (Xcode 15+) rejects for ___dso_handle references in dylibs.
    # Apple's clang avoids ADRP to ___dso_handle via GOT-indirect addressing,
    # but zig's LLVM backend does not have this special case.
    # -Wl,-ld_classic forces the classic linker (pre-Xcode 15 behavior) which
    # does NOT have this ADRP restriction. -Wl,-fixup_chains was tried but
    # does NOT fix the issue — the new ld64 rejects ADRP to ___dso_handle
    # regardless of fixup format.
    # CMAKE_OSX_DEPLOYMENT_TARGET does NOT work — zig ignores it.
    # Must pass -mmacosx-version-min=11.0 directly in CMAKE_C/CXX_FLAGS so
    # zig cc sees it as an explicit compiler flag.
    CMAKE_SHARED_FLAGS=(
      -DCMAKE_C_FLAGS="-fvisibility=default -mmacosx-version-min=11.0"
      -DCMAKE_CXX_FLAGS="-fvisibility=default -mmacosx-version-min=11.0"
      -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
      -DCMAKE_SHARED_LINKER_FLAGS="-L${LLVM_INSTALL}/lib -lc++"
      -DCMAKE_EXE_LINKER_FLAGS="-L${LLVM_INSTALL}/lib -lc++"
    )
elif is_not_unix; then
    # Windows: override shared library link rule to use `zig cc -shared`.
    # zig cc handles @response files and -Wl, prefixes natively, so no
    # wrapper script is needed. zig _14+ probes for libc++ at the install
    # path set up after Phase 1 and links it dynamically when found.
    #
    # -fvisibility=default: CRITICAL — zig cc compiles with -fvisibility=hidden
    # by default. lld's --export-all-symbols does NOT export hidden symbols.
    # Without this, internal clang C++ symbols (SourceManager::getSpellingLocSlowCase
    # etc.) are hidden in object files → missing from libclang-cpp.dll.a → 104
    # undefined symbol errors when zig links against shared LLVM.
    # Linux and macOS set this in their CMAKE_SHARED_FLAGS too.
    #
    # CRITICAL: --export-all-symbols MUST be in the link template itself.
    # CMAKE_SHARED_LINKER_FLAGS=-Wl,--export-all-symbols does NOT propagate
    # into <LINK_FLAGS> when CMAKE_CXX_CREATE_SHARED_LIBRARY is overridden.
    # CI proof: libLLVM-20.dll.a=24 MiB (gets --export-all-symbols from patch
    # 0004's target_link_options), libclang-cpp.dll.a=7.9 KiB (relied on
    # CMAKE_SHARED_LINKER_FLAGS → <LINK_FLAGS> which DOES NOT WORK).
    # Without --export-all-symbols, the DLL only exports __declspec(dllexport)
    # symbols, missing thousands of clang/LLVM symbols zig needs.
    # Windows: override link rule (normal variable, not cache)
    # Use _BUILD_PREFIX_ (mixed path from build.bat: D:/a/... with drive letter).
    # NOT _BUILD_PREFIX (/d/a/...) — ninja runs commands via cmd.exe which doesn't
    # understand MSYS2 unix paths.  NOT BUILD_PREFIX (D:\a\...) — cmake treats
    # backslashes as escape characters in set() strings.
    _zig_cc_exe="${_BUILD_PREFIX_}/Library/bin/x86_64-w64-mingw32-zig.exe"
    # zig cc -shared handles CRT, compiler-rt, and system import libs automatically.
    # zig _14 probes for a shared libc++ at $BUILD_PREFIX/lib/zig-llvm/lib/libc++.dll.a
    # (symlinked after Phase 1 runtimes build) and links it dynamically when found.
    # Pre-generate MinGW import libraries from .def files as belt-and-suspenders;
    # having them in -L won't conflict with zig's own auto-generated imports.
    #
    # zig cc -shared is only confirmed working on x86_64-windows-gnu.
    # aarch64 hangs for 100+ seconds and produces an empty implib; that path
    # still needs a different approach and is handled separately.
    _mingw_implib_dir="${SRC_DIR}/_mingw_implibs"
    mkdir -p "${_mingw_implib_dir}"
    _zig_lib_dir="${_BUILD_PREFIX}/Library/lib/zig"
    _zig_mingw_def="${_zig_lib_dir}/libc/mingw"
    # Determine arch-specific def directory
    if [[ "${ZIG_TRIPLET}" == aarch64-* ]]; then
      _zig_mingw_arch_def="${_zig_mingw_def}/libarm64"
      _dlltool_machine="arm64"
    else
      _zig_mingw_arch_def="${_zig_mingw_def}/lib64"
      _dlltool_machine="i386:x86-64"
    fi
    echo "  Pre-generating MinGW import libraries from .def files..."
    echo "  .def source: ${_zig_mingw_def}/lib-common/ and ${_zig_mingw_arch_def}/"
    echo "  Output: ${_mingw_implib_dir}/"

    # .def.in files need C preprocessing: they #include "func.def.in" from def-include/
    # which defines architecture-gating macros (F64, F_X64, F_ARM64, etc.).
    # Critical libs (kernel32, advapi32, ws2_32, ole32, uuid) are ALL .def.in files.
    _def_include_dir="${_zig_mingw_def}/def-include"
    _cpp_tmp_dir="${_mingw_implib_dir}/_preprocessed"
    mkdir -p "${_cpp_tmp_dir}"
    # Set architecture defines for the C preprocessor
    if [[ "${ZIG_TRIPLET}" == aarch64-* ]]; then
      _arch_defines=(-D__aarch64__)
    else
      _arch_defines=(-D__x86_64__)
    fi
    echo "  def-include dir: ${_def_include_dir}"
    echo "  Arch defines: ${_arch_defines[*]}"

    _gen_count=0
    _gen_fail=0
    _cpp_count=0
    for _def_dir in "${_zig_mingw_def}/lib-common" "${_zig_mingw_arch_def}"; do
      if [[ ! -d "${_def_dir}" ]]; then
        echo "  WARNING: .def directory not found: ${_def_dir}"
        continue
      fi
      for _def_file in "${_def_dir}"/*.def "${_def_dir}"/*.def.in; do
        [[ -f "${_def_file}" ]] || continue
        _lib_name=$(basename "${_def_file}" .def)
        _lib_name=$(basename "${_lib_name}" .def.in)
        _actual_def="${_def_file}"
        # .def.in files need C preprocessing to expand #include and arch macros
        if [[ "${_def_file}" == *.def.in ]]; then
          _processed="${_cpp_tmp_dir}/${_lib_name}.def"
          if "${_zig_bin}" cc -E -P -nostdinc -x c \
              -I "${_def_include_dir}" "${_arch_defines[@]}" \
              "${_def_file}" -o "${_processed}" 2>/dev/null; then
            _actual_def="${_processed}"
            (( _cpp_count++ )) || true
          else
            dbg "  cpp failed for ${_lib_name}.def.in"
            (( _gen_fail++ )) || true
            continue
          fi
        fi
        if "${_zig_bin}" dlltool -m "${_dlltool_machine}" \
            -d "${_actual_def}" -l "${_mingw_implib_dir}/lib${_lib_name}.a" 2>/dev/null; then
          (( _gen_count++ )) || true
        else
          dbg "  dlltool failed for ${_lib_name}"
          (( _gen_fail++ )) || true
        fi
      done
    done
    echo "  Preprocessed ${_cpp_count} .def.in files"
    echo "  Generated ${_gen_count} import libraries (${_gen_fail} failures)"

    # Verify critical libs exist
    # uuid and mingw_crt are omitted: zig cc -shared compiles these automatically.
    _critical_ok=1
    for _crit in kernel32 shell32 psapi advapi32 ws2_32 ole32; do
      if [[ ! -f "${_mingw_implib_dir}/lib${_crit}.a" ]]; then
        echo "  FATAL: lib${_crit}.a was not generated"
        _critical_ok=0
      fi
    done
    if [[ ${_critical_ok} -eq 0 ]]; then
      echo "  Available .def dirs:"
      ls "${_zig_mingw_def}/" 2>/dev/null | sed 's/^/    /' || echo "    <not found>"
      echo "  lib-common contents (first 10):"
      ls "${_zig_mingw_def}/lib-common/" 2>/dev/null | head -10 | sed 's/^/    /' || echo "    <empty>"
      exit 1
    fi
    echo "  Critical import libraries verified OK"
    # Use _BUILD_PREFIX_ (mixed path D:/a/...) for the cmake template (cmd.exe compat)
    _mingw_implib_dir_cmake="${_SRC_DIR_}/_mingw_implibs"
    cat >> "${_cmake_project_include}" << CMINIT
# Normal variable (original approach):
set(CMAKE_CXX_CREATE_SHARED_LIBRARY "${_zig_cc_exe} cc -shared -target x86_64-windows-gnu <CMAKE_SHARED_LIBRARY_CXX_FLAGS> <LINK_FLAGS> <CMAKE_SHARED_LIBRARY_CREATE_CXX_FLAGS> -Wl,--export-all-symbols -L${_mingw_implib_dir_cmake} -o <TARGET> -Wl,--out-implib,<TARGET_IMPLIB> <OBJECTS> <LINK_LIBRARIES>")
# CACHE FORCE (cmake 3.31+ may not propagate normal vars to ninja generator):
set(CMAKE_CXX_CREATE_SHARED_LIBRARY "\${CMAKE_CXX_CREATE_SHARED_LIBRARY}" CACHE STRING "CXX shared library link rule" FORCE)
message(STATUS ">>> CMAKE_CXX_CREATE_SHARED_LIBRARY set to: \${CMAKE_CXX_CREATE_SHARED_LIBRARY}")
CMINIT
    CMAKE_SHARED_FLAGS=(
      -DCMAKE_C_FLAGS="-fvisibility=default"
      -DCMAKE_CXX_FLAGS="-fvisibility=default"
    )
fi

ulimit -n 4096 2>/dev/null || true
echo "=== cmake initial-cache file (${_cmake_init}) ==="
sed 's/^/  /' "${_cmake_init}" || true
echo "=== cmake project include file (${_cmake_project_include}) ==="
sed 's/^/  /' "${_cmake_project_include}" || true

# NOTE: Mini cmake validation removed — zig-as-Clang on Windows doesn't generate
# shared library rules in a minimal project (cmake needs more context from the
# real LLVM build's cmake modules). The post-configure check below (line ~1584)
# validates the template injection in the REAL build.ninja right after cmake
# configure (~2 min), before the ~90 min build phase.
echo "=== Skipping mini cmake test (false-negative on Windows) ==="
echo "  Will validate link template in real LLVM build.ninja after configure."
cmake "-C${_cmake_init}" \
  -S "${LLVM_SRC}" -B "${LLVM_BUILD}" \
  -DCMAKE_PROJECT_INCLUDE="${_cmake_project_include}" \
  "${CMAKE_CROSS_FLAGS[@]}" \
  "${CMAKE_PLATFORM_FLAGS[@]}" \
  "${CMAKE_RC_FLAGS[@]}" \
  "${CMAKE_SHARED_FLAGS[@]}" \
  -DHAS_LOGF128=OFF \
  -DLLD_BUILD_TOOLS=OFF \
  "${_CMAKE[@]}" \
  "${_CLANG[@]}" \
  "${_LLVM[@]}" \
  -G Ninja

# === QUICK-FAIL: verify CMAKE_CXX_CREATE_SHARED_LIBRARY template in build.ninja ===
# This runs RIGHT AFTER cmake configure, BEFORE the 90-minute build.
# If the template wasn't injected, abort immediately instead of building for
# 90+ minutes only to discover the link command is wrong.
echo "=== Quick-fail: verifying link template in build.ninja ==="
if is_osx; then
  _template_marker="macos-link-wrapper"
  _template_label="macos-link-wrapper.sh"
elif is_not_unix; then
  _template_marker="x86_64-windows-gnu"
  _template_label="zig cc -shared -target x86_64-windows-gnu"
else
  _template_marker="zig-cxx-shared"
  _template_label="zig-cxx-shared"
fi

# Diagnostic: check if cmake printed our project include messages
echo "  Checking cmake output for PROJECT_INCLUDE diagnostics..."
echo "  cmake version:"
cmake --version 2>&1 | head -1 | sed 's/^/    /'

# cmake's ninja generator puts rules in CMakeFiles/rules.ninja (included by build.ninja),
# NOT in build.ninja itself.  Explicitly search CMakeFiles/rules.ninja.
# NOTE: "${LLVM_BUILD}"/*.ninja glob ONLY finds top-level build.ninja — it MISSES
# CMakeFiles/rules.ninja which is in a subdirectory.  Always pass the explicit paths.
_rules_ninja="${LLVM_BUILD}/CMakeFiles/rules.ninja"
_build_ninja="${LLVM_BUILD}/build.ninja"
{ set +x; } 2>/dev/null
echo "  Ninja files:"
echo "    build.ninja: $( [[ -f "${_build_ninja}" ]] && echo found || echo NOT FOUND )"
echo "    CMakeFiles/rules.ninja: $( [[ -f "${_rules_ninja}" ]] && echo found || echo NOT FOUND )"

echo "  CMAKE_CXX_CREATE_SHARED_LIBRARY in CMakeCache.txt:"
grep 'CMAKE_CXX_CREATE_SHARED_LIBRARY' "${LLVM_BUILD}/CMakeCache.txt" 2>/dev/null | sed 's/^/    /' || echo "    <not found>"

# Show all 'rule ' entries from rules.ninja for diagnostic purposes
echo "  All link rules in CMakeFiles/rules.ninja (rule lines):"
grep '^rule ' "${_rules_ninja}" 2>/dev/null | grep -i 'CXX\|LINK\|SHARED' | sed 's/^/    /' || echo "    <none found>"

echo "  Searching for template marker '${_template_marker}' in CMakeFiles/rules.ninja..."
set -x

if grep -q "${_template_marker}" "${_rules_ninja}" 2>/dev/null; then
  echo "  OK: ${_template_label} found in CMakeFiles/rules.ninja"
  { set +x; } 2>/dev/null
  grep -B2 -A5 "${_template_marker}" "${_rules_ninja}" 2>/dev/null | head -20 | sed 's/^/    /' || true
  set -x
else
  echo "  FATAL: ${_template_label} NOT FOUND in CMakeFiles/rules.ninja!"
  echo "  CMAKE_PROJECT_INCLUDE set the variable (confirmed in cache) but ninja generator did not use it."
  { set +x; } 2>/dev/null
  echo "  All CXX_SHARED rules in CMakeFiles/rules.ninja:"
  grep -A3 'CXX_SHARED\|CREATE_SHARED\|SHARED_LIBRARY_LINKER' "${_rules_ninja}" 2>/dev/null | head -30 | sed 's/^/    /' || echo "    <none>"
  echo "  First 10 rule entries in CMakeFiles/rules.ninja:"
  grep '^rule ' "${_rules_ninja}" 2>/dev/null | head -10 | sed 's/^/    /' || echo "    <none>"
  set -x
  echo "  Aborting to avoid wasting 90+ minutes on a build that will fail at link time."
  exit 1
fi

# Platform-specific diagnostics (non-fatal, informational only)
if is_osx; then
  _implicit=$(grep 'CMAKE_CXX_IMPLICIT_LINK_LIBRARIES' "${LLVM_BUILD}/CMakeCache.txt" 2>/dev/null || true)
  echo "  CMAKE_CXX_IMPLICIT_LINK_LIBRARIES: ${_implicit:-<not found>}"
fi
if is_not_unix; then
  # Show the build statement for libclang-cpp.dll to see actual LINK_FLAGS expansion
  echo "  build.ninja entry for libclang-cpp.dll (first 20 lines):"
  grep -A20 'build.*libclang-cpp.*\.dll' "${LLVM_BUILD}/build.ninja" 2>/dev/null | head -20 | sed 's/^/    /' || echo "    <no libclang-cpp.dll entry found>"
  echo "  build.ninja entry for libLLVM (first 20 lines):"
  grep -A20 'build.*libLLVM.*\.dll[^.]' "${LLVM_BUILD}/build.ninja" 2>/dev/null | head -20 | sed 's/^/    /' || echo "    <no libLLVM.dll entry found>"
fi

# === Fast stub shared library test ===
# Before spending hours on the real LLVM build, create a tiny shared lib that
# references std::generic_category() — exactly what libLLVM will do.
# Verifies the link setup produces shared (not static) libc++ linkage.
# Takes seconds, not hours.
if is_linux; then
  echo "=== Fast stub .so test (verify shared libc++ linkage) ==="
  _stub_dir="${SRC_DIR}/_stub_test"
  mkdir -p "${_stub_dir}"

  # Compile: zig c++ produces .o with generic_category as U (UNDEFINED)
  cat > "${_stub_dir}/stub.cpp" << 'STUBCPP'
#include <system_error>
// Force a reference to generic_category so it appears in the symbol table.
// This mimics what LLVM/Clang code does internally.
const std::error_category* _stub_ref = &std::generic_category();
STUBCPP

  echo "  Compiling stub.cpp with zig c++..."
  "${ZIG_CXX}" -c -fPIC -o "${_stub_dir}/stub.o" "${_stub_dir}/stub.cpp"

  if _debug; then
    dbg "stub.o generic_category symbols:"
    nm "${_stub_dir}/stub.o" | grep 'generic_category' | sed 's/^/    /' || echo "    <none>"
  fi

  # Link: use the CMAKE_CXX_CREATE_SHARED_LIBRARY wrapper (zig-cxx-shared)
  echo "  Linking stub.so with zig-cxx-shared wrapper..."
  "${ZIG_CXX_SHARED}" -shared -o "${_stub_dir}/stub.so" \
    -L"${LLVM_INSTALL}/lib" -lc++ \
    "${_stub_dir}/stub.o"

  # Check the stub .so
  echo "  === Checking stub.so ==="
  _fail=0

  echo "  --- Check 1: no local generic_category ---"
  _local_syms=$(nm -a "${_stub_dir}/stub.so" 2>/dev/null | grep 'generic_category' || true)
  dbg "nm -a: ${_local_syms:-<none>}"
  if echo "${_local_syms}" | grep -qP '^[0-9a-f]+ [a-z] '; then
    echo "  FAIL: local generic_category — libc++ baked in"
    _fail=1
  else
    echo "  OK"
  fi

  echo "  --- Check 2: UNDEFINED in dynamic symbols ---"
  _dynsym=$(readelf --dyn-syms --wide "${_stub_dir}/stub.so" 2>/dev/null | grep 'generic_category' || true)
  dbg "readelf --dyn-syms: ${_dynsym:-<none>}"
  if [[ -z "${_dynsym}" ]]; then
    echo "  FAIL: not in dynamic symbol table"
    _fail=1
  elif echo "${_dynsym}" | grep -q 'UND'; then
    echo "  OK: UNDEFINED"
  else
    echo "  FAIL: not UNDEFINED"
    _fail=1
  fi

  echo "  --- Check 3: libc++.so in NEEDED ---"
  _needed=$(readelf -d "${_stub_dir}/stub.so" 2>/dev/null | grep NEEDED || true)
  if _debug; then echo "${_needed}" | sed 's/^/    /'; fi
  if echo "${_needed}" | grep -qE 'libc\+\+\.so'; then
    echo "  OK: libc++.so in NEEDED"
  else
    echo "  FAIL: libc++.so NOT in NEEDED"
    _fail=1
  fi

  if [[ ${_fail} -ne 0 ]]; then
    echo ""
    echo "  ============================================================"
    echo "  EARLY ABORT: stub .so test failed."
    echo "  The shared library link setup does not produce a .so that"
    echo "  uses external shared libc++.  The real LLVM build would fail"
    echo "  zig's ZigClangIsLLVMUsingSeparateLibcxx check."
    echo "  ============================================================"
    echo "  Wrapper used: ${ZIG_CXX_SHARED}"
    cat "${ZIG_CXX_SHARED}"
    exit 1
  fi
  echo "  === Stub .so test PASSED ==="
  rm -rf "${_stub_dir}"
elif is_osx; then
  # macOS equivalent of the Linux stub test.
  # Verifies that system clang (bypassing zig) produces a .dylib that uses
  # external shared libc++ instead of zig's bundled static copy.
  # zig cc (BOTH cc and c++ modes) injects static libc++ into Mach-O .dylib
  # files — confirmed on osx-arm64 and osx-64 CI.  System clang doesn't.
  # Without this fix, libclang-cpp.dylib gets a LOCAL copy of generic_category
  # ('t'), which zig's RTTI check detects at startup.
  # NOTE: dyld deduplicates symbols at runtime (same addresses), so a
  # dlsym address comparison would PASS even with the bug. We must check
  # nm output to detect the static merge.
  echo "=== Fast stub .dylib test (verify shared libc++ linkage) ==="
  _stub_dir="${SRC_DIR}/_stub_test"
  mkdir -p "${_stub_dir}"

  cat > "${_stub_dir}/stub.cpp" << 'STUBCPP'
#include <system_error>
const std::error_category* _stub_ref = &std::generic_category();
STUBCPP

  echo "  Compiling stub.cpp with zig c++..."
  "${ZIG_CXX}" -c -fPIC -fvisibility=default -o "${_stub_dir}/stub.o" "${_stub_dir}/stub.cpp"

  # Diagnostic: check if generic_category is already baked into the OBJECT file.
  # If it's defined ('t'/'T') in stub.o, the problem is at COMPILE time (zig's
  # headers instantiate the symbol) and no linker change can fix it.
  # If it's undefined ('U'), the problem is at link time and system clang should fix it.
  _obj_syms=$(nm "${_stub_dir}/stub.o" 2>/dev/null | grep 'generic_category' || true)
  dbg "stub.o nm: ${_obj_syms:-<none>}"
  if echo "${_obj_syms}" | grep -q ' [tT] '; then
    echo "  WARNING: generic_category is DEFINED in stub.o (compile-time issue)"
    echo "  This means zig's headers instantiate the symbol locally."
    echo "  No linker change will help — need to compile with system headers."
  elif echo "${_obj_syms}" | grep -q ' U '; then
    echo "  OK: generic_category is UNDEFINED in stub.o (link-time resolution)"
  else
    dbg "  stub.o: generic_category not found or unexpected symbol type"
  fi

  # Quick-fail: check deployment target mismatch before linking.
  # zig may compile objects for a newer macOS target than the linker expects.
  # e.g. zig uses macOS 13.0 but link template has -mmacosx-version-min=11.0.
  # This causes ld64 to reject ADRP relocations to ___dso_handle.
  _stub_minos=""
  # LC_BUILD_VERSION (newer) shows: minos X.Y.Z; LC_VERSION_MIN_MACOSX shows: version X.Y
  if otool -l "${_stub_dir}/stub.o" 2>/dev/null | grep -q 'LC_BUILD_VERSION'; then
    _stub_minos=$(otool -l "${_stub_dir}/stub.o" 2>/dev/null \
      | grep -A4 'LC_BUILD_VERSION' | grep 'minos' | awk '{print $2}' | head -1)
  elif otool -l "${_stub_dir}/stub.o" 2>/dev/null | grep -q 'LC_VERSION_MIN_MACOSX'; then
    _stub_minos=$(otool -l "${_stub_dir}/stub.o" 2>/dev/null \
      | grep -A2 'LC_VERSION_MIN_MACOSX' | grep 'version' | awk '{print $2}' | head -1)
  fi
  echo "  stub.o deployment target (from zig): ${_stub_minos:-<unknown>}"

  # Extract -mmacosx-version-min from the link template used for the real LLVM build.
  _link_version_min=$(grep -o '\-mmacosx-version-min=[0-9.]*' "${_cmake_project_include}" \
    | head -1 | sed 's/-mmacosx-version-min=//' || true)
  if [[ -n "${_link_version_min}" ]]; then
    echo "  Link template deployment target (-mmacosx-version-min): ${_link_version_min}"
    if [[ -n "${_stub_minos}" ]]; then
      # Compare major versions — if zig's minos major > linker's version-min major, ADRP risk
      _zig_major=$(echo "${_stub_minos}" | cut -d. -f1)
      _link_major=$(echo "${_link_version_min}" | cut -d. -f1)
      if [[ "${_zig_major}" -gt "${_link_major}" ]]; then
        echo "  EARLY ABORT: deployment target mismatch!"
        echo "    zig compiled stub.o for macOS ${_stub_minos}"
        echo "    linker template targets macOS ${_link_version_min} (-mmacosx-version-min)"
        echo "    ld64 will reject ADRP relocations (e.g. to ___dso_handle) from newer-target objects."
        echo "    Fix: remove -mmacosx-version-min from the CMAKE_CXX_CREATE_SHARED_LIBRARY"
        echo "         template (let the linker default to the SDK), OR ensure zig cc also"
        echo "         targets macOS ${_link_version_min} (patch zig-force-load-cxx wrapper)."
        exit 1
      fi
    fi
  else
    echo "  Link template has no -mmacosx-version-min (linker will use SDK default)"
  fi

  # Link: use the wrapper — matches CMAKE_CXX_CREATE_SHARED_LIBRARY override.
  # The wrapper filters *libc++.a/*libc++abi.a from argv then exec-s /usr/bin/clang.
  # For the stub test there are no libc++.a args so this is equivalent to
  # calling /usr/bin/clang directly, but using the wrapper keeps the test
  # consistent with the real LLVM build.
  # -arch ensures correct target for cross-builds (arm64 runner → x86_64 target).
  echo "  Linking stub.dylib with macos-link-wrapper.sh (arch: ${_osx_arch})..."
  "${SRC_DIR}/macos-link-wrapper.sh" -arch "${_osx_arch}" -dynamiclib \
    -mmacosx-version-min="${_deploy_target}" -Wl,-ld_classic \
    -L"${LLVM_INSTALL}/lib" -lc++ \
    -o "${_stub_dir}/stub.dylib" \
    "${_stub_dir}/stub.o"

  echo "  === Checking stub.dylib ==="
  _fail=0

  echo "  --- Check 1: no local generic_category ---"
  # nm -a shows all symbols; lowercase 't' = local defined = static libc++ baked in
  _local_syms=$(nm -a "${_stub_dir}/stub.dylib" 2>/dev/null | grep 'generic_category' || true)
  dbg "nm -a: ${_local_syms:-<none>}"
  if echo "${_local_syms}" | grep -q '^[0-9a-f]* t '; then
    echo "  FAIL: local generic_category ('t') — static libc++ baked in"
    _fail=1
  else
    echo "  OK"
  fi

  echo "  --- Check 2: generic_category is UNDEFINED ---"
  # nm -u shows undefined symbols (references to external shared libc++)
  _undef=$(nm -u "${_stub_dir}/stub.dylib" 2>/dev/null | grep 'generic_category' || true)
  dbg "nm -u: ${_undef:-<none>}"
  if [[ -n "${_undef}" ]]; then
    echo "  OK: UNDEFINED (will resolve from shared libc++)"
  else
    # Also check global defined — if -fvisibility=default made it global, that's also bad
    _global=$(nm -gU "${_stub_dir}/stub.dylib" 2>/dev/null | grep 'generic_category' || true)
    if [[ -n "${_global}" ]]; then
      echo "  FAIL: GLOBAL DEFINED — libc++ symbol baked in (not delegating to shared)"
      _fail=1
    else
      echo "  FAIL: generic_category not found in symbol table"
      _fail=1
    fi
  fi

  echo "  --- Check 3: libc++.dylib in load commands ---"
  _deps=$(otool -L "${_stub_dir}/stub.dylib" 2>/dev/null || true)
  if _debug; then echo "${_deps}" | sed 's/^/    /'; fi
  if echo "${_deps}" | grep -q 'libc++'; then
    echo "  OK: libc++ in load commands"
  else
    echo "  FAIL: libc++ NOT in load commands"
    _fail=1
  fi

  if [[ ${_fail} -ne 0 ]]; then
    echo ""
    echo "  ============================================================"
    echo "  EARLY ABORT: stub .dylib test failed."
    echo "  The shared library link setup does not produce a .dylib that"
    echo "  uses external shared libc++.  The real LLVM build would fail"
    echo "  zig's ZigClangIsLLVMUsingSeparateLibcxx RTTI check."
    echo "  ============================================================"
    echo "  wrapper: ${SRC_DIR}/macos-link-wrapper.sh (arch: ${_osx_arch})"
    echo "  MACOS_LINK: ${MACOS_LINK}"
    echo "  ZIG_CXX: ${ZIG_CXX}"
    echo "  LLVM_INSTALL/lib contents:"
    ls -la "${LLVM_INSTALL}/lib/"libc++* 2>/dev/null || echo "    <none>"
    exit 1
  fi
  echo "  === Stub .dylib test PASSED ==="
  rm -rf "${_stub_dir}"
fi

echo "=== Building LLVM ==="
if is_not_unix; then
  # Two-phase build on Windows:
  # Phase 1: Build libLLVM.dll (patch 0004 adds --export-all-symbols for data symbols)
  # Phase 1.5: atexit from dllcrt2.obj leaks into the import lib via --export-all-symbols.
  #   Zig's driver rejects --exclude-symbols. We use ar d to surgically remove the atexit
  #   import entry, preserving the short-import format. This prevents duplicate symbol
  #   errors in Phase 2 when libclang-cpp links against the cleaned import lib.
  # Phase 2: Build everything else (libclang-cpp links against cleaned import lib)

  # Enable zig-cxx-shared verbose logging for shared library links
  export ZIG_CXX_SHARED_VERBOSE=1

  # Phase 1: Build libLLVM DLL only
  echo "  Phase 1: Building LLVM shared library..."
  cmake --build "${LLVM_BUILD}" --target LLVM -j"${CPU_COUNT}"

  # Phase 1.5: Remove atexit from import lib via strip_atexit_from_implib().
  # The same function is exercised by the fast-fail stub test above, so any bug
  # in the shared logic surfaces in ~5 s (stub) rather than after the 90-min build.
  _implib=$(find "${LLVM_BUILD}" \( -name 'libLLVM*.dll.a' -o -name 'LLVM*.dll.a' \) 2>/dev/null | awk 'NR==1')
  _zig_bin="${_native_zig:-${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe}"

  # Determine dlltool machine type for cross-compilation (x64 host → arm64 target)
  _dlltool_machine=""
  if [[ "${ZIG_TRIPLET}" == aarch64-* ]]; then
    _dlltool_machine="arm64"
  elif [[ "${ZIG_TRIPLET}" == x86_64-* ]]; then
    _dlltool_machine="i386:x86-64"
  fi

  if [[ -n "${_implib}" ]]; then
    echo "  Phase 1.5: Stripping atexit from import lib: ${_implib}"
    if ! strip_atexit_from_implib "${_implib}" "${_zig_bin}" "libLLVM-20" "${_dlltool_machine}"; then
      echo "  ERROR: strip_atexit_from_implib failed — aborting build."
      exit 1
    fi
    # Quick-fail: verify libLLVM.dll.a has critical symbols after strip_atexit.
    # Without this, a broken import lib wastes the entire Phase 2 build.
    # Use direct pipe (strings | grep -q) to avoid storing ~8 MB of symbols in a
    # bash variable — MSYS2 echo truncates large variables, causing false failures.
    echo "  Phase 1.5b: Quick-fail verification of libLLVM.dll.a exports..."
    { set +x; } 2>/dev/null
    _llvm_fail=0
    for _check_sym in ErrorInfoBase LLVMInitialize; do
      if strings -a "${_implib}" 2>/dev/null | grep -q "${_check_sym}"; then
        echo "    OK: ${_check_sym} found"
      else
        echo "    FAIL: ${_check_sym} NOT found in libLLVM.dll.a"
        _llvm_fail=1
      fi
    done

    # Count total symbol-like strings (approximate, for logging)
    _llvm_nsyms=$(strings -a "${_implib}" 2>/dev/null \
      | grep -cxE '[_A-Za-z?@][_A-Za-z0-9?@$]*' || echo 0)
    echo "    Total symbols in libLLVM.dll.a: ${_llvm_nsyms}"
    if [[ "${_llvm_nsyms}" -lt 5000 ]]; then
      echo "    FAIL: expected 5000+ symbols, got ${_llvm_nsyms}"
      _llvm_fail=1
    fi
    set -x

    if [[ "${_llvm_fail}" -ne 0 ]]; then
      echo "  ERROR: libLLVM.dll.a is missing critical symbols!"
      echo "  strip_atexit_from_implib may have discarded members, or --export-all-symbols is missing."
      exit 1
    fi
    echo "  OK: libLLVM.dll.a verified (${_llvm_nsyms} symbols, all critical present)"
  else
    echo "  WARNING: import lib not found — skipping Phase 1.5"
  fi

  # Phase 2: Build all remaining targets.
  # --export-all-symbols is in the CMAKE_CXX_CREATE_SHARED_LIBRARY template,
  # so all DLLs (libclang-cpp etc.) export their symbols.
  echo "  Phase 2: Building remaining targets..."
  cmake --build "${LLVM_BUILD}" -j"${CPU_COUNT}"

  # Phase 2.5: Strip atexit from libclang-cpp import lib + verify exports.
  # --export-all-symbols is baked into CMAKE_CXX_CREATE_SHARED_LIBRARY template,
  # which also leaks atexit from dllcrt2.obj — same issue as libLLVM.
  _clang_implib=$(find "${LLVM_BUILD}" \( -name 'libclang-cpp*.dll.a' -o -name 'clang-cpp*.dll.a' \) 2>/dev/null | awk 'NR==1')
  if [[ -n "${_clang_implib}" ]]; then
    echo "  Phase 2.5: Stripping atexit from clang-cpp import lib: ${_clang_implib}"
    if ! strip_atexit_from_implib "${_clang_implib}" "${_zig_bin}" "libclang-cpp" "${_dlltool_machine}"; then
      echo "  ERROR: strip_atexit_from_implib failed for clang-cpp — aborting build."
      exit 1
    fi
    # Quick-fail: verify libclang-cpp.dll.a actually exports the symbols zig needs.
    # Without this, a broken import lib wastes 25+ min on zig-zig_impl before failing
    # with "104 undefined symbol" errors (clang::SourceManager::*, etc.).
    #
    # Critical symbols that zig's zig_clang.cpp references directly:
    #   SourceManager  — getSpellingLocSlowCase, getFilename, getSpellingLineNumber
    #   CompilerInstance — zig uses clang as a library
    #   ASTContext       — AST manipulation
    echo "  Phase 2.5b: Quick-fail verification of libclang-cpp.dll.a exports..."
    # Instant size check: a proper import lib is 100s of KiB to MiB.
    # 7.9 KiB means --export-all-symbols didn't work (only a handful of symbols).
    _clang_implib_size=$(stat -c%s "${_clang_implib}" 2>/dev/null || stat -f%z "${_clang_implib}" 2>/dev/null || echo 0)
    echo "    Import lib size: ${_clang_implib_size} bytes ($(( _clang_implib_size / 1024 )) KiB)"
    if [[ "${_clang_implib_size}" -lt 100000 ]]; then
      echo "    FAIL: libclang-cpp.dll.a is only ${_clang_implib_size} bytes!"
      echo "    Expected 100+ KiB — --export-all-symbols likely missing from link command."
      echo "    Compare: libLLVM-20.dll.a should be ~24 MiB."
      exit 1
    fi
    # Use direct pipe (strings | grep -q) to avoid storing large symbol sets in bash
    # variables — MSYS2 echo truncates large variables, causing false failures.
    { set +x; } 2>/dev/null
    _clang_fail=0
    # Check critical zig-required symbols
    for _check_sym in SourceManager CompilerInstance ASTContext; do
      if strings -a "${_clang_implib}" 2>/dev/null | grep -q "${_check_sym}"; then
        echo "    OK: ${_check_sym} found"
      else
        echo "    FAIL: ${_check_sym} NOT found in libclang-cpp.dll.a"
        _clang_fail=1
      fi
    done

    # Minimum symbol count — libclang-cpp exports thousands of C++ symbols.
    # If we have < 1000, something went very wrong (visibility, ar d, etc.)
    _clang_nsyms=$(strings -a "${_clang_implib}" 2>/dev/null \
      | grep -cxE '[_A-Za-z?@][_A-Za-z0-9?@$]*' || echo 0)
    echo "    Total symbols in libclang-cpp.dll.a: ${_clang_nsyms}"
    if [[ "${_clang_nsyms}" -lt 1000 ]]; then
      echo "    FAIL: expected 1000+ symbols, got ${_clang_nsyms}"
      _clang_fail=1
    fi
    set -x

    if [[ "${_clang_fail}" -ne 0 ]]; then
      echo "  ERROR: libclang-cpp.dll.a is missing critical symbols!"
      echo "  This would cause 104+ undefined symbol errors in zig-zig_impl build."
      echo "  Likely causes:"
      echo "    - -fvisibility=default not reaching clang compilation"
      echo "    - --export-all-symbols not in libclang-cpp link command"
      echo "    - strip_atexit_from_implib discarded members (ar d removed too much)"
      exit 1
    fi
    echo "  OK: libclang-cpp.dll.a verified (${_clang_nsyms} symbols, all critical present)"
  fi
elif is_osx; then
  # Two-phase build on macOS: build libLLVM.dylib first, check symbol exports,
  # then build the rest. Without this, a visibility bug wastes the full 2-hour build
  # only to fail at the very end when libclang-cpp.dylib links against libLLVM.dylib.
  echo "  Phase 1: Building LLVM shared library..."
  cmake --build "${LLVM_BUILD}" --target LLVM -j"${CPU_COUNT}"

  # Quick-fail: verify key symbols are exported from libLLVM.dylib.
  # If zig cc's visibility handling is broken, we find out here (~50% through build)
  # instead of at the end when libclang-cpp.dylib tries to link.
  # === macOS diagnostic: dump link wrapper log ===
  # ninja eats stderr on success, so all wrapper output went to MACOS_LINK_LOG.
  # Show only the libLLVM / libclang entries (wrapper is only called for .dylib links).
  if [[ -f "${MACOS_LINK_LOG}" ]]; then
    echo "  === macOS link wrapper log (libLLVM/libclang entries) ==="
    grep -A5 'libLLVM\|libclang' "${MACOS_LINK_LOG}" | head -60 | sed 's/^/  /' || echo "  (no libLLVM/libclang entries found)"
    echo "  --- link wrapper summary ---"
    echo "  Total link invocations: $(grep -c '^ARGS:' "${MACOS_LINK_LOG}" 2>/dev/null || echo 0)"
    echo "  Total skipped static libc++: $(grep -c '^SKIPPED:' "${MACOS_LINK_LOG}" 2>/dev/null || echo 0)"
    echo "  Log saved at: ${MACOS_LINK_LOG}"
  else
    echo "  WARNING: ${MACOS_LINK_LOG} not found — wrapper may not have been invoked"
  fi

  # === macOS diagnostic: check ninja .rsp response files ===
  # For large link commands ninja writes arguments to a .rsp file.
  # These survive the build and let us see the ACTUAL arguments passed to the wrapper.
  echo "  === macOS: checking ninja response files for libLLVM link ==="
  _rsp=$(find "${LLVM_BUILD}" -name '*.rsp' -path '*LLVM*' 2>/dev/null | head -1)
  if [[ -n "${_rsp}" ]]; then
    echo "  Found: ${_rsp}"
    echo "  Content (first 30 lines):"
    head -30 "${_rsp}" | sed 's/^/    /'
    echo "  libc++ references in .rsp:"
    grep -i 'libc++' "${_rsp}" | sed 's/^/    /' || echo "    <none>"
  else
    echo "  No LLVM .rsp files found (arguments may be inline or files cleaned up)"
    # Fall back: show any recent .rsp files at all
    echo "  Any .rsp files in build dir:"
    find "${LLVM_BUILD}" -name '*.rsp' -newer "${LLVM_BUILD}/build.ninja" 2>/dev/null | head -5 | sed 's/^/    /' || echo "    <none>"
  fi

  _llvm_dylib=$(find "${LLVM_BUILD}" -name 'libLLVM*.dylib' -not -name '*.dSYM' 2>/dev/null | awk 'NR==1')
  if [[ -n "${_llvm_dylib}" ]]; then
    # === macOS diagnostic: immediate libLLVM.dylib inspection ===
    echo "  === macOS: immediate libLLVM.dylib check ==="
    echo "  File: ${_llvm_dylib}"
    echo "  Size: $(ls -lh "${_llvm_dylib}" | awk '{print $5}')"
    echo "  otool -L (first 10 lines):"
    otool -L "${_llvm_dylib}" 2>/dev/null | head -10 | sed 's/^/    /'
    echo "  nm generic_category (all types):"
    nm -a "${_llvm_dylib}" 2>/dev/null | grep 'generic_category' | head -5 | sed 's/^/    /' || echo "    <none>"
    echo "  nm libc++ undefined refs:"
    nm -u "${_llvm_dylib}" 2>/dev/null | grep 'libc++\|cxx' | head -5 | sed 's/^/    /' || echo "    <none>"

    echo "  Checking libLLVM.dylib symbol exports: ${_llvm_dylib}"

    # Check for a known externally-consumed symbol (LLVMInitialize* functions).
    # IMPORTANT: use "grep ... >/dev/null" NOT "grep -q" here.
    # grep -q exits on first match, closing the pipe while nm is still writing
    # 55K+ symbols. Under set -o pipefail, nm's SIGPIPE (exit 141) makes the
    # pipeline fail even though the symbol was found.
    _test_sym="LLVMInitializeAArch64AsmParser"
    if nm -g "${_llvm_dylib}" 2>/dev/null | grep "${_test_sym}" >/dev/null 2>&1; then
      echo "  OK: ${_test_sym} exported (global)"
    else
      echo "  FAIL: ${_test_sym} NOT exported from libLLVM.dylib"
      if _debug && [[ -f "${RECIPE_DIR}/building/debug-macos-dylib.sh" ]]; then
        source "${RECIPE_DIR}/building/debug-macos-dylib.sh"
        debug_macos_dylib "${_llvm_dylib}" "${_test_sym}" "${LLVM_BUILD}"
      fi
      echo "  EARLY ABORT: libLLVM.dylib is missing key symbols."
      exit 1
    fi
  else
    echo "  WARNING: libLLVM.dylib not found after Phase 1 — proceeding anyway"
  fi

  echo "  Phase 2: Building remaining targets..."
  cmake --build "${LLVM_BUILD}" -j"${CPU_COUNT}"
else
  # Linux: single-phase build (no known symbol visibility issues with ELF)
  cmake --build "${LLVM_BUILD}" -j"${CPU_COUNT}"
fi

echo "=== Installing LLVM ==="
cmake --install "${LLVM_BUILD}"

# Install tablegen tools (not installed by cmake --install, but needed for cross-compilation)
# These are host-arch binaries that run on the build machine to generate .inc files.
echo "=== Installing tablegen tools ==="
for _tbl in llvm-tblgen clang-tblgen llvm-min-tblgen; do
  if [[ -x "${LLVM_BUILD}/bin/${_tbl}" ]]; then
    cp -v "${LLVM_BUILD}/bin/${_tbl}" "${LLVM_INSTALL}/bin/"
  fi
done

if [[ "${ZIG_LLVM_SKIP_BUILD:-}" == "0" ]]; then
  echo "=== Populating the cache ==="
  mkdir -p ${RECIPE_DIR}/cache && rm -rf ${RECIPE_DIR}/cache/*
  cp -r ${PREFIX}/lib/zig-llvm/* ${RECIPE_DIR}/cache/
fi

remove_unneeded
post_install
fix_lld_cmake_deps

# Verify llvm-config --system-libs includes zlib/zstd (native builds only)
if ! is_cross; then
  echo "=== Verifying llvm-config --system-libs ==="
  # Use the real binary, not the wrapper (wrapper only filters ld flags, not libs)
  _real_config="${LLVM_INSTALL}/bin/llvm-config.real"
  [[ -f "${_real_config}.exe" ]] && _real_config="${_real_config}.exe"
  if [[ -x "${_real_config}" ]]; then
    _system_libs=$("${_real_config}" --system-libs 2>/dev/null || true)
    echo "  system-libs: ${_system_libs}"
    if ! echo "${_system_libs}" | grep -q '\-lz'; then
      echo "  WARNING: llvm-config --system-libs missing -lz (LLVM_ENABLE_ZLIB=ON)"
    fi
    if is_unix && ! echo "${_system_libs}" | grep -q '\-lzstd'; then
      echo "  WARNING: llvm-config --system-libs missing -lzstd (LLVM_ENABLE_ZSTD=ON)"
    fi
  else
    dbg "llvm-config.real not executable, skipping system-libs verification"
  fi
fi

echo "=== zig-llvm build complete ==="

# Create a marker file for zig build to find this LLVM
echo "${LLVM_INSTALL}" > "$(dirname "${LLVM_INSTALL}")/zig-llvm-path.txt"

