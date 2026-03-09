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

source ${RECIPE_DIR}/post-install.sh
source ${RECIPE_DIR}/remove-unneeded.sh

build_platform="${build_platform:-${target_platform}}"

is_linux() { [[ "${target_platform}" == "linux-"* ]]; }
is_osx() { [[ "${target_platform}" == "osx-"* ]]; }
is_unix() { [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; }
is_not_unix() { [[ "${target_platform}" != "linux-"* && "${target_platform}" != "osx-"* ]]; }
is_cross() { [[ "${build_platform}" != "${target_platform}" ]]; }

is_debug() { [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]]; }

echo "=== Building zig-llvmdev with zig cc ==="
echo "  LLVM source: ${SRC_DIR}/llvm-source"
echo "  Target: ${target_platform}"

LLVM_SRC="${SRC_DIR}/llvm"
LLVM_BUILD="${SRC_DIR}/conda-llvm-build"
LLVM_INSTALL="${PREFIX}/lib/zig-llvm"

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

if [[ -z "${CONDA_BUILD_ZIG:-}" ]]; then
  echo "ERROR: CONDA_BUILD_ZIG not set"
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
  # CMAKE_AR/CMAKE_RANLIB don't support semicolon syntax (CMake invokes them
  # directly via cmd.exe, not as compiler commands). Cross-compiler .bat wrappers
  # reference aarch64-w64-mingw32-zig.exe which doesn't exist.
  # Create .bat wrappers that cmd.exe can invoke, calling the native .exe.
  # Convert forward-slash path to backslash for cmd.exe.
  _native_zig_win=$(echo "${_native_zig}" | sed 's|/|\\|g')

  _zig_ar="${SRC_DIR}/_zig_ar.bat"
  cat > "${_zig_ar}" << ARWRAP
@echo off
"${_native_zig_win}" ar %*
ARWRAP

  _zig_ranlib="${SRC_DIR}/_zig_ranlib.bat"
  cat > "${_zig_ranlib}" << RANLIBWRAP
@echo off
"${_native_zig_win}" ranlib %*
RANLIBWRAP

  export ZIG_AR="${_zig_ar}"
  export ZIG_RANLIB="${_zig_ranlib}"
  export ZIG_RC="${_zig};rc"
  # Windows zig-cxx-shared: bash wrapper that invokes ld.lld directly for
  # DLL creation, bypassing zig's static libc++ merge.
  # CMake calls this via CMAKE_CXX_CREATE_SHARED_LIBRARY.
  ZIG_CXX_SHARED_WIN="${SRC_DIR}/_zig_cxx_shared_win"
  cat > "${ZIG_CXX_SHARED_WIN}" << 'SHAREDWIN'
#!/usr/bin/env bash
set -euo pipefail
# Windows DLL linker wrapper — invokes ld.lld directly in MinGW mode.
# Translates compiler-driver flags to raw linker flags, similar to
# the Linux zig-cxx-shared wrapper.
#
# Why: zig c++ always statically merges its bundled libc++ into .dll files.
# By invoking ld.lld directly, we link against the shared libc++.dll instead.

_args=()
_libs=()
_output=""
_implib=""

for arg in "$@"; do
    case "$arg" in
        # Output file
        -o) _next_is_output=1; continue ;;
        # Strip compiler-only flags that ld.lld doesn't understand
        -target|--target=*) continue ;;
        -mcpu=*|-march=*|-mtune=*) continue ;;
        -stdlib=*) continue ;;
        -f*|-O*|-g|-g[0-9]|-D*|-I*|-std=*|-W*|-pedantic) continue ;;
        -Werror=*|-Wno-*) continue ;;
        # Translate -Wl, flags
        -Wl,*)
            _wl_args="${arg#-Wl,}"
            IFS=',' read -ra _parts <<< "${_wl_args}"
            for _p in "${_parts[@]}"; do
                _args+=("${_p}")
            done
            continue ;;
        # Translate -Xlinker
        -Xlinker) _next_is_xlinker=1; continue ;;
        # Shared flag → already handled
        -shared) _args+=("--shared"); continue ;;
        # Pass through everything else (objects, libraries, -L paths)
        *) ;;
    esac

    if [[ "${_next_is_output:-0}" == "1" ]]; then
        _output="$arg"
        _next_is_output=0
        continue
    fi
    if [[ "${_next_is_xlinker:-0}" == "1" ]]; then
        _args+=("$arg")
        _next_is_xlinker=0
        continue
    fi

    _args+=("$arg")
done

# Find lld: prefer conda lld package, then zig's internal lld
_lld=""
if command -v ld.lld >/dev/null 2>&1; then
    _lld="ld.lld"
elif command -v lld >/dev/null 2>&1; then
    _lld="lld"
elif command -v lld-link >/dev/null 2>&1; then
    # zig ships lld-link on Windows; lld-link -flavor gnu = MinGW mode
    _lld="lld-link"
fi

if [[ -z "${_lld}" ]]; then
    echo "ERROR: no lld found in PATH" >&2
    echo "  Tried: ld.lld, lld, lld-link" >&2
    echo "  PATH: ${PATH}" >&2
    exit 1
fi

echo "=== zig-cxx-shared-win ===" >&2
echo "  output: ${_output}" >&2
echo "  lld: ${_lld}" >&2
echo "  args count: ${#_args[@]}" >&2
echo "  args (first 10): ${_args[*]:0:10}" >&2

# Use MinGW emulation mode for PE/COFF output
exec "${_lld}" -m i386pep \
    --shared \
    -o "${_output}" \
    "${_args[@]}"
SHAREDWIN
  chmod +x "${ZIG_CXX_SHARED_WIN}"
  export ZIG_CXX_SHARED="${ZIG_CXX_SHARED_WIN}"
else
  export ZIG_CC="${ZIG_WRAPPERS}/zig-cc"
  export ZIG_CXX="${ZIG_WRAPPERS}/zig-cxx"
  export ZIG_CXX_SHARED="${ZIG_WRAPPERS}/zig-cxx-shared"
  export ZIG_AR="${ZIG_WRAPPERS}/zig-ar"
  export ZIG_RANLIB="${ZIG_WRAPPERS}/zig-ranlib"
  export ZIG_ASM="${ZIG_WRAPPERS}/zig-asm"
  export ZIG_RC="${ZIG_WRAPPERS}/zig-rc"
fi

# HOTFIX: zig-compiler *_8 wrappers on macOS.
# 1. Zig's Mach-O linker does NOT support -all_load, -force_load, or
#    -exported_symbols_list. Wrapper already filters them but LLVM needs
#    -all_load/-force_load to pull all archive members into libLLVM.dylib.
# 2. Solution: add *_list flag filters AND create a helper script that
#    converts -force_load/-all_load into archive extraction (ar x → .o files).
# Remove when zig-compiler *_9 ships these fixes.
if is_osx; then
    echo "  Patching macOS zig-cc/zig-cxx wrappers..."
    for _w in "${ZIG_CC}" "${ZIG_CXX}"; do
        # Add filters for *_list flags zig doesn't support.
        # -all_load/-force_load are already filtered by the wrapper;
        # archive extraction is handled by zig-force-load-wrapper below.
        sed -i '' \
          '/-Wl,-all_load|-Wl,-force_load,\*) ;;/a\
        -Wl,-exported_symbols_list|-Wl,-exported_symbols_list,*) ;;\
        -Wl,-unexported_symbols_list|-Wl,-unexported_symbols_list,*) ;;\
        -Wl,-force_symbols_not_weak_list|-Wl,-force_symbols_not_weak_list,*) ;;\
        -Wl,-force_symbols_weak_list|-Wl,-force_symbols_weak_list,*) ;;\
        -Wl,-reexported_symbols_list|-Wl,-reexported_symbols_list,*) ;;' "${_w}"
        # Filter -mcpu=* from external sources. conda-build may inject -mcpu=core2
        # for osx-64 cross-builds; zig doesn't recognize x86 CPU names like 'core2'.
        # The wrapper's own -mcpu=baseline is in the exec line (not in $@), so
        # this only strips external ones.  Add after the -march/-mtune filter.
        sed -i '' '/-march=.*|-mtune=.*) ;;/a\
        -mcpu=*) ;;' "${_w}"
    done

    # Create a CXX compiler wrapper that intercepts -force_load and -all_load,
    # extracts the referenced archives to .o files, and passes those to zig-cxx.
    # Zig's Mach-O linker doesn't support these flags, but LLVM's CMake uses
    # -force_load/-all_load to pull all target initializers into libLLVM.dylib.
    #
    # IMPORTANT: This wrapper is set as CMAKE_CXX_COMPILER (not as
    # CMAKE_CXX_CREATE_SHARED_LIBRARY). The latter is unreliable — CMake's
    # Ninja generator may not apply it to all shared library targets.
    # As CMAKE_CXX_COMPILER, it handles both compile and link commands.
    # The force-load logic only activates when -Wl,-all_load or -Wl,-force_load
    # is present; for plain compilations it's a transparent passthrough.
    ZIG_CXX_FORCELOAD="${SRC_DIR}/_zig_cxx_forceload"
    cat > "${ZIG_CXX_FORCELOAD}" << FORCELOAD
#!/usr/bin/env bash
set -euo pipefail
# macOS CXX wrapper: transparent passthrough for compilation,
# archive extraction for -Wl,-all_load/-Wl,-force_load link steps.
_real_cxx="${ZIG_CXX}"

# Quick check: if no -all_load or -force_load in args, just passthrough
_has_forceload=0
for _a in "\$@"; do
    case "\$_a" in
        -Wl,-all_load|-Wl,-force_load,*) _has_forceload=1; break ;;
    esac
done

if [[ \$_has_forceload -eq 0 ]]; then
    exec "\${_real_cxx}" "\$@"
fi

# Debug log: first invocation only
_log="/tmp/_zig_force_load_debug.log"
if [[ ! -f "\${_log}" ]]; then
    echo "=== force-load wrapper invoked ===" > "\${_log}"
    echo "real_cxx: \${_real_cxx}" >> "\${_log}"
    echo "argc: \$#" >> "\${_log}"
    for _a in "\$@"; do
        echo "  arg: \${_a}" >> "\${_log}"
    done
fi

_all_load=0
_force_load_archives=()
_other_args=()
_archive_args=()

for arg in "\$@"; do
    case "\$arg" in
        -Wl,-all_load)
            _all_load=1 ;;
        -Wl,-force_load,*)
            _force_load_archives+=("\${arg#-Wl,-force_load,}") ;;
        *.a)
            if [[ \${_all_load} -eq 1 ]]; then
                _archive_args+=("\$arg")
            else
                _other_args+=("\$arg")
            fi ;;
        *)
            _other_args+=("\$arg") ;;
    esac
done

# Debug: log what was intercepted
if [[ -f "\${_log}" ]] && ! grep -q "INTERCEPTED" "\${_log}" 2>/dev/null; then
    echo "INTERCEPTED:" >> "\${_log}"
    echo "  all_load: \${_all_load}" >> "\${_log}"
    echo "  force_load_archives: \${_force_load_archives[*]:-<none>}" >> "\${_log}"
    echo "  archive_args (all_load): \${_archive_args[*]:-<none>}" >> "\${_log}"
    echo "  other_args count: \${#_other_args[@]}" >> "\${_log}"
fi

# Extract archives to temp dir and collect .o files
# Ninja sets CWD to the build directory, so relative paths like
# lib/libLLVMDemangle.a are relative to it. Resolve to absolute before
# cd-ing into the temp extraction directory.
_cwd=\$(pwd)
_extracted=()
if [[ \${#_force_load_archives[@]} -gt 0 ]] || [[ \${#_archive_args[@]} -gt 0 ]]; then
    _tmpdir=\$(mktemp -d)
    trap 'rm -rf "\${_tmpdir}"' EXIT

    _all_archives=("\${_force_load_archives[@]}" "\${_archive_args[@]}")
    for _ar in "\${_all_archives[@]}"; do
        # Resolve relative paths to absolute
        [[ "\$_ar" != /* ]] && _ar="\${_cwd}/\${_ar}"
        if [[ -f "\$_ar" ]]; then
            # Use archive basename + hash to avoid .o name collisions
            _ar_id=\$(basename "\$_ar" .a)_\$(echo "\$_ar" | md5 -q 2>/dev/null || md5sum <<< "\$_ar" | cut -c1-8)
            _ar_dir="\${_tmpdir}/\${_ar_id}"
            mkdir -p "\${_ar_dir}"
            (cd "\${_ar_dir}" && ar x "\$_ar")
            for _o in "\${_ar_dir}"/*.o; do
                [[ -f "\$_o" ]] && _extracted+=("\$_o")
            done
        fi
    done
fi

exec "\${_real_cxx}" "\${_other_args[@]}" "\${_extracted[@]}"
FORCELOAD
    chmod +x "${ZIG_CXX_FORCELOAD}"

    # Override ZIG_CXX so all subsequent cmake references use the force-load wrapper
    export ZIG_CXX="${ZIG_CXX_FORCELOAD}"
fi

# Clear conda's compiler flags — zig handles optimization internally.
# CMAKE_ARGS: conda-build sets this with architecture-specific flags (e.g.
# -DCMAKE_OSX_ARCHITECTURES=x86_64, -mcpu=core2 for osx-64 cross-builds)
# that conflict with zig's own target/CPU handling.
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS CMAKE_ARGS
export CFLAGS="" CXXFLAGS="" LDFLAGS="" CPPFLAGS=""

echo "  ZIG_TRIPLET: ${ZIG_TRIPLET}"
echo "  ZIG_CC: ${ZIG_CC}"
echo "  ZIG_CXX: ${ZIG_CXX}"
echo "  ZIG_CXX_SHARED: ${ZIG_CXX_SHARED}"
echo "  ZIG_AR: ${ZIG_AR}"

# LLVM_TRIPLET is set by recipe.yaml env (standard LLVM triple, no glibc version suffix)
echo "  LLVM_TRIPLET: ${LLVM_TRIPLET}"

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
    -DCMAKE_OSX_ARCHITECTURES="${_osx_arch}"
  )
fi

# non-Unix: path-length workaround, zstd config, and atexit collision fix
is_not_unix && {
    # zstd on conda-forge Windows: only libzstd.dll exists (no import library).
    # conda's zstdConfig.cmake declares zstd::libzstd_shared with IMPORTED_IMPLIB
    # pointing to a non-existent .lib file, causing cmake to error.
    # Disable zstd to avoid the broken cmake config.
    #
    # atexit collision: zig's mingw dllcrt2.obj defines atexit.
    # lld's AutoExporter excludes dllcrt2.o but NOT dllcrt2.obj (zig's name).
    # So atexit leaks into libLLVM-20.dll.a. When libclang-cpp.dll links
    # its own CRT + libLLVM-20.dll.a, atexit collides.
    # zig's lld rejects --exclude-symbols and --allow-multiple-definition.
    #
    # Fix: Two-phase build. Build libLLVM first, strip atexit from import
    # lib with objcopy, then build remaining targets (libclang-cpp etc.).
    # Patch 0003 removes --export-all-symbols from libclang-cpp CMakeLists.
    CMAKE_PLATFORM_FLAGS=(
      -DCMAKE_OBJECT_PATH_MAX=1024
      -DLLVM_USE_INTEL_JITEVENTS=ON
      -DLLVM_ENABLE_DUMP=ON
      -DLLVM_ENABLE_ZSTD=OFF
      -DLLVM_EXPORT_SYMBOLS_FOR_PLUGINS=OFF
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

  # Create marker file
  echo "${LLVM_INSTALL}" > "${PREFIX}/lib/zig-llvm-path.txt"

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
  echo "  To speed up future builds, populate cache after successful build:"
  echo "    mkdir -p ${RECIPE_DIR}/cache"
  echo "    cp -r \${PREFIX}/lib/zig-llvm ${RECIPE_DIR}/cache/"
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

  # Runtimes to build and platform-specific flags
  _RUNTIMES_LIST="libcxxabi;libcxx"
  _RUNTIMES_FLAGS=(
    -DLIBCXXABI_ENABLE_SHARED=ON
    -DLIBCXXABI_ENABLE_STATIC=OFF
    -DLIBCXXABI_USE_COMPILER_RT=ON
    -DLIBCXX_ENABLE_SHARED=ON
    -DLIBCXX_ENABLE_STATIC=OFF
    -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=OFF
    -DLIBCXX_USE_COMPILER_RT=ON
    -DLIBCXX_CXX_ABI=libcxxabi
  )

  if is_unix; then
    # Unix: also build libunwind (Windows uses SEH, not DWARF unwinding)
    _RUNTIMES_LIST="libunwind;${_RUNTIMES_LIST}"
    _RUNTIMES_FLAGS+=(
      -DLIBUNWIND_ENABLE_SHARED=ON
      -DLIBUNWIND_ENABLE_STATIC=OFF
      -DLIBUNWIND_USE_COMPILER_RT=ON
      -DLIBCXXABI_USE_LLVM_UNWINDER=ON
    )
    # Override zig cc's default -fvisibility=hidden so libc++ symbols are public
    # and genuinely shared between libLLVM.so and libclang-cpp.so.
    _RUNTIMES_CMAKE+=(
      -DCMAKE_C_FLAGS="-fvisibility=default"
      -DCMAKE_CXX_FLAGS="-fvisibility=default"
      -DCMAKE_SKIP_RPATH=ON
    )
    _RUNTIMES_CMAKE+=(-DLLVM_CONFIG_PATH="${BUILD_PREFIX}/bin/llvm-config")
  else
    # Windows/MinGW: libc++ uses __declspec(dllexport) via _LIBCPP_DLL_VIS,
    # no visibility flags needed. No rpath on Windows.
    # Windows: libcxxabi doesn't use libunwind
    _RUNTIMES_FLAGS+=(-DLIBCXXABI_USE_LLVM_UNWINDER=OFF)
  fi

  # macOS: tell cmake the correct arch (prevents -mcpu=core2 on cross-builds)
  if is_osx; then
    _RUNTIMES_CMAKE+=(-DCMAKE_OSX_ARCHITECTURES="${_osx_arch}")
  fi

  echo "  Building runtimes: ${_RUNTIMES_LIST}..."
  mkdir -p "${SRC_DIR}/conda-runtimes-build"

  _runtimes_ok=1
  if is_not_unix; then
    # Windows runtimes build is exploratory — don't fail the whole build
    echo "  [Windows: runtimes build is exploratory, non-fatal]"
    if cmake -S "${LIBCXX_SRC}" -B "${SRC_DIR}/conda-runtimes-build" \
        "${_RUNTIMES_CMAKE[@]}" \
        -DLLVM_ENABLE_RUNTIMES="${_RUNTIMES_LIST}" \
        "${_RUNTIMES_FLAGS[@]}" \
        -G Ninja 2>&1; then
      cmake --build "${SRC_DIR}/conda-runtimes-build" -j"${CPU_COUNT}" 2>&1 && \
      cmake --install "${SRC_DIR}/conda-runtimes-build" 2>&1 || _runtimes_ok=0
    else
      _runtimes_ok=0
    fi
    if [[ ${_runtimes_ok} -eq 0 ]]; then
      echo "  WARNING: Windows runtimes build failed (exploratory, continuing)"
    fi
  else
    cmake -S "${LIBCXX_SRC}" -B "${SRC_DIR}/conda-runtimes-build" \
      "${_RUNTIMES_CMAKE[@]}" \
      -DLLVM_ENABLE_RUNTIMES="${_RUNTIMES_LIST}" \
      "${_RUNTIMES_FLAGS[@]}" \
      -G Ninja
    cmake --build "${SRC_DIR}/conda-runtimes-build" -j"${CPU_COUNT}"
    cmake --install "${SRC_DIR}/conda-runtimes-build"
  fi

  echo "  libc++ runtimes installed to ${LLVM_INSTALL}/lib"

  # === Verify libc++ runtimes ===
  echo "=== Verifying libc++ runtime installation ==="
  ls -la "${LLVM_INSTALL}/lib/"libc++* 2>/dev/null || true
  if is_not_unix; then
    # Windows: expect .dll + .dll.a (import library)
    ls -la "${LLVM_INSTALL}/bin/"libc++* 2>/dev/null || true
  fi

fi

_CLANG=(
  -DCLANG_ENABLE_OBJC_REWRITER=ON
  -DCLANG_LINK_CLANG_DYLIB=ON

  -DCLANG_BUILD_TOOLS=OFF
  -DCLANG_ENABLE_ARCMT=OFF
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF
  -DCLANG_INCLUDE_DOCS=OFF
  -DCLANG_INCLUDE_TESTS=OFF
  -DCLANG_TOOL_CLANG_IMPORT_TEST_BUILD=OFF
  -DCLANG_TOOL_CLANG_LINKER_WRAPPER_BUILD=OFF
  -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF
  -DCLANG_TOOL_LIBCLANG_BUILD=OFF
)

_LLVM=(
  -DLLVM_BUILD_TOOLS=ON
  -DLLVM_BUILD_LLVM_DYLIB=ON
  -DLLVM_DYLIB_COMPONENTS="all"
  -DLLVM_ENABLE_LIBCXX=ON
  -DLLVM_ENABLE_LIBXML2=ON
  -DLLVM_ENABLE_PROJECTS="clang;lld"
  -DLLVM_ENABLE_RTTI=ON
  -DLLVM_ENABLE_ZLIB=ON
  -DLLVM_LINK_LLVM_DYLIB=ON
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64;ARM;PowerPC;RISCV;WebAssembly;SystemZ;AMDGPU;AVR;NVPTX"
  -DLLVM_TOOL_LLVM_CONFIG_BUILD=ON

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
  # Disable all tools except llvm-config (saves significant build time)
  -DLLVM_TOOL_BUGPOINT_BUILD=OFF
  -DLLVM_TOOL_DSYMUTIL_BUILD=OFF
  -DLLVM_TOOL_GOLD_BUILD=OFF
  -DLLVM_TOOL_LLC_BUILD=OFF
  -DLLVM_TOOL_LLI_BUILD=OFF
  -DLLVM_TOOL_LLVM_AR_BUILD=OFF
  -DLLVM_TOOL_LLVM_AS_BUILD=OFF
  -DLLVM_TOOL_LLVM_BCANALYZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_CAT_BUILD=OFF
  -DLLVM_TOOL_LLVM_CFI_VERIFY_BUILD=OFF
  -DLLVM_TOOL_LLVM_COV_BUILD=OFF
  -DLLVM_TOOL_LLVM_CVTRES_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXFILT_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXMAP_BUILD=OFF
  -DLLVM_TOOL_LLVM_DIFF_BUILD=OFF
  -DLLVM_TOOL_LLVM_DIS_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWARFDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWARFUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWP_BUILD=OFF
  -DLLVM_TOOL_LLVM_EXEGESIS_BUILD=OFF
  -DLLVM_TOOL_LLVM_EXTRACT_BUILD=OFF
  -DLLVM_TOOL_LLVM_GSYMUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_IFS_BUILD=OFF
  -DLLVM_TOOL_LLVM_JITLINK_BUILD=OFF
  -DLLVM_TOOL_LLVM_LINK_BUILD=OFF
  -DLLVM_TOOL_LLVM_LIPO_BUILD=OFF
  -DLLVM_TOOL_LLVM_LTO2_BUILD=OFF
  -DLLVM_TOOL_LLVM_LTO_BUILD=OFF
  -DLLVM_TOOL_LLVM_MCA_BUILD=OFF
  -DLLVM_TOOL_LLVM_MC_BUILD=OFF
  -DLLVM_TOOL_LLVM_ML_BUILD=OFF
  -DLLVM_TOOL_LLVM_MODEXTRACT_BUILD=OFF
  -DLLVM_TOOL_LLVM_MT_BUILD=OFF
  -DLLVM_TOOL_LLVM_NM_BUILD=OFF
  -DLLVM_TOOL_LLVM_OBJCOPY_BUILD=OFF
  -DLLVM_TOOL_LLVM_OBJDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_OPT_REPORT_BUILD=OFF
  -DLLVM_TOOL_LLVM_PDBUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_PROFDATA_BUILD=OFF
  -DLLVM_TOOL_LLVM_PROFGEN_BUILD=OFF
  -DLLVM_TOOL_LLVM_RC_BUILD=OFF
  -DLLVM_TOOL_LLVM_READOBJ_BUILD=OFF
  -DLLVM_TOOL_LLVM_REDUCE_BUILD=OFF
  -DLLVM_TOOL_LLVM_RTDYLD_BUILD=OFF
  -DLLVM_TOOL_LLVM_SIM_BUILD=OFF
  -DLLVM_TOOL_LLVM_SIZE_BUILD=OFF
  -DLLVM_TOOL_LLVM_SPLIT_BUILD=OFF
  -DLLVM_TOOL_LLVM_STRESS_BUILD=OFF
  -DLLVM_TOOL_LLVM_STRINGS_BUILD=OFF
  -DLLVM_TOOL_LLVM_SYMBOLIZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_TLI_CHECKER_BUILD=OFF
  -DLLVM_TOOL_LLVM_UNDNAME_BUILD=OFF
  -DLLVM_TOOL_LLVM_XRAY_BUILD=OFF
  -DLLVM_TOOL_LTO_BUILD=OFF
  -DLLVM_TOOL_OBJ2YAML_BUILD=OFF
  -DLLVM_TOOL_OPT_BUILD=OFF
  -DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF
  -DLLVM_TOOL_SANCOV_BUILD=OFF
  -DLLVM_TOOL_SANSTATS_BUILD=OFF
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
CMAKE_RC_FLAGS=()
CMAKE_RC_INIT=""
if is_not_unix; then
  # _BUILD_PREFIX: forward-slash unix path version of BUILD_PREFIX,
  # created by build.bat (e.g. /d/a/package-incubator/.../build_env).
  _rc_init="${SRC_DIR}/_cmake_init.cmake"
  _rc_path="${_BUILD_PREFIX}/Library/share/zig/wrappers/zig-rc.bat"
  cat > "${_rc_init}" << CMINIT
# RC compiler with forward-slash path — avoids CMake 4.2 backslash escape bug.
set(CMAKE_RC_COMPILER "${_rc_path}" CACHE FILEPATH "RC compiler")
set(CMAKE_RC_COMPILER_WORKS TRUE CACHE BOOL "RC compiler works")
CMINIT

  CMAKE_RC_INIT="-C${_rc_init}"
elif [[ -n "${ZIG_RC:-}" ]]; then
  CMAKE_RC_FLAGS=(-DCMAKE_RC_COMPILER="${ZIG_RC}")
fi

# Linux: override shared library link rule to use zig-cxx-shared (ld.lld directly).
# macOS: zig-cxx-shared uses ld.lld (ELF), which can't handle Mach-O .dylib files.
# On macOS, zig c++ links shared libs directly; libc++ linking is handled via flags.
CMAKE_SHARED_FLAGS=()
if [[ -n "${ZIG_CXX_SHARED:-}" ]] && is_linux; then
    CMAKE_SHARED_FLAGS=(
      -DCMAKE_CXX_CREATE_SHARED_LIBRARY="${ZIG_CXX_SHARED} <CMAKE_SHARED_LIBRARY_CXX_FLAGS> <LINK_FLAGS> <CMAKE_SHARED_LIBRARY_CREATE_CXX_FLAGS> <SONAME_FLAG><TARGET_SONAME> -o <TARGET> <OBJECTS> <LINK_LIBRARIES>"
      -DCMAKE_SHARED_LINKER_FLAGS="-L${LLVM_INSTALL}/lib -lc++ -lc++abi"
      -DCMAKE_EXE_LINKER_FLAGS="-L${LLVM_INSTALL}/lib -lc++ -lc++abi"
    )
elif is_osx; then
    # macOS workarounds for zig's Mach-O linker:
    # 1. Force-load: ZIG_CXX now points to the force-load wrapper (set above in
    #    the HOTFIX section). It intercepts -Wl,-all_load/-Wl,-force_load, extracts
    #    archives to .o files, and passes them to zig-cxx. For non-link commands
    #    (compilation), it's a transparent passthrough.
    # 2. -fvisibility=default: zig compiles with hidden visibility by default.
    #    On Mach-O, hidden symbols are truly invisible to other dylibs.
    #    Without this, libclang-cpp.dylib can't see libLLVM.dylib's symbols.
    CMAKE_SHARED_FLAGS=(
      -DCMAKE_C_FLAGS="-fvisibility=default"
      -DCMAKE_CXX_FLAGS="-fvisibility=default"
      -DCMAKE_SHARED_LINKER_FLAGS="-L${LLVM_INSTALL}/lib -lc++ -lc++abi"
      -DCMAKE_EXE_LINKER_FLAGS="-L${LLVM_INSTALL}/lib -lc++ -lc++abi"
    )
# elif is_not_unix; then
    # TODO: Windows shared libc++ linking
    # Same problem as Unix: zig statically merges its bundled libc++ into every
    # .dll at link time, creating duplicate copies in LLVM-20.dll and
    # libclang-cpp.dll. Need a zig-cxx-shared equivalent for Windows.
    #
    # Approach: override CMAKE_CXX_CREATE_SHARED_LIBRARY with a wrapper that
    # invokes ld.lld directly (PE/COFF mode), bypassing zig's static libc++
    # merge. Similar to the Linux zig-cxx-shared wrapper but for .dll output.
    #
    # Key differences from Linux zig-cxx-shared:
    # 1. lld uses PE/COFF mode (-flavor gnu or ld.lld --target=x86_64-w64-mingw32)
    # 2. Output is .dll + .dll.a (import library), not .so
    # 3. Need --out-implib=<lib>.dll.a for import library generation
    # 4. DLL entry point: dllcrt2.o from zig's mingw CRT
    # 5. -lc++ -lc++abi resolve to libc++.dll.a / libc++abi.dll.a import libs
    # 6. No -z defs equivalent — Windows linker requires all symbols resolved
    #    (use --allow-multiple-definition for atexit collision)
    #
    # CMAKE_SHARED_FLAGS=(
    #   -DCMAKE_CXX_CREATE_SHARED_LIBRARY="zig-cxx-shared-win <FLAGS> <LINK_FLAGS> -o <TARGET> <OBJECTS> <LINK_LIBRARIES>"
    #   -DCMAKE_SHARED_LINKER_FLAGS="-L${LLVM_INSTALL}/lib -lc++ -lc++abi -Wl,--allow-multiple-definition"
    # )
fi

ulimit -n 4096 2>/dev/null || true
cmake ${CMAKE_RC_INIT:+"${CMAKE_RC_INIT}"} \
  -S "${LLVM_SRC}" -B "${LLVM_BUILD}" \
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

  echo "  stub.o generic_category symbols:"
  nm "${_stub_dir}/stub.o" | grep 'generic_category' || echo "    <none>"

  # Link: use the CMAKE_CXX_CREATE_SHARED_LIBRARY wrapper (zig-cxx-shared)
  echo "  Linking stub.so with zig-cxx-shared wrapper..."
  "${ZIG_CXX_SHARED}" -shared -o "${_stub_dir}/stub.so" \
    -L"${LLVM_INSTALL}/lib" -lc++ -lc++abi \
    "${_stub_dir}/stub.o"

  # Check the stub .so
  echo "  === Checking stub.so ==="
  _fail=0

  echo "  --- Check 1: no local generic_category ---"
  _local_syms=$(nm -a "${_stub_dir}/stub.so" 2>/dev/null | grep 'generic_category' || true)
  echo "  nm -a: ${_local_syms:-<none>}"
  if echo "${_local_syms}" | grep -qP '^[0-9a-f]+ [a-z] '; then
    echo "  FAIL: local generic_category — libc++ baked in"
    _fail=1
  else
    echo "  OK"
  fi

  echo "  --- Check 2: UNDEFINED in dynamic symbols ---"
  _dynsym=$(readelf --dyn-syms --wide "${_stub_dir}/stub.so" 2>/dev/null | grep 'generic_category' || true)
  echo "  readelf --dyn-syms: ${_dynsym:-<none>}"
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
  echo "${_needed}" | sed 's/^/    /'
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
elif is_not_unix; then
  # Reproduce the EXACT atexit collision scenario and validate the fix.
  #
  # The real failure: libLLVM.dll auto-exports atexit (from dllcrt2.obj) into
  # its import lib. libclang-cpp.dll links its own CRT + libLLVM.dll.a → collision.
  #
  # This stub test validates the two-phase-build fix:
  # 1. Build libA.dll (reproduces libLLVM — atexit leaks into import lib)
  # 2. Verify atexit IS in the import lib (confirms the bug exists)
  # 3. Strip atexit with zig objcopy (validates our fix works)
  # 4. Verify atexit is gone from import lib
  # 5. Link libB.dll against cleaned import lib (must succeed)
  #
  # Takes ~5 seconds instead of 2+ hours.
  echo "=== Fast Windows atexit collision test ==="
  _stub_dir="${SRC_DIR}/_stub_test"
  mkdir -p "${_stub_dir}"
  _stub_fail=0

  # Parse semicolon-separated ZIG_CC into array
  IFS=';' read -ra _zig_cc_args <<< "${ZIG_CC}"
  echo "  ZIG_CC parsed: ${_zig_cc_args[*]}"

  _zig_bin="${_native_zig:-${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe}"
  echo "  zig binary: ${_zig_bin}"

  cat > "${_stub_dir}/a.c" << 'ASRC'
int func_a(void) { return 42; }
ASRC
  cat > "${_stub_dir}/b.c" << 'BSRC'
__declspec(dllimport) int func_a(void);
__declspec(dllexport) int func_b(void) { return func_a() + 1; }
BSRC

  echo "  Compiling a.c and b.c..."
  "${_zig_cc_args[@]}" -c -o "${_stub_dir}/a.o" "${_stub_dir}/a.c"
  "${_zig_cc_args[@]}" -c -o "${_stub_dir}/b.o" "${_stub_dir}/b.c"

  # Step 1: Create libA.dll — NO dllexport, so auto-export kicks in (like libLLVM)
  echo "  Step 1: Creating libA.dll (auto-export, like libLLVM)..."
  if ! "${_zig_cc_args[@]}" -shared \
      -o "${_stub_dir}/libA.dll" \
      -Wl,--out-implib,"${_stub_dir}/libA.dll.a" \
      "${_stub_dir}/a.o" 2>"${_stub_dir}/a_err.txt"; then
    echo "    FAIL: cannot create libA.dll"
    head -10 "${_stub_dir}/a_err.txt" | sed 's/^/      /'
    _stub_fail=1
  else
    echo "    OK: libA.dll created"
  fi

  # Step 2: Verify atexit IS in the import lib (confirms bug exists with zig)
  if [[ ${_stub_fail} -eq 0 ]]; then
    echo "  Step 2: Checking if atexit leaked into import lib..."
    if nm "${_stub_dir}/libA.dll.a" 2>/dev/null | grep -qi 'atexit'; then
      echo "    CONFIRMED: atexit present in import lib (this is the bug)"
      nm "${_stub_dir}/libA.dll.a" 2>/dev/null | grep -i 'atexit' | head -3 | sed 's/^/      /'
    else
      echo "    UNEXPECTED: atexit not in import lib — bug may not exist on this zig version"
      echo "    (proceeding anyway to validate fix)"
    fi
  fi

  # Step 3: Reproduce the collision (link libB against libA import lib)
  if [[ ${_stub_fail} -eq 0 ]]; then
    echo "  Step 3: Reproducing collision (libB.dll + libA.dll.a)..."
    if "${_zig_cc_args[@]}" -shared \
        -o "${_stub_dir}/libB_before.dll" \
        "${_stub_dir}/b.o" "${_stub_dir}/libA.dll.a" 2>"${_stub_dir}/b_before_err.txt"; then
      echo "    No collision even before fix — safe (atexit may not be in import lib)"
    else
      if grep -qi 'atexit' "${_stub_dir}/b_before_err.txt"; then
        echo "    CONFIRMED: atexit collision reproduced"
        head -3 "${_stub_dir}/b_before_err.txt" | sed 's/^/      /'
      else
        echo "    FAIL: link failed but NOT due to atexit:"
        head -5 "${_stub_dir}/b_before_err.txt" | sed 's/^/      /'
        _stub_fail=1
      fi
    fi
  fi

  # Step 4: Apply fix — strip atexit from import lib
  if [[ ${_stub_fail} -eq 0 ]]; then
    echo "  Step 4: Stripping atexit from import lib with zig objcopy..."
    if "${_zig_bin}" objcopy --strip-symbol=atexit "${_stub_dir}/libA.dll.a" 2>"${_stub_dir}/objcopy_err.txt"; then
      echo "    OK: objcopy succeeded"
      # Verify atexit is gone
      if nm "${_stub_dir}/libA.dll.a" 2>/dev/null | grep -qi 'atexit'; then
        echo "    FAIL: atexit still present after objcopy!"
        nm "${_stub_dir}/libA.dll.a" 2>/dev/null | grep -i 'atexit' | head -3 | sed 's/^/      /'
        _stub_fail=1
      else
        echo "    OK: atexit removed from import lib"
      fi
    else
      echo "    FAIL: zig objcopy --strip-symbol failed"
      cat "${_stub_dir}/objcopy_err.txt" | sed 's/^/      /'
      echo "    Trying system objcopy as fallback..."
      if objcopy --strip-symbol=atexit "${_stub_dir}/libA.dll.a" 2>"${_stub_dir}/objcopy2_err.txt"; then
        echo "    OK: system objcopy succeeded"
      else
        echo "    FAIL: system objcopy also failed"
        cat "${_stub_dir}/objcopy2_err.txt" | sed 's/^/      /'
        _stub_fail=1
      fi
    fi
  fi

  # Step 5: Link libB against CLEANED import lib (must succeed now)
  if [[ ${_stub_fail} -eq 0 ]]; then
    echo "  Step 5: Linking libB.dll against cleaned import lib..."
    if "${_zig_cc_args[@]}" -shared \
        -o "${_stub_dir}/libB_after.dll" \
        "${_stub_dir}/b.o" "${_stub_dir}/libA.dll.a" 2>"${_stub_dir}/b_after_err.txt"; then
      echo "    OK: libB.dll links successfully after atexit removal"
    else
      echo "    FAIL: libB.dll still fails after fix!"
      head -5 "${_stub_dir}/b_after_err.txt" | sed 's/^/      /'
      _stub_fail=1
    fi
  fi

  if [[ ${_stub_fail} -ne 0 ]]; then
    echo ""
    echo "  ============================================================"
    echo "  EARLY ABORT: Windows atexit collision fix does not work."
    echo "  The two-phase build + objcopy --strip-symbol approach cannot"
    echo "  fix the atexit collision. Need a different strategy."
    echo "  ============================================================"
    rm -rf "${_stub_dir}"
    exit 1
  fi
  echo "  === Windows atexit collision test PASSED ==="
  rm -rf "${_stub_dir}"
fi

echo "=== Building LLVM ==="
if is_not_unix; then
  # Two-phase build on Windows to fix atexit collision.
  # Phase 1: Build libLLVM DLL target only.
  # zig's dllcrt2.obj defines atexit, but lld's AutoExporter only excludes
  # dllcrt2.o (not .obj), so atexit leaks into libLLVM-20.dll.a.
  # After building, strip atexit from the import lib before phase 2.
  echo "  Phase 1: Building LLVM shared library..."
  cmake --build "${LLVM_BUILD}" --target LLVM -j"${CPU_COUNT}"

  # Strip atexit from import library to prevent collision when
  # libclang-cpp.dll links its own CRT + libLLVM-20.dll.a
  _implib=$(find "${LLVM_BUILD}" -name 'libLLVM*.dll.a' -o -name 'LLVM*.dll.a' | head -1)
  if [[ -n "${_implib}" ]]; then
    echo "  Stripping atexit from import lib: ${_implib}"
    if nm "${_implib}" 2>/dev/null | grep -q ' T atexit'; then
      echo "    Found atexit in import lib — stripping"
      # Use zig objcopy (bundled llvm-objcopy) to strip the symbol
      _zig_bin="${_native_zig:-${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe}"
      "${_zig_bin}" objcopy --strip-symbol=atexit "${_implib}" \
        || objcopy --strip-symbol=atexit "${_implib}" 2>/dev/null \
        || echo "    WARNING: could not strip atexit (objcopy not available)"
      # Verify
      if nm "${_implib}" 2>/dev/null | grep -q ' T atexit'; then
        echo "    WARNING: atexit still present after strip attempt"
      else
        echo "    OK: atexit removed"
      fi
    else
      echo "    OK: no atexit in import lib"
    fi
  fi

  # Phase 2: Build remaining targets (libclang-cpp, lld, tools)
  echo "  Phase 2: Building remaining targets..."
  cmake --build "${LLVM_BUILD}" -j"${CPU_COUNT}"
else
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

echo "=== zig-llvm build complete ==="

# Create a marker file for zig build to find this LLVM
echo "${LLVM_INSTALL}" > "${PREFIX}/lib/zig-llvm-path.txt"

