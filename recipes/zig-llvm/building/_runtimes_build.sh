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

  if is_linux; then
    # zig's clang auto-embeds .deplibs sections (dl, pthread) in shared-lib objects.
    # lld processes .deplibs separately from explicit -l flags and fails when the
    # library path isn't directly resolvable. zig's cc driver also does not forward
    # -Wl,--ignore-dependent-libraries to lld, so fix this at compile time instead:
    # -fno-autolink suppresses .deplibs generation entirely. The explicit -ldl/-lpthread
    # on the cmake command line still cover the same dependencies.
    # Note: this overrides is_unix CMAKE_C/CXX_FLAGS — -fvisibility=default is preserved.
    _RUNTIMES_CMAKE+=(
      "-DCMAKE_C_FLAGS=-fvisibility=default -fno-autolink"
      "-DCMAKE_CXX_FLAGS=-fvisibility=default -fno-autolink"
    )
  fi

  if is_not_unix; then
    # MinGW: Win32 threading API (no pthreads on Windows)
    _RUNTIMES_FLAGS+=(
      -DLIBCXX_HAS_WIN32_THREAD_API=ON
      -DLIBCXXABI_HAS_WIN32_THREAD_API=ON
      -DLIBCXX_HAS_PTHREAD_API=OFF
      -DLIBCXXABI_HAS_PTHREAD_API=OFF
      # dl and pthread are not standalone libraries on Windows (dl=kernel32,
      # pthread=Win32 API). With CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
      # cmake's check_library_exists() compiles without linking, so it falsely
      # reports these libraries as present and adds -ldl/-lpthread to the link.
      # Pre-set the check results to NO to suppress the erroneous -l flags.
      -DLIBUNWIND_HAS_DL_LIB=NO
      -DLIBUNWIND_HAS_PTHREAD_LIB=NO
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
    # If zig-gcc package didn't ship the stub, build it inline as a fallback.
    # Mirrors recipes/zig-gcc/building/_win_arm64_stubs.sh:create_fpreset_stub.
    # ARM64 has no x87 FPU; _fpreset is a no-op.
    if [[ ! -f "${_fpreset_stub}" ]]; then
      echo "  _fpreset_arm64.o stub missing from zig-gcc package; building inline fallback"
      _fpreset_stub="${LLVM_BUILD//\\//}/_fpreset_arm64.o"
      _fpreset_src="${LLVM_BUILD//\\//}/_fpreset_arm64.c"
      mkdir -p "${LLVM_BUILD}"
      cat > "${_fpreset_src}" << 'EOF'
// Inline fallback for _fpreset_arm64.o (mirror of zig-gcc _win_arm64_stubs.sh).
// ARM64 has no x87 FPU; _fpreset is a no-op. Resolves IMAGE_REL_ARM64_BRANCH26
// auto-import error from CRT objects (crt2.obj, libmingw32.lib).
void _fpreset(void) {}
EOF
      "${BUILD_PREFIX//\\//}/Library/bin/x86_64-w64-mingw32-zig.exe" cc \
        -target aarch64-windows-gnu -c "${_fpreset_src}" -o "${_fpreset_stub}" \
        || { echo "ERROR: failed to compile inline _fpreset_arm64.o stub"; exit 1; }
      rm -f "${_fpreset_src}"
      [[ -f "${_fpreset_stub}" ]] || { echo "ERROR: _fpreset stub still missing after compile"; exit 1; }
      echo "    inline stub: ${_fpreset_stub} ($(wc -c < "${_fpreset_stub}") bytes)"
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
      "-DCMAKE_CXX_FLAGS=-fvisibility=default -fno-autolink -D__GLIBC_MINOR__=17"
    )
    _RUNTIMES_FLAGS+=(
      -DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF
    )
  fi

  # Cross-compilation: tell cmake the compiler's target triple explicitly.
  # Without this, cmake's ABI detection probes the wrapper by filename and may
  # infer the build-host triple (x86_64) instead of the target triple (e.g.
  # aarch64-unknown-linux-gnu), caching x86_64 for all C/C++ compile+link steps.
  # ASM escapes the problem because it is compiled differently, so C/C++ objects
  # end up as elf_x86_64 while ASM objects are aarch64 — causing ld.lld errors.
  # Zig parses compiler target queries in 3-component format (<arch>-<os>-<abi>);
  # clang's 4-component LLVM triple (e.g. aarch64-unknown-linux-gnu) makes zig
  # treat "unknown" as the OS and fail with UnknownOperatingSystem.
  # Strip the "-unknown-" middle component to get the zig-compatible triple.
  ZIG_LLVM_TRIPLET="${LLVM_TRIPLET/-unknown-/-}"
  ZIG_LLVM_TRIPLET="${ZIG_LLVM_TRIPLET/-w64-/-}"

  if is_cross; then
    _RUNTIMES_CMAKE+=(
      -DCMAKE_C_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
      -DCMAKE_CXX_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
      -DCMAKE_ASM_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
      # Skip cmake's ABI detection — it runs in EXECUTABLE mode and fails for cross-builds,
      # leaving cmake architecturally blind and poisoning all check_cxx_compiler_flag probes.
      # Without this, libunwind's CXX_SUPPORTS_FUNWIND_TABLES_FLAG probe fails and the
      # configure aborts at libunwind/src/CMakeLists.txt:107.
      -DCMAKE_C_ABI_COMPILED=TRUE
      -DCMAKE_CXX_ABI_COMPILED=TRUE
      # Force the specific libunwind feature flags that have a hard-fail in CMakeLists.txt.
      # The compiler (zig-cc / clang 20.1.8) does support all of these — the cmake probes
      # falsely return Failed due to the ABI-detection poisoning above. These overrides
      # make the result resilient even if some probe still misfires.
      -DCXX_SUPPORTS_FUNWIND_TABLES_FLAG=TRUE
      -DCXX_SUPPORTS_FNO_EXCEPTIONS_FLAG=TRUE
      -DCXX_SUPPORTS_FNO_RTTI_FLAG=TRUE
      -DCXX_SUPPORTS_NOSTDLIBXX_FLAG=TRUE
      -DCXX_SUPPORTS_UNWINDLIB_EQ_NONE_FLAG=TRUE
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

  # Disk recovery: Phase 1 runtimes build dir (~1-2GB) is no longer needed
  # after install. Removing it before Phase 2 prevents ENOSPC on linux-64
  # (cross-target LLVM peaks at 15-20GB during Phase 2 compile).
  echo "=== Removing Phase 1 runtimes build dir (disk recovery) ==="
  rm -rf "${SRC_DIR}/conda-runtimes-build"

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
  if is_cross; then
    # Cross-compile: ${LLVM_INSTALL}/lib/libc++* is TARGET-arch (e.g. aarch64);
    # copying it over ${_probe_dir} would overwrite the BUILD-arch libc++ that
    # the solver-installed zig-libcxx (recipe.yaml requirements.build cross block)
    # placed there. Host tools (e.g. llvm-tblgen) need build-arch libc++ to load.
    echo "  Cross-compile: skipping libc++ copy to ${_probe_dir} (build-arch libc++ from zig-libcxx dep is already there)"
  else
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

fi

