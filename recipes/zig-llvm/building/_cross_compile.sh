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
    # ppc64le GCC redirect doesn't propagate sysroot/-L paths from the wrapper.
    # libLLVM.so has DT_NEEDED for libz.so.1, libzstd.so.1, libxml2.so.16.
    # Consumers (llvm-ar etc.) need -rpath-link at link time (not just runtime rpath).
    # Cover both flat ($PREFIX/lib) and zig-* isolated layouts; non-existent dirs are no-ops.
    _rpath_link="-Wl,-rpath-link,${PREFIX}/lib -Wl,-rpath-link,${PREFIX}/lib/zig-zlib/lib -Wl,-rpath-link,${PREFIX}/lib/zig-zstd/lib -Wl,-rpath-link,${PREFIX}/lib/zig-libxml2/lib"
    CMAKE_CROSS_FLAGS+=(
      -DCMAKE_EXE_LINKER_FLAGS_INIT="${_rpath_link}"
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
_is_shared=0
_has_libcxx=0
for _a in "\$@"; do
    [[ "\$_a" == "-shared" ]]    && _is_shared=1
    [[ "\$_a" == */libc++.a ]]   && _has_libcxx=1
    _args+=("\$_a")
done
if (( _is_shared )); then
    _args+=(-L"${_ppc_sysroot_early}/usr/lib64" -L"${_ppc_sysroot_early}/usr/lib" -lpthread -ldl -lrt -lm)
fi
# Whenever zig's libc++.a is in the link (executable OR shared), it references
# typeinfo for std::length_error / std::runtime_error / std::logic_error which
# live in libstdc++.so on ppc64le Linux. Inject -lstdc++ from the sysroot.
if (( _has_libcxx )); then
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
    _native_cc="${BUILD_PREFIX}/share/zig/wrappers/${ZIG_TARGET_BUILD}-zig-cc"
    _native_cxx="${BUILD_PREFIX}/share/zig/wrappers/${ZIG_TARGET_BUILD}-zig-cxx"
    _native_asm="${BUILD_PREFIX}/share/zig/wrappers/${ZIG_TARGET_BUILD}-zig-asm"
    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${_native_cc};-DCMAKE_CXX_COMPILER=${_native_cxx};-DCMAKE_ASM_COMPILER=${_native_asm};-DCMAKE_PREFIX_PATH=${BUILD_PREFIX};-DCMAKE_FIND_ROOT_PATH=${BUILD_PREFIX};-DLLVM_ENABLE_ZSTD=OFF"
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

