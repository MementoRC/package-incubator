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

  # ppc64le: zig's self-hosted linker looks for `cc` in PATH to use as the
  # GCC linker driver, but needs the cross-GCC for ppc64le. Create a `cc`
  # symlink so zig finds the right linker. Also skip CMake's link test since
  # zig's self-hosted linker injects -m elf64lppc then chokes on it.
  # TODO: Remove once zig fixes self-hosted linker for ppc64le.
  if [[ "${LLVM_TRIPLET}" == powerpc64le-* ]]; then
    # Force CMake to skip compiler linking tests. zig's self-hosted linker
    # injects -m elf64lppc then chokes on it, and CMAKE_TRY_COMPILE_TARGET_TYPE
    # doesn't prevent CMakeTestCCompiler from linking. Compilation is verified
    # by the pre-flight test above; linking isn't needed (libraries only).
    CMAKE_CROSS_FLAGS+=(
      -DCMAKE_C_COMPILER_WORKS=TRUE
      -DCMAKE_CXX_COMPILER_WORKS=TRUE
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    )
    # zig's self-hosted linker looks for `cc` in PATH as GCC linker driver for
    # compilation, but invokes ld.bfd directly from GCC's libexec path for linking.
    # The sysroot's libpthread.so is a GNU ld script with absolute paths:
    #   GROUP ( /lib64/libpthread.so.0 /usr/lib64/libpthread_nonshared.a )
    # ld.bfd resolves these from the build host's /lib64 (x86_64) rather than the
    # ppc64le sysroot, because zig's self-hosted linker doesn't pass --sysroot.
    # Fix: wrap the ld.bfd binary in GCC's libexec path with a script that injects
    # --sysroot before any other args. This ensures all ld.bfd invocations (whether
    # from GCC or zig's self-hosted linker) get the correct sysroot.
    _ppc_gcc="${BUILD_PREFIX}/bin/powerpc64le-conda-linux-gnu-gcc"
    _ppc_sysroot_early="${BUILD_PREFIX}/powerpc64le-conda-linux-gnu/sysroot"
    if [[ -x "${_ppc_gcc}" ]]; then
      _ppc_bin="${SRC_DIR}/_ppc64le_bin"
      mkdir -p "${_ppc_bin}"
      ln -sf "${_ppc_gcc}" "${_ppc_bin}/cc"
      export PATH="${_ppc_bin}:${PATH}"
      echo "  ppc64le: cc -> ${_ppc_gcc}"

      # Wrap ld.bfd to inject --sysroot automatically.
      # zig's self-hosted linker calls ld.bfd directly from GCC's libexec path
      # (as a symlink -> $BUILD_PREFIX/bin/powerpc64le-conda-linux-gnu-ld),
      # bypassing GCC's spec-file sysroot injection. We intercept by replacing
      # the real ld binary with a wrapper that adds --sysroot, then renaming
      # the original to ld.real. The libexec symlink keeps pointing to bin/ld
      # which is now the wrapper.
      _ppc_ld_bin="${BUILD_PREFIX}/bin/powerpc64le-conda-linux-gnu-ld"
      if [[ -x "${_ppc_ld_bin}" ]] && [[ ! -f "${_ppc_ld_bin}.real" ]]; then
        mv "${_ppc_ld_bin}" "${_ppc_ld_bin}.real"
        # zig's self-hosted linker drops -lpthread/-ldl when building its ld.bfd
        # invocation for ppc64le — it only passes -lgcc/-lgcc_s/-lc as implicit
        # libs. This causes -z defs to fail on libunwind.so (pthread_rwlock_*
        # and dladdr/dlsym undefined). We inject -lpthread -ldl after the
        # object files for any -shared build. The --sysroot ensures ld.bfd finds
        # libpthread.so.0 in the sysroot rather than the build host's /lib64.
        cat > "${_ppc_ld_bin}" << PPCLD
#!/usr/bin/env bash
_args=("--sysroot=${_ppc_sysroot_early}")
_is_shared=0
_has_libcxx=0
for _a in "\$@"; do
    [[ "\$_a" == "-shared" ]]    && _is_shared=1
    [[ "\$_a" == */libc++.a ]]   && _has_libcxx=1
    _args+=("\$_a")
done
if (( _is_shared )); then
    _args+=(-L"${_ppc_sysroot_early}/usr/lib64" -L"${_ppc_sysroot_early}/usr/lib" -lpthread -ldl)
fi
# GCC redirect uses 'gcc' not 'g++', so -lstdc++ is never added automatically.
# zig's bundled libc++.a/string.o (.toc) references typeinfo for std::length_error,
# which lives in libstdc++.so on ppc64le Linux. Inject it for executable links only
# (shared libs use -nostdlib++ and don't need it here).
if (( !_is_shared )) && (( _has_libcxx )); then
    _args+=(-L"${_ppc_sysroot_early}/usr/lib64" -L"${_ppc_sysroot_early}/usr/lib" -lstdc++)
fi
exec "${_ppc_ld_bin}.real" "\${_args[@]}"
PPCLD
        chmod +x "${_ppc_ld_bin}"
        echo "  ppc64le: ld.bfd wrapped at ${_ppc_ld_bin} -> injects --sysroot + -lpthread -ldl for shared"
      fi
    fi
  fi


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
  # cross architecture (e.g. ppc64le), producing .o that can't link on
  # the build host (x86_64).
  if is_linux; then
    # Linux cross-builds: use BUILD_PREFIX zig-gcc wrappers for NATIVE tools.
    # The wrappers (from zig-gcc build dep) target the build host (x86_64) and
    # include sysroot detection, flag filtering, LLD auto-promotion, and
    # --no-dependent-libraries. Using raw "zig cc" bypasses all of that.
    _native_cc="${BUILD_PREFIX}/share/zig/wrappers/${ZIG_TARGET_BUILD}-zig-cc"
    _native_cxx="${BUILD_PREFIX}/share/zig/wrappers/${ZIG_TARGET_BUILD}-zig-cxx"
    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${_native_cc};-DCMAKE_CXX_COMPILER=${_native_cxx};-DLLVM_ENABLE_ZSTD=OFF"
    )
  elif is_not_unix; then
    _host_cc_exe="${BUILD_PREFIX}/Library/share/zig/wrappers/${ZIG_TARGET_BUILD}-zig-cc.exe"
    _host_cxx_exe="${BUILD_PREFIX}/Library/share/zig/wrappers/${ZIG_TARGET_BUILD}-zig-cxx.exe"
    _host_ar_bat="${BUILD_PREFIX}/Library/share/zig/wrappers/${ZIG_TARGET_BUILD}-zig-ar.bat"
    _host_ranlib_bat="${BUILD_PREFIX}/Library/share/zig/wrappers/${ZIG_TARGET_BUILD}-zig-ranlib.bat"

    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${_host_cc_exe};-DCMAKE_CXX_COMPILER=${_host_cxx_exe};-DCMAKE_AR=${_host_ar_bat};-DCMAKE_RANLIB=${_host_ranlib_bat};-DLLVM_ENABLE_ZSTD=OFF;-DCMAKE_OBJECT_PATH_MAX=1024"
    )
    echo "  HOST_CC: ${_host_cc_exe}"
    echo "  HOST_CXX: ${_host_cxx_exe}"
  fi

  echo "  CMAKE_SYSTEM_NAME: ${CMAKE_SYSTEM_NAME}"
  echo "  LLVM_TABLEGEN: ${LLVM_TBLGEN}"
  echo "  CLANG_TABLEGEN: ${CLANG_TBLGEN}"
  echo "  LLVM_NATIVE_TOOL_DIR: ${_tblgen_dir:-<not set>}"
fi

# Use zig compiler wrappers provided by the zig-compiler package.
# These are pre-built wrappers with flag filtering and sysroot detection.
# On Windows, conda packages install under Library/
ZIG_WRAPPERS="${BUILD_PREFIX}/share/zig/wrappers"
is_not_unix && ZIG_WRAPPERS="${BUILD_PREFIX}/Library/share/zig/wrappers"
if [[ ! -d "${ZIG_WRAPPERS}" ]]; then
  echo "ERROR: zig wrappers not found at ${ZIG_WRAPPERS}"
  echo "  Is zig-compiler installed as a build dependency?"
  exit 1
fi

if is_not_unix; then
  # Use the pre-built shim wrappers — they hardcode the cc/c++ subcommand internally,
  # so cmake's compiler probe (--target=<triple> -print-target-triple) works correctly.
  # Shims are installed side-by-side in Library/share/zig/wrappers/ by both the
  # build-host and target-host wrapper packages.
  _shim_cc="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cc.exe"
  if [[ ! -x "${_shim_cc}" ]]; then
    echo "ERROR: zig cc shim not found at ${_shim_cc}"
    ls "${ZIG_WRAPPERS}/"*zig* 2>/dev/null || true
    exit 1
  fi
  "${_shim_cc}" --version

  export ZIG_CC="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cc.exe"
  export ZIG_CXX="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cxx.exe"
  export ZIG_ASM="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cc.exe"
  export ZIG_AR="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-ar.bat"
  export ZIG_RANLIB="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-ranlib.bat"
  export ZIG_RC="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-rc.bat"
else
  export ZIG_CC="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cc"
  export ZIG_CXX="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cxx"
  export ZIG_AR="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-ar"
  export ZIG_RANLIB="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-ranlib"
  export ZIG_ASM="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-asm"
  export ZIG_RC="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-rc"
fi

# macOS force-load wrapper: zig _14+ provides zig-force-load-cxx which handles
# -Wl,-all_load/-Wl,-force_load by extracting archives to .o files, in c++ mode.
# Set as CMAKE_CXX_COMPILER so it handles both compile and link commands;
# force-load logic only activates when those flags are present.
# _14 also fixes the relative-path bug (archives resolved to absolute before cd+ar x).
if is_osx; then
    if [[ -x "${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-force-load-cxx" ]]; then
        export ZIG_CXX="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-force-load-cxx"
    else
        echo "ERROR: ${ZIG_TARGET_HOST}-zig-force-load-cxx not found in ${ZIG_WRAPPERS}"
        exit 1
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
    for _wrapper in "${ZIG_WRAPPERS}/_zig-cc-common.sh" "${ZIG_CXX}" "${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cc" "${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cxx"; do
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
    for _diag_wrapper in "${ZIG_WRAPPERS}/_zig-cc-common.sh" "${ZIG_CXX}" "${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cc" "${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cxx"; do
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
  # Bypass FindZstd's CMAKE_PREFIX_PATH search — cross-builds must use the
  # target-arch zstd from zig-zstd, not the host-arch copy in BUILD_PREFIX.
  # ZSTD_LIBRARY/ZSTD_INCLUDE_DIR take full precedence over zstd_ROOT hints.
  -DZSTD_LIBRARY="${PREFIX}/lib/zig-zstd/lib/libzstd.so"
  -DZSTD_INCLUDE_DIR="${PREFIX}/lib/zig-zstd/include"
)
# Consumer links (llvm-ar etc.) need -rpath-link at LINK time to find
# libLLVM.so's transitive deps (libz, libzstd, libxml2). For sysroot-less
# targets (riscv64, s390x) these live in zig-* isolated dirs. Non-existent
# dirs are silently ignored, so this is safe for all linux targets.
if is_linux; then
  _rpath_link_zig="-Wl,-rpath-link,${PREFIX}/lib/zig-zlib/lib -Wl,-rpath-link,${PREFIX}/lib/zig-zstd/lib -Wl,-rpath-link,${PREFIX}/lib/zig-libxml2/lib"
  CMAKE_PLATFORM_FLAGS+=(
    -DCMAKE_EXE_LINKER_FLAGS_INIT="${_rpath_link_zig}"
    -DCMAKE_SHARED_LINKER_FLAGS_INIT="${_rpath_link_zig}"
  )
  unset _rpath_link_zig
fi
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

# === Hotfix: ppc64le wrapper LLD block ===
# The zig wrapper hard-errors on ppc64le when it sees standard ELF linker flags
# (--version-script, --gc-sections, etc.) because it classifies them as "LLD-only"
# and LLD lacks ppc64le relocation support. But these flags are standard GNU ld
# flags that ld.bfd handles natively. Patch the installed wrapper to:
# 1. Only error on explicit -fuse-ld=lld, not auto-promoted ELF flags
# 2. Filter -Bsymbolic* on ppc64le (zig's self-hosted linker rejects it before ld.bfd)
# TODO: Remove once zig-feedstock publishes a build with this fix.
_zig_common="${ZIG_WRAPPERS}/_zig-cc-common.sh"
if [[ -f "${_zig_common}" ]] && grep -q 'Block LLD on ppc64le' "${_zig_common}" 2>/dev/null; then
    echo "=== Patching installed zig wrapper for ppc64le LLD compatibility ==="
    python3 - "${_zig_common}" << 'PATCH_EOF'
import re, sys
p = sys.argv[1]
t = open(p).read()
# 1. Replace hard-error LLD block with graceful fallback:
#    only error on explicit -fuse-ld=lld, reset _use_lld=0 for auto-promoted flags
old_block = re.compile(r'# --- Block LLD on ppc64le.*?^fi', re.MULTILINE | re.DOTALL)
new_block = (
    '# --- ppc64le: LLD lacks relocation support, but ld.bfd handles ELF flags ---\n'
    'if (( _use_lld )) && [[ "powerpc64le" == "powerpc64le" ]]; then\n'
    '    _explicit_lld=0\n'
    '    for _a in "$@"; do\n'
    '        [[ "$_a" == "-fuse-ld=lld" ]] && _explicit_lld=1 && break\n'
    '    done\n'
    '    if (( _explicit_lld )); then\n'
    '        echo "zig cc: error: -fuse-ld=lld is not supported on ppc64le" >&2\n'
    '        exit 1\n'
    '    fi\n'
    '    _use_lld=0\n'
    'fi'
)
t = old_block.sub(new_block, t)
# 2. Filter -Bsymbolic* on ppc64le (zig rejects before ld.bfd sees it)
rpath_line = '-Wl,-rpath-link|-Wl,-rpath-link,*|-Wl,--disable-new-dtags) ;;'
if rpath_line in t and 'Bsymbolic) ;;' not in t:
    t = t.replace(
        rpath_line,
        '-Wl,-Bsymbolic-functions|-Wl,-Bsymbolic|-Bsymbolic-functions|-Bsymbolic) ;;\n'
        '        ' + rpath_line
    )
open(p, 'w').write(t)
print('  Wrapper patched successfully')
PATCH_EOF
fi

# Windows: fast-fail test (~5 seconds) BEFORE any slow builds.
# Validates tools, patches, and (on x86_64) the full DLL export + dlltool pipeline.
#
# DLL creation approaches and their limitations:
#   zig cc -shared:     works on x86_64, but hangs ~100s with empty implibs on aarch64
#   zig ld.lld:         routes to ELF driver, rejects MinGW PE flags (-m i386pep)
#
# Strategy: full DLL pipeline test on x86_64 (zig cc -shared handles CRT).
# On aarch64: validate tools + patches only; cmake handles DLL creation with
# zig cc -shared and full CRT context during the real build.
if is_not_unix; then
  echo "=== Fast Windows data-symbol export test ==="
  _stub_dir="${SRC_DIR}/_stub_test"
  mkdir -p "${_stub_dir}"
  _stub_fail=0

  _zig_cc_args=("${ZIG_CC}")
  _zig_cxx_args=("${ZIG_CXX}")
  dbg "ZIG_CC: ${_zig_cc_args[*]}"
  dbg "ZIG_CXX: ${_zig_cxx_args[*]}"

  _zig_bin="${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe"

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
  # The aarch64 build delegates DLL creation to cmake with full CRT context.
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

  # Windows ARM64: cmake compiler link test fails with:
  #   lld-link: unable to automatically import from _fpreset with relocation
  #   type IMAGE_REL_ARM64_BRANCH26 in crt2.obj / libmingw32.lib
  # ARM64 branch instructions (BL) can't be redirected to DLL import thunks
  # the way x86 auto-import works. Skip the link test via STATIC_LIBRARY mode,
  # and inject the _fpreset stub into all linker invocations so shared lib
  # builds (libunwind.dll, libc++.dll, etc.) don't hit the same error.
  if is_not_unix && [[ "${LLVM_TRIPLET}" == aarch64-* ]]; then
    _fpreset_stub="${BUILD_PREFIX//\\//}/Library/lib/zig/libc/mingw/lib-common/_fpreset_arm64.o"
    if [[ ! -f "${_fpreset_stub}" ]]; then
      echo "WARNING: _fpreset_arm64.o stub not found at ${_fpreset_stub}"
      echo "  ARM64 shared library links may fail with auto-import relocation errors"
    fi
    _RUNTIMES_CMAKE+=(
      -DCMAKE_C_COMPILER_WORKS=TRUE
      -DCMAKE_CXX_COMPILER_WORKS=TRUE
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
      -DCMAKE_SHARED_LINKER_FLAGS="${_fpreset_stub}"
      -DCMAKE_EXE_LINKER_FLAGS="${_fpreset_stub}"
    )
  fi

  # macOS: tell cmake the correct arch (prevents -mcpu=core2 on cross-builds)
  if is_osx; then
    _RUNTIMES_CMAKE+=(-DCMAKE_OSX_ARCHITECTURES="${_osx_arch}")
  fi

  # ppc64le: skip CMake compiler link test (same as main LLVM build).
  # The ld wrapper (created above) injects --sysroot + -lpthread/-ldl for shared
  # lib builds. Additionally suppress glibc-version-gated symbols that are NOT
  # available in the glibc 2.17 sysroot but zig's bundled headers enable:
  # - __cxa_thread_atexit_impl: added in glibc 2.18. zig's check_library_exists
  #   tests against zig's bundled libc (newer glibc), so LIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL
  #   comes back ON. Override to OFF so the fallback implementation is compiled.
  # - copy_file_range: added in glibc 2.27 libc wrapper. Guarded by
  #   _LIBCPP_GLIBC_PREREQ(2,27) but zig's bundled libc++ headers may resolve
  #   this as true. Undefine _LIBCPP_FILESYSTEM_USE_COPY_FILE_RANGE so the
  #   sendfile/fstream fallback is used instead.
  if [[ "${LLVM_TRIPLET}" == powerpc64le-* ]]; then
    _RUNTIMES_CMAKE+=(
      -DCMAKE_C_COMPILER_WORKS=TRUE
      -DCMAKE_CXX_COMPILER_WORKS=TRUE
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
      "-DCMAKE_CXX_FLAGS=-fvisibility=default -D__GLIBC_MINOR__=17"
    )
    _RUNTIMES_FLAGS+=(
      -DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF
    )
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

  # === zig _14 libc++ probe: make shared libc++ visible at BUILD_PREFIX ===
  # zig _14's libcxx_shared.zig probes for shared libc++ relative to zig_lib_dir:
  #   <zig_lib_dir>/../../lib/zig-llvm/lib/libc++{.so.1,.1.dylib,.dll.a}
  # zig_lib_dir is $BUILD_PREFIX/lib/zig/ (Linux/macOS) or $BUILD_PREFIX/Library/lib/zig/ (Windows).
  # Phase 1 installs libc++ to $PREFIX/lib/zig-llvm/lib/ — different from BUILD_PREFIX.
  # Symlink so zig _14 finds it during Phase 2 AND when downstream packages build.
  if is_not_unix; then
    _probe_dir="${BUILD_PREFIX}/Library/lib/zig-llvm/lib"
  else
    _probe_dir="${BUILD_PREFIX}/lib/zig-llvm/lib"
  fi
  mkdir -p "${_probe_dir}"
  echo "  Creating zig _14 libc++ probe copies at ${_probe_dir}"
  for _libcxx in "${LLVM_INSTALL}/lib/"libc++*; do
    [[ -f "${_libcxx}" ]] || continue
    _name=$(basename "${_libcxx}")
    # Use cp instead of ln -sf: Windows native zig binary may not follow
    # MSYS2 Unix symlinks when probing for libc++.dll.a
    cp -f "${_libcxx}" "${_probe_dir}/${_name}"
    echo "    ${_name} ($(wc -c < "${_probe_dir}/${_name}") bytes)"
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
  -DLLVM_TOOL_LLVM_AR_BUILD=ON  # ON: llvm-ar creates llvm-dlltool symlink (needed for MinGW import lib generation)
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

  -DCMAKE_C_FLAGS="-fvisibility=default"
  -DCMAKE_CXX_FLAGS="-fvisibility=default"
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
  _rc_path="${_BUILD_PREFIX}/Library/share/zig/wrappers/${ZIG_TARGET_HOST}-zig-rc.bat"
  cat >> "${_cmake_init}" << CMINIT
# RC compiler with forward-slash path — avoids CMake 4.2 backslash escape bug.
set(CMAKE_RC_COMPILER "${_rc_path}" CACHE FILEPATH "RC compiler")
set(CMAKE_RC_COMPILER_WORKS TRUE CACHE BOOL "RC compiler works")
CMINIT
elif [[ -n "${ZIG_RC:-}" ]]; then
  CMAKE_RC_FLAGS=(-DCMAKE_RC_COMPILER="${ZIG_RC}")
fi

ulimit -n 4096 2>/dev/null || true
echo "=== cmake initial-cache file (${_cmake_init}) ==="
sed 's/^/  /' "${_cmake_init}" || true
echo "=== cmake project include file (${_cmake_project_include}) ==="
sed 's/^/  /' "${_cmake_project_include}" || true

cmake "-C${_cmake_init}" \
  -S "${LLVM_SRC}" -B "${LLVM_BUILD}" \
  -DCMAKE_PROJECT_INCLUDE="${_cmake_project_include}" \
  "${CMAKE_CROSS_FLAGS[@]}" \
  "${CMAKE_PLATFORM_FLAGS[@]}" \
  "${CMAKE_RC_FLAGS[@]}" \
  -DHAS_LOGF128=OFF \
  -DLLD_BUILD_TOOLS=OFF \
  "${_CMAKE[@]}" \
  "${_CLANG[@]}" \
  "${_LLVM[@]}" \
  -G Ninja


# === Quick-fail: verify --export-all-symbols in ALL shared library link rules ===
# libLLVM and libclang-cpp each get their own CXX_SHARED_LIBRARY_LINKER rule in
# rules.ninja.  If --export-all-symbols is missing from either, the import lib
# will be 8 KiB instead of 100+ KiB — but we'd only discover that AFTER 2+ hours.
if is_not_unix; then
  { set +x; } 2>/dev/null
  echo "=== Quick-fail: verifying --export-all-symbols in ALL shared library rules ==="
  _export_fail=0
  while IFS= read -r _rule_name; do
    # Extract the command line for this rule (next 8 lines after the rule declaration)
    _rule_cmd=$(grep -A8 "^rule ${_rule_name}$" "${_rules_ninja}" 2>/dev/null | grep 'command =' || true)
    echo "  ${_rule_name}:"
    if echo "${_rule_cmd}" | grep -q 'export-all-symbols'; then
      echo "    OK: --export-all-symbols present"
    else
      echo "    FAIL: --export-all-symbols NOT in command line!"
      echo "    command = ${_rule_cmd}"
      _export_fail=1
    fi
  done < <(grep '^rule CXX_SHARED_LIBRARY_LINKER' "${_rules_ninja}" 2>/dev/null | sed 's/^rule //')
  if [[ ${_export_fail} -ne 0 ]]; then
    echo "  FATAL: --export-all-symbols missing from one or more shared library link rules."
    echo "  libclang-cpp.dll.a will be ~8 KiB instead of 100+ KiB."
    echo "  Aborting to avoid wasting 2+ hours on a build that will fail."
    set -x
    exit 1
  fi
  echo "  All shared library rules have --export-all-symbols"
  set -x
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

  # Add libc++ DLL location to PATH so build-time executables (llvm-min-tblgen etc.)
  # can find libc++.dll at runtime.  With zig _14's libc++ probe, zig links
  # executables against shared libc++ — but the DLL must be discoverable via PATH.
  export PATH="${LLVM_INSTALL}/bin:${LLVM_INSTALL}/lib:${PATH}"
  echo "  Added ${LLVM_INSTALL}/bin and lib to PATH for runtime DLL discovery"

  # Phase 1: Build libLLVM DLL only
  echo "  Phase 1: Building LLVM shared library..."
  cmake --build "${LLVM_BUILD}" --target LLVM -j"${CPU_COUNT}"

  # Phase 1.5: Remove atexit from import lib via strip_atexit_from_implib().
  # The same function is exercised by the fast-fail stub test above, so any bug
  # in the shared logic surfaces in ~5 s (stub) rather than after the 90-min build.
  _implib=$(find "${LLVM_BUILD}" \( -name 'libLLVM*.dll.a' -o -name 'LLVM*.dll.a' \) 2>/dev/null | awk 'NR==1')
  _zig_bin="${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe"

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
      echo "    Expected 100+ KiB — --export-all-symbols not effective for libclang-cpp."
      # Print DLL size for quick diagnosis (large DLL + tiny implib = --out-implib problem)
      _clang_dll_fail=$(find "${LLVM_BUILD}" -name 'libclang-cpp*.dll' -o -name 'clang-cpp*.dll' 2>/dev/null | head -1)
      if [[ -n "${_clang_dll_fail}" ]]; then
        _clang_dll_fail_sz=$(stat -c%s "${_clang_dll_fail}" 2>/dev/null || stat -f%z "${_clang_dll_fail}" 2>/dev/null || echo 0)
        echo "    libclang-cpp.dll size: ${_clang_dll_fail_sz} bytes ($(( _clang_dll_fail_sz / 1048576 )) MiB)"
      else
        echo "    libclang-cpp.dll: NOT FOUND"
      fi
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
      # Show DLL size for diagnosis
      _clang_dll_sym=$(find "${LLVM_BUILD}" -name 'libclang-cpp*.dll' -o -name 'clang-cpp*.dll' 2>/dev/null | head -1)
      if [[ -n "${_clang_dll_sym}" ]]; then
        _clang_dll_sym_sz=$(stat -c%s "${_clang_dll_sym}" 2>/dev/null || stat -f%z "${_clang_dll_sym}" 2>/dev/null || echo 0)
        echo "  libclang-cpp.dll size: ${_clang_dll_sym_sz} bytes ($(( _clang_dll_sym_sz / 1048576 )) MiB)"
        _clang_dll_sym_nsyms=$( ("${_zig_bin}" nm "${_clang_dll_sym}" 2>/dev/null || nm "${_clang_dll_sym}" 2>/dev/null) \
          | grep -c ' [TDBCV] ' || echo 0)
        echo "  libclang-cpp.dll exported symbols (nm): ${_clang_dll_sym_nsyms}"
      fi
      echo "  libclang-cpp.dll.a size: ${_clang_implib_size} bytes, symbols: ${_clang_nsyms}"
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
  # Same rpath issue as Linux: llvm-min-tblgen needs to find libunwind from LLVM_INSTALL.
  export DYLD_LIBRARY_PATH="${LLVM_INSTALL}/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  echo "  Phase 1: Building LLVM shared library..."
  cmake --build "${LLVM_BUILD}" --target LLVM -j"${CPU_COUNT}"

  # Quick-fail: verify key symbols are exported from libLLVM.dylib.
  # If zig cc's visibility handling is broken, we find out here (~50% through build)
  # instead of at the end when libclang-cpp.dylib tries to link.
  _llvm_dylib=$(find "${LLVM_BUILD}" -name 'libLLVM*.dylib' -not -name '*.dSYM' 2>/dev/null | awk 'NR==1')
  if [[ -n "${_llvm_dylib}" ]]; then
    # Check for a known externally-consumed symbol (LLVMInitialize* functions).
    # IMPORTANT: use "grep ... >/dev/null" NOT "grep -q" here.
    # grep -q exits on first match, closing the pipe while nm is still writing
    # 55K+ symbols. Under set -o pipefail, nm's SIGPIPE (exit 141) makes the
    # pipeline fail even though the symbol was found.
    _test_sym="LLVMInitializeAArch64AsmParser"
    if nm -g "${_llvm_dylib}" 2>/dev/null | grep "${_test_sym}" >/dev/null 2>&1; then
      echo "  OK: ${_test_sym} exported from libLLVM.dylib"
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
  # llvm-min-tblgen links against libunwind.so.1 (from zig-llvm's shared runtimes).
  # LLVM's llvm_setup_rpath() sets BUILD_WITH_INSTALL_RPATH=ON which bypasses
  # CMAKE_BUILD_RPATH. The binary's $ORIGIN/../lib resolves to LLVM_BUILD/lib/
  # but libunwind.so.1 is in LLVM_INSTALL/lib/. LD_LIBRARY_PATH bridges the gap.
  export LD_LIBRARY_PATH="${LLVM_INSTALL}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
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

