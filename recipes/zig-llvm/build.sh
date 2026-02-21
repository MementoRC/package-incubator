#!/usr/bin/env bash
# Build LLVM with zig cc for zig-llvmdev package
# This produces LLVM/Clang/LLD shared libraries with libc++ ABI
# compatible with zig-cc-built zigcpp

set -euxo pipefail
IFS=$'\n\t'

if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  echo "ERROR: This script requires bash 5.2 or later (found ${BASH_VERSION})"
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
is_not_unix() { ! is_unix; }
is_cross() { [[ "${build_platform}" != "${target_platform}" ]]; }

is_debug() { [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]]; }

echo "=== Building zig-llvmdev with zig cc ==="
echo "  LLVM source: ${SRC_DIR}/llvm-source"
echo "  Target: ${target_platform}"

# Verify zig-compiler package is available
BOOTSTRAP_ZIG="${CONDA_BUILD_ZIG:-}"
if [[ -z "${BOOTSTRAP_ZIG}" ]]; then
  echo "ERROR: CONDA_BUILD_ZIG not set — is zig-compiler installed as build dep?"
  exit 1
fi
echo "  Bootstrap zig: ${BOOTSTRAP_ZIG} ($(${BOOTSTRAP_ZIG} version))"

# Build directories — install to lib/zig-llvm to avoid conflicts with conda-forge llvmdev
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
  
  # Tablegen tools run on the BUILD host, not target.
  # Provided by zig-llvm itself (build dep for cross-compilation).
  LLVM_TBLGEN=""
  CLANG_TBLGEN=""
  for _prefix in "${BUILD_PREFIX}/lib/zig-llvm" "${BUILD_PREFIX}"; do
    if [[ -x "${_prefix}/bin/llvm-tblgen" ]] && [[ -x "${_prefix}/bin/clang-tblgen" ]]; then
      LLVM_TBLGEN="${_prefix}/bin/llvm-tblgen"
      CLANG_TBLGEN="${_prefix}/bin/clang-tblgen"
      break
    fi
  done

  if [[ -z "${LLVM_TBLGEN}" ]]; then
    echo "ERROR: llvm-tblgen/clang-tblgen not found"
    echo "  Cross-compilation requires zig-llvm as a build dependency"
    exit 1
  fi

  CMAKE_CROSS_FLAGS=(
    -DCMAKE_CROSSCOMPILING=True
    -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}"
    -DCMAKE_INSTALL_INCLUDEDIR=include
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_INSTALL_BINDIR=bin
    -DCMAKE_SYSTEM_NAME="${CMAKE_SYSTEM_NAME}"
    -DLLVM_TABLEGEN="${LLVM_TBLGEN}"
    -DCLANG_TABLEGEN="${CLANG_TBLGEN}"
    -DLLVM_DEFAULT_TARGET_TRIPLE="${LLVM_TRIPLET}"
    -DLLVM_HOST_TRIPLE="${LLVM_TRIPLET}"
  )

  echo "  CMAKE_SYSTEM_NAME: ${CMAKE_SYSTEM_NAME}"
  echo "  LLVM_TABLEGEN: ${LLVM_TBLGEN}"
  echo "  CLANG_TABLEGEN: ${CLANG_TBLGEN}"
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
    # Windows: CMake supports semicolon-separated "compiler;arg1;arg2" for
    # CMAKE_C_COMPILER/CXX/ASM — but NOT for CMAKE_AR/RANLIB.
    # .bat wrappers don't work reliably for compilers (cmd.exe quoting issues),
    # so use semicolon syntax for compilers, .bat wrappers only for ar/ranlib.
    # CMake needs a full path to the compiler on Windows.
    # CONDA_BUILD_ZIG may be a bare name like "x86_64-w64-windows-gnu-zig".
    # Resolve to the full path under BUILD_PREFIX/Library/bin/.
    _zig="${BOOTSTRAP_ZIG}"
    if [[ "${_zig}" != */* ]] && [[ "${_zig}" != *\\* ]]; then
        # Bare name — resolve under BUILD_PREFIX
        for _ext in ".exe" ""; do
            _candidate="${BUILD_PREFIX}/Library/bin/${_zig}${_ext}"
            if [[ -f "${_candidate}" ]]; then
                _zig="${_candidate}"
                break
            fi
        done
    fi
    _target="${ZIG_TRIPLET}"
    export ZIG_CC="${_zig};cc;-target;${_target};-mcpu=baseline"
    export ZIG_CXX="${_zig};c++;-target;${_target};-mcpu=baseline"
    export ZIG_ASM="${_zig};cc;-target;${_target};-mcpu=baseline"
    export ZIG_AR="${ZIG_WRAPPERS}/zig-ar.bat"
    export ZIG_RANLIB="${ZIG_WRAPPERS}/zig-ranlib.bat"
    export ZIG_RC="${ZIG_WRAPPERS}/zig-rc.bat"
    export ZIG_CXX_SHARED=""  # not used on Windows
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
# Two issues:
# 1. Wrappers filter -Wl,-all_load/-Wl,-force_load — but LLVM NEEDS these
#    to pull all archive members into libLLVM.dylib (otherwise symbols like
#    _LLVMInitializeAArch64AsmParser are never included). UN-filter them.
# 2. Wrappers lack filters for -exported_symbols_list and related ld64
#    *_list flags that zig's Mach-O linker doesn't support. ADD filters.
# Remove when zig-compiler *_9 ships these fixes.
if is_osx; then
    echo "  Patching macOS zig-cc/zig-cxx wrappers..."
    for _w in "${ZIG_CC}" "${ZIG_CXX}"; do
        # Un-filter -all_load and -force_load (LLVM needs them for dylib)
        # by replacing the drop rule with a pass-through
        sed -i.bak \
          -e 's/-Wl,-all_load|-Wl,-force_load,\*) ;;/-Wl,-all_load|-Wl,-force_load,*) args+=("$arg") ;;/' \
          "${_w}"
        # Add filters for *_list flags zig doesn't support
        sed -i \
          '/-Wl,-all_load|-Wl,-force_load,\*) args+=("$arg") ;;/a\
        -Wl,-exported_symbols_list|-Wl,-exported_symbols_list,*) ;;\
        -Wl,-unexported_symbols_list|-Wl,-unexported_symbols_list,*) ;;\
        -Wl,-force_symbols_not_weak_list|-Wl,-force_symbols_not_weak_list,*) ;;\
        -Wl,-force_symbols_weak_list|-Wl,-force_symbols_weak_list,*) ;;\
        -Wl,-reexported_symbols_list|-Wl,-reexported_symbols_list,*) ;;' "${_w}"
        rm -f "${_w}.bak"
    done
fi

# Clear conda's compiler flags — zig handles optimization internally
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
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
is_osx && CMAKE_PLATFORM_FLAGS=(
  -DLLVM_ENABLE_ZSTD=ON
)

# non-Unix: path-length workaround and zstd config
# CMAKE_OBJECT_PATH_MAX: raise limit to avoid path-too-long warnings
# zstd: conda's zstdConfig.cmake has wrong IMPORTED_IMPLIB for Release config.
#   Overwrite it with a corrected version that sets IMPORTED_IMPLIB_RELEASE.
is_not_unix && {
    # zstd on conda-forge Windows: only libzstd.dll exists (no import library).
    # conda's zstdConfig.cmake declares zstd::libzstd_shared with IMPORTED_IMPLIB
    # pointing to a non-existent .lib file, causing cmake to error.
    # Disable zstd to avoid the broken cmake config.
    #
    # --allow-multiple-definition: zig's mingw dllcrt2.obj defines atexit, and
    # --export-all-symbols causes it to leak into libLLVM-20.dll.a; when
    # libclang-cpp.dll links both its own CRT and libLLVM-20.dll.a, atexit
    # collides. This flag tells lld to accept the first definition silently.
    CMAKE_PLATFORM_FLAGS=(
      -DCMAKE_OBJECT_PATH_MAX=1024
      -DLLVM_USE_INTEL_JITEVENTS=ON
      -DLLVM_ENABLE_DUMP=ON
      -DLLVM_ENABLE_ZSTD=OFF
      -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--allow-multiple-definition"
      -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-multiple-definition"
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
    echo "  Test 2a: macOS flags that MUST pass through (needed by LLVM)..."
    _link_flags=(
        -Wl,-all_load
    )
    echo "  Test 2b: macOS flags that should be filtered by hotfix..."
    # Create a minimal export file
    echo "_test_func" > "${_test_dir}/exports.txt"
    _link_flags+=(
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

if [[ "${target_platform}" == linux-* ]] || [[ "${target_platform}" == osx-* ]]; then
  echo "=== Building libc++/libc++abi/libunwind with zig cc (-fvisibility=default) ==="
  # Build runtimes BEFORE LLVM so libLLVM.so links against the already-installed
  # libc++.so.1 (NEEDED entry). Built with -fvisibility=default so symbols are
  # genuinely public and shared.
  LIBCXX_SRC="${SRC_DIR}/runtimes"

  _RUNTIMES_CMAKE=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}"
    -DCMAKE_C_COMPILER="${ZIG_CC}"
    -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
    -DCMAKE_ASM_COMPILER="${ZIG_ASM}"
    -DCMAKE_AR="${ZIG_AR}"
    -DCMAKE_RANLIB="${ZIG_RANLIB}"
    # Override zig cc's default -fvisibility=hidden so libc++ symbols are public
    # and genuinely shared between libLLVM.so and libclang-cpp.so.
    -DCMAKE_C_FLAGS="-fvisibility=default"
    -DCMAKE_CXX_FLAGS="-fvisibility=default"
    -DCMAKE_SKIP_RPATH=ON
    -DLLVM_CONFIG_PATH="${BUILD_PREFIX}/bin/llvm-config"
  )

  # Build all three runtimes in one invocation so inter-dependencies (libcxxabi
  # needing libunwind in LLVM_ENABLE_RUNTIMES) are satisfied automatically.
  echo "  Building libunwind + libcxxabi + libcxx..."
  mkdir -p "${SRC_DIR}/conda-runtimes-build"
  cmake -S "${LIBCXX_SRC}" -B "${SRC_DIR}/conda-runtimes-build" \
    "${_RUNTIMES_CMAKE[@]}" \
    -DLLVM_ENABLE_RUNTIMES="libunwind;libcxxabi;libcxx" \
    -DLIBUNWIND_ENABLE_SHARED=ON \
    -DLIBUNWIND_ENABLE_STATIC=OFF \
    -DLIBUNWIND_USE_COMPILER_RT=ON \
    -DLIBCXXABI_ENABLE_SHARED=ON \
    -DLIBCXXABI_ENABLE_STATIC=OFF \
    -DLIBCXXABI_USE_COMPILER_RT=ON \
    -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
    -DLIBCXX_ENABLE_SHARED=ON \
    -DLIBCXX_ENABLE_STATIC=OFF \
    -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=OFF \
    -DLIBCXX_USE_COMPILER_RT=ON \
    -DLIBCXX_CXX_ABI=libcxxabi \
    -G Ninja
  cmake --build "${SRC_DIR}/conda-runtimes-build" -j"${CPU_COUNT}"
  cmake --install "${SRC_DIR}/conda-runtimes-build"

  echo "  libc++ runtimes installed to ${LLVM_INSTALL}/lib"

  # === Verify libc++ runtimes and symlinks ===
  echo "=== Verifying libc++ runtime installation ==="
  ls -la "${LLVM_INSTALL}/lib/"libc++* || true

  # Ensure linker symlinks exist (CMake install may skip them)
  if [[ ! -e "${LLVM_INSTALL}/lib/libc++.so.1" ]]; then
    ln -sf libc++.so.1.0 "${LLVM_INSTALL}/lib/libc++.so.1"
  fi
  if [[ ! -e "${LLVM_INSTALL}/lib/libc++abi.so" ]]; then
    ln -sf libc++abi.so.1.0 "${LLVM_INSTALL}/lib/libc++abi.so"
  fi
  if [[ ! -e "${LLVM_INSTALL}/lib/libc++abi.so.1" ]]; then
    ln -sf libc++abi.so.1.0 "${LLVM_INSTALL}/lib/libc++abi.so.1"
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

# RC compiler (only meaningful on Windows, harmless elsewhere)
CMAKE_RC_FLAGS=(-DCMAKE_RC_COMPILER="${ZIG_RC}")

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
    CMAKE_SHARED_FLAGS=(
      -DCMAKE_SHARED_LINKER_FLAGS="-L${LLVM_INSTALL}/lib -lc++ -lc++abi"
      -DCMAKE_EXE_LINKER_FLAGS="-L${LLVM_INSTALL}/lib -lc++ -lc++abi"
    )
fi

ulimit -n 4096 2>/dev/null || true
cmake -S "${LLVM_SRC}" -B "${LLVM_BUILD}" \
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

# === Fast stub .so test ===
# Before spending hours on the real LLVM build, create a tiny .so that
# references std::generic_category() — exactly what libLLVM.so and
# libclang-cpp.so will do.  Check that the stub .so has:
#   1. No local generic_category (no static libc++ merge)
#   2. UNDEFINED generic_category in dynamic symbols
#   3. libc++.so in NEEDED entries
# This takes seconds, not 40 minutes.
if [[ "${target_platform}" == linux-* ]]; then
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
elif [[ "${target_platform}" == osx-* ]]; then
  echo "=== Fast macOS stub test (verify -all_load passes through wrapper) ==="
  _stub_dir="${SRC_DIR}/_stub_test"
  mkdir -p "${_stub_dir}"

  # Create two .o files: one referenced, one unreferenced (like LLVM targets).
  # Without -all_load, the linker won't pull unreferenced.o from the archive.
  cat > "${_stub_dir}/referenced.c" << 'EOF'
int referenced_func(void) { return 1; }
EOF
  cat > "${_stub_dir}/unreferenced.c" << 'EOF'
int unreferenced_func(void) { return 2; }
EOF
  cat > "${_stub_dir}/main.c" << 'EOF'
extern int referenced_func(void);
int main(void) { return referenced_func(); }
EOF

  echo "  Compiling test objects..."
  "${ZIG_CC}" -c -fPIC -o "${_stub_dir}/referenced.o" "${_stub_dir}/referenced.c"
  "${ZIG_CC}" -c -fPIC -o "${_stub_dir}/unreferenced.o" "${_stub_dir}/unreferenced.c"

  echo "  Creating test archive..."
  "${ZIG_AR}" rcs "${_stub_dir}/libtest.a" "${_stub_dir}/referenced.o" "${_stub_dir}/unreferenced.o"

  echo "  Test 1: linking dylib WITH -Wl,-all_load (must include unreferenced_func)..."
  if "${ZIG_CC}" -shared -Wl,-all_load -o "${_stub_dir}/test_allload.dylib" "${_stub_dir}/libtest.a" 2>"${_stub_dir}/err.txt"; then
    _syms=$(nm -gU "${_stub_dir}/test_allload.dylib" 2>/dev/null | grep 'unreferenced_func' || true)
    if [[ -n "${_syms}" ]]; then
      echo "  OK: -all_load works, unreferenced_func is in dylib"
    else
      echo "  FAIL: dylib created but unreferenced_func missing — -all_load not working"
      echo "  This will cause undefined _LLVMInitialize* errors"
      nm -gU "${_stub_dir}/test_allload.dylib" 2>/dev/null | head -10 | sed 's/^/    /'
      exit 1
    fi
  else
    echo "  FAIL: -Wl,-all_load not accepted by zig wrapper"
    cat "${_stub_dir}/err.txt" | head -5 | sed 's/^/    /'
    echo ""
    echo "  The wrapper is filtering -all_load. LLVM needs it to pull all"
    echo "  target .o files into libLLVM.dylib. Check the hotfix in build.sh."
    exit 1
  fi

  echo "  Test 2: linking dylib WITHOUT -all_load (unreferenced_func should be absent)..."
  "${ZIG_CC}" -shared -o "${_stub_dir}/test_noallload.dylib" \
    -L"${_stub_dir}" -ltest "${_stub_dir}/referenced.o" 2>/dev/null || true
  # This test is informational — just confirms the difference

  echo "  === macOS stub test PASSED ==="
  rm -rf "${_stub_dir}"
fi

echo "=== Building LLVM ==="
cmake --build "${LLVM_BUILD}" -j"${CPU_COUNT}"

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

