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
    # Force zig-cc to select shared libc++ instead of zig-cache static .a.
    # libcxx_shared.findSharedLibCxxString skips its logic when target_arch !=
    # build_arch UNLESS this env var is set (cross-arch ppc64le from x86_64).
    export ZIG_SHARED_LIBCXX_DIR="${PREFIX}/lib/zig-llvm/lib"

    # Force CMake to skip compiler linking tests. zig's self-hosted linker
    # injects -m elf64lppc then chokes on it, and CMAKE_TRY_COMPILE_TARGET_TYPE
    # doesn't prevent CMakeTestCCompiler from linking. Compilation is verified
    # by the pre-flight test above; linking isn't needed (libraries only).
    CMAKE_CROSS_FLAGS+=(
      -DCMAKE_C_COMPILER_WORKS=TRUE
      -DCMAKE_CXX_COMPILER_WORKS=TRUE
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    )
    # ppc64le GCC redirect doesn't propagate sysroot/-L paths from the wrapper.
    # libLLVM.so has DT_NEEDED for libz.so.1, libzstd.so.1, libxml2.so.16.
    # Consumers (llvm-ar etc.) need -rpath-link at link time (not just runtime rpath).
    # Cover both flat ($PREFIX/lib) and zig-* isolated layouts; non-existent dirs are no-ops.
    _rpath_link="-Wl,-rpath-link,${PREFIX}/lib -Wl,-rpath-link,${PREFIX}/lib/zig-zlib/lib -Wl,-rpath-link,${PREFIX}/lib/zig-zstd/lib -Wl,-rpath-link,${PREFIX}/lib/zig-libxml2/lib -Wl,-rpath-link,${BUILD_PREFIX}/powerpc64le-conda-linux-gnu/sysroot/usr/lib64 -Wl,-rpath-link,${BUILD_PREFIX}/powerpc64le-conda-linux-gnu/sysroot/lib64"
    CMAKE_CROSS_FLAGS+=(
      -DCMAKE_EXE_LINKER_FLAGS_INIT="${_rpath_link}"
      # Allow zig-cc to inject bundled libc++/libc++abi into the link command;
      # the ld.bfd wrapper below (lines 114-143) intercepts and swaps these static
      # .a files for the recipe's shared libc++.so, preventing LOCAL_DEFINED merges.
      -DCMAKE_SHARED_LINKER_FLAGS_INIT="${_rpath_link}"
    )
    unset _rpath_link
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
# Sysroot library search path + rpath-link is needed for EVERY link, not just
# -shared. Executables that link libLLVM.so as a DSO trigger rpath-link
# resolution of libLLVM's DT_NEEDED (libstdc++.so.6), which lives in the
# sysroot. Without this, bin/clang-fuzzer-dictionary etc. fail with
# 'libstdc++.so.6 not found' + undefined references to @GLIBCXX_3.4 symbols.
_args+=(-L"${_ppc_sysroot_early}/usr/lib64" -L"${_ppc_sysroot_early}/usr/lib")
_args+=(-L"${PREFIX}/lib/zig-llvm/lib")
_args+=(-L"${PREFIX}/lib")                          # libz/libzstd/libxml2 from $PREFIX/lib
_args+=(-rpath-link "${PREFIX}/lib")                # transitive DT_NEEDED resolution for libLLVM.so
_args+=(-rpath-link "${_ppc_sysroot_early}/usr/lib64" -rpath-link "${_ppc_sysroot_early}/usr/lib")
_is_shared=0
for _a in "\$@"; do
    [[ "\$_a" == "-shared" ]]    && _is_shared=1
    _args+=("\$_a")
done
if (( _is_shared )); then
    _args+=(-lpthread -ldl -lrt -lm)
fi
# NOTE: Do NOT inject -lstdc++ here. libc++abi.a is already in the link
# command (from zig-cc's libc++/libc++abi/libunwind bundle), which provides
# the std::* typeinfo symbols (runtime_error, logic_error, length_error,
# etc.) statically. Injecting -lstdc++ would cause dynamic libstdc++.so.6
# to win over libc++abi.a, baking DT_NEEDED libstdc++.so.6 into the output
# DSO and breaking downstream links (clang-fuzzer-dictionary @GLIBCXX_3.4
# undefined refs).
# Swap zig's bundled static libc++/libc++abi/libunwind (which reference symbols
# only in libstdc++.so on ppc64le, re-introducing the libstdc++ dependency) for
# the recipe's zig-libcxx shared libs (built libstdc++-free). Replacement path
# from ZIG_LIBCXX_DIR (default \${PREFIX}/lib/zig-llvm/lib). Falls back to
# original path if replacement .so is missing.
_libcxx_dir="\${ZIG_LIBCXX_DIR:-${PREFIX}/lib/zig-llvm/lib}"
_libcxx_so="\${_libcxx_dir}/libc++.so"
_libunwind_so="\${_libcxx_dir}/libunwind.so"
_swap_args=()
for _a in "\${_args[@]}"; do
    case "\${_a}" in
        */zig-cache/*/libc++.a|*/zig-cache/*/libc++abi.a)
            if [[ -f "\${_libcxx_so}" ]]; then
                _swap_args+=("\${_libcxx_so}")
            else
                _swap_args+=("\${_a}")
            fi
            ;;
        */zig-cache/*/libunwind.a)
            if [[ -f "\${_libunwind_so}" ]]; then
                _swap_args+=("\${_libunwind_so}")
            else
                _swap_args+=("\${_a}")
            fi
            ;;
        *)
            _swap_args+=("\${_a}")
            ;;
    esac
done
_args=("\${_swap_args[@]}")
exec "${_ppc_ld_bin}.real" "\${_args[@]}"
PPCLD
        chmod +x "${_ppc_ld_bin}"
        echo "  ppc64le: ld.bfd wrapped at ${_ppc_ld_bin} -> injects --sysroot + -lpthread -ldl for shared"
      fi
    fi
  fi


  # Tablegen tools run on the BUILD host, not target.
  # Provided by zig-llvm itself (build dep for cross-compilation).
  LLVM_TBLGEN=$(find "${BUILD_PREFIX}" \
      \( -name llvm-tblgen -o -name llvm-tblgen.exe \) \
      ! -name 'llvm-min-tblgen' ! -name 'llvm-min-tblgen.exe' \
      -type f 2>/dev/null | head -1)
  echo "  LLVM_TBLGEN resolved to: ${LLVM_TBLGEN:-<not found>}"
  CLANG_TBLGEN=$(find "${BUILD_PREFIX}" \
      \( -name clang-tblgen -o -name clang-tblgen.exe \) \
      -type f 2>/dev/null | head -1)
  # Append tblgen paths if found (use += to preserve existing flags).
  # LLVM 20 uses CLANG_TABLEGEN_EXE (not CLANG_TABLEGEN).
  if [[ -n "${LLVM_TBLGEN}" ]]; then
    # LLVM 20+ TableGen variable resolution:
    #   LLVM_TABLEGEN: legacy cache variable (still honored).
    #   LLVM_TABLEGEN_EXE: internal var consulted by tablegen() macro on LLVM 20+.
    #     Without this, the macro may fall back to MIN tblgen for some generators
    #     (e.g. -gen-asm-matcher on WebAssembly), producing "Unknown command line argument" errors.
    #   LLVM_MIN_TABLEGEN_EXE: bootstrap-only minimal tblgen. Pointed at the FULL
    #     llvm-tblgen.exe since it is a strict superset (handles every generator
    #     min-tblgen handles, plus the rest). Safe and avoids the asm-matcher mismatch.
    CMAKE_CROSS_FLAGS+=(
      -DLLVM_TABLEGEN="${LLVM_TBLGEN}"
      -DLLVM_TABLEGEN_EXE="${LLVM_TBLGEN}"
      -DLLVM_MIN_TABLEGEN_EXE="${LLVM_TBLGEN}"
    )
  fi
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
    _native_cc="${BUILD_PREFIX}/bin/${CONDA_BUILD_ZIG}-cc"
    _native_cxx="${BUILD_PREFIX}/bin/${CONDA_BUILD_ZIG}-cxx"
    _native_asm="${BUILD_PREFIX}/bin/${CONDA_BUILD_ZIG}-asm"
    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${_native_cc};-DCMAKE_CXX_COMPILER=${_native_cxx};-DCMAKE_ASM_COMPILER=${_native_asm};-DCMAKE_PREFIX_PATH=${BUILD_PREFIX};-DCMAKE_FIND_ROOT_PATH=${BUILD_PREFIX};-DLLVM_ENABLE_ZSTD=OFF"
    )
  elif is_not_unix; then
    _host_cc_exe="${BUILD_PREFIX}/Library/bin/${CONDA_BUILD_ZIG}-cc.exe"
    _host_cxx_exe="${BUILD_PREFIX}/Library/bin/${CONDA_BUILD_ZIG}-cxx.exe"
    _host_ar_bat="${BUILD_PREFIX}/Library/bin/${CONDA_BUILD_ZIG}-ar.exe"
    _host_ranlib_bat="${BUILD_PREFIX}/Library/bin/${CONDA_BUILD_ZIG}-ranlib.exe"

    # Write a CMake project-include file for the NATIVE sub-project.
    # This file patches the link rule templates after platform detection.
    #
    # Root cause: CMake's Windows-GNU.cmake sets CMAKE_GNULD_IMAGE_VERSION to
    #   "-Wl,--major-image-version,<TARGET_VERSION_MAJOR>,--minor-image-version,<TARGET_VERSION_MINOR>"
    # For executables without an explicit VERSION property, <TARGET_VERSION_MAJOR>
    # and <TARGET_VERSION_MINOR> evaluate to 0 (the CMake default). Zig cc converts
    # --major-image-version,0,--minor-image-version,0 to lld-link /version:0.0,
    # which zig's lld-link rejects with InvalidVersion.
    #
    # CMAKE_EXE_LINKER_FLAGS_INIT (tried in rounds 3-8) is appended to the link
    # command, but CMake's link rule template ALSO appends ${CMAKE_GNULD_IMAGE_VERSION}
    # AFTER <LINK_FLAGS>. Zig's lld-link uses the last --major-image-version, so the
    # 0,0 from the template wins over our 1,0 from LINKER_FLAGS_INIT.
    #
    # CMAKE_PROJECT_INCLUDE runs at the END of project() (after platform module sets
    # the link rule vars). We use string(REPLACE) to patch the 0-version generator
    # expressions with hardcoded 1,0 before CMake generates build.ninja.
    #
    # Use _SRC_DIR (forward-slash path from build.bat) to avoid CMake 4.2
    # backslash escape bug; fall back to bash-normalised SRC_DIR.
    _fwd_src_dir="${_SRC_DIR:-${SRC_DIR//\\//}}"
    _native_project_include_fwd="${_fwd_src_dir}/_native_cmake_project_include.cmake"
    # Write with literal SRC_DIR (backslashes are fine for the 'cat' call itself).
    cat > "${SRC_DIR}/_native_cmake_project_include.cmake" << 'NATIVE_CMINIT'
# Fix: zig lld-link rejects /version:0.0 for Windows executables built in the
# NATIVE cross-build sub-project (llvm-min-tblgen.exe etc.).
#
# CMake's Windows-GNU.cmake defines:
#   CMAKE_GNULD_IMAGE_VERSION =
#     "-Wl,--major-image-version,<TARGET_VERSION_MAJOR>,--minor-image-version,<TARGET_VERSION_MINOR>"
# and bakes it into CMAKE_${lang}_LINK_EXECUTABLE via ${CMAKE_GNULD_IMAGE_VERSION}.
# Executables without explicit VERSION property get <TARGET_VERSION_MAJOR>=0,
# <TARGET_VERSION_MINOR>=0. Zig translates --major-image-version,0,... to
# lld-link /version:0.0, which zig lld-link rejects as InvalidVersion.
#
# This file runs via CMAKE_PROJECT_INCLUDE (last step of project(), after all
# platform modules have set the link rule variables). string(REPLACE) patches the
# zero-version generator expressions with hardcoded 1,0 before CMake generates
# build.ninja. Handles both Windows-GNU format (--major-image-version) and
# Windows-Clang format (/version:) for robustness.
message(STATUS ">>> NATIVE CMAKE_PROJECT_INCLUDE: patching link rules for zig lld-link /version:0.0 fix")
if(WIN32)
  foreach(_native_lang IN ITEMS C CXX ASM)
    foreach(_native_rule IN ITEMS
        CMAKE_${_native_lang}_LINK_EXECUTABLE
        CMAKE_${_native_lang}_CREATE_SHARED_LIBRARY
        CMAKE_${_native_lang}_CREATE_SHARED_MODULE)
      if(DEFINED ${_native_rule})
        string(REPLACE
          "--major-image-version,<TARGET_VERSION_MAJOR>,--minor-image-version,<TARGET_VERSION_MINOR>"
          "--major-image-version,1,--minor-image-version,0"
          ${_native_rule} "${${_native_rule}}")
        string(REPLACE
          "/version:<TARGET_VERSION_MAJOR>.<TARGET_VERSION_MINOR>"
          "/version:1.0"
          ${_native_rule} "${${_native_rule}}")
      endif()
    endforeach()
  endforeach()
  message(STATUS ">>> NATIVE CMAKE_PROJECT_INCLUDE: link rules patched (version 1.0)")
endif()
NATIVE_CMINIT
    echo "  NATIVE cmake project include: ${_native_project_include_fwd}"

    # CMake compiler probe builds an exe by default, which on Windows injects
    # -Xlinker /version:0.0 — zig lld-link rejects bare 0.0 as InvalidVersion.
    # Build a static lib for the probe instead (no link, no /version: flag).
    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${_host_cc_exe};-DCMAKE_CXX_COMPILER=${_host_cxx_exe};-DCMAKE_AR=${_host_ar_bat};-DCMAKE_RANLIB=${_host_ranlib_bat};-DLLVM_ENABLE_ZSTD=OFF;-DCMAKE_OBJECT_PATH_MAX=1024;-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY;-DCMAKE_EXE_LINKER_FLAGS_INIT=-Wl,--major-image-version,1,--minor-image-version,0;-DCMAKE_SHARED_LINKER_FLAGS_INIT=-Wl,--major-image-version,1,--minor-image-version,0;-DCMAKE_PROJECT_INCLUDE=${_native_project_include_fwd}"
    )
    echo "  HOST_CC: ${_host_cc_exe}"
    echo "  HOST_CXX: ${_host_cxx_exe}"
    unset _fwd_src_dir _native_project_include_fwd
  fi

  # Zig parses compiler target queries in 3-component format (<arch>-<os>-<abi>);
  # clang's 4-component LLVM triple (e.g. aarch64-unknown-linux-gnu) makes zig
  # treat "unknown" as the OS and fail with UnknownOperatingSystem.
  # Strip the "-unknown-" middle component to get the zig-compatible triple.
  # NOTE: ZIG_LLVM_TRIPLET is also used in the runtimes is_cross block below.
  ZIG_LLVM_TRIPLET="${LLVM_TRIPLET/-unknown-/-}"
  ZIG_LLVM_TRIPLET="${ZIG_LLVM_TRIPLET/-w64-/-}"

  # Cross-compilation: tell cmake the main LLVM configure the compiler's target
  # triple explicitly. Without this, cmake's ABI detection probes the wrapper by
  # filename and may infer the build-host triple (x86_64) instead of the target
  # triple (e.g. aarch64), causing it to link test binaries as x86_64 against
  # the freshly-installed target-arch libc++ — producing an elf incompatibility
  # error ("libc++.so.1 is incompatible with elf_x86_64").
  if is_cross; then
    CMAKE_CROSS_FLAGS+=(
      -DCMAKE_C_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
      -DCMAKE_CXX_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
      -DCMAKE_ASM_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
      -DCMAKE_C_ABI_COMPILED=TRUE
      -DCMAKE_CXX_ABI_COMPILED=TRUE
    )
  fi

  echo "  CMAKE_SYSTEM_NAME: ${CMAKE_SYSTEM_NAME}"
  echo "  LLVM_TABLEGEN: ${LLVM_TBLGEN}"
  echo "  CLANG_TABLEGEN: ${CLANG_TBLGEN}"
  echo "  LLVM_NATIVE_TOOL_DIR: ${_tblgen_dir:-<not set>}"
fi

