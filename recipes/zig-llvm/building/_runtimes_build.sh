mkdir -p "${LLVM_BUILD}"

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

# libunwind provides _Unwind_* / _GCC_specific_handler symbols needed by
# libc++abi's exception handling. On Unix: DWARF unwinding (shared lib).
# On Windows (MinGW): SEH-based unwinding via libunwind's SEH adapter, built
# STATIC-only so it embeds into libc++abi.dll (see Windows overrides below).
# Without libunwind, the libc++abi.dll link fails with undefined _Unwind_Resume,
# _Unwind_RaiseException, _GCC_specific_handler, etc.
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

# Windows (all arches): skip CMake C/CXX compiler ABI probe — zig's bundled
# LLD/COFF emits /MANIFEST:EMBED which CMake's link-test doesn't expect.
# Use STATIC_LIBRARY mode so the probe compiles only (no link step).
if is_not_unix && [[ "${LLVM_TRIPLET}" == *-windows* ]]; then
  _RUNTIMES_CMAKE+=(
    -DCMAKE_C_COMPILER_WORKS=TRUE
    -DCMAKE_CXX_COMPILER_WORKS=TRUE
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
  )

  # Windows COFF: build libunwind STATIC-ONLY and embed it (and libc++abi) into libc++.dll.
  #
  # The unwind.lib collision (`ninja: error: multiple rules generate lib/unwind.lib`)
  # historically happened when both `unwind` (shared, import lib → unwind.lib) and
  # `unwind_static` (static → unwind.lib) targets were enabled — both emit the same
  # filename on COFF. Unix is unaffected because .a vs .so extensions differ.
  #
  # Solution: build only the STATIC libunwind on Windows (LIBUNWIND_ENABLE_SHARED=OFF,
  # LIBUNWIND_ENABLE_STATIC=ON — overriding the Unix defaults set earlier), and embed
  # it into libcxxabi (LIBCXXABI_STATICALLY_LINK_UNWINDER_IN_SHARED_LIBRARY=ON). The
  # default LIBCXX_STATICALLY_LINK_ABI_IN_SHARED_LIBRARY=ON then folds libcxxabi
  # (with its embedded unwind) into libc++.dll — the standard Unix-like layout.
  #
  # Why ABI-in-shared can stay ON on Windows now: the original reason for the OFF
  # override (LIBUNWIND_ENABLE_SHARED=ON triggering the unwind.lib name collision)
  # is gone now that the shared libunwind variant is disabled. With only one unwind
  # target, no rule collision occurs. Without ABI-in-shared, libc++abi.dll builds
  # as a separate DLL and fails to link against std::__1::__libcpp_mutex_* /
  # __libcpp_condvar_* threading primitives that live in libc++ — a circular
  # dependency that the merged layout avoids.
  _RUNTIMES_FLAGS+=(
    -DLIBUNWIND_ENABLE_SHARED=OFF
    -DLIBUNWIND_ENABLE_STATIC=ON
    -DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_SHARED_LIBRARY=ON
  )

  # Windows ARM64 only: cmake compiler link test additionally fails with:
  #   lld-link: unable to automatically import from _fpreset with relocation
  #   type IMAGE_REL_ARM64_BRANCH26 in crt2.obj / libmingw32.lib
  # ARM64 branch instructions (BL) can't be redirected to DLL import thunks
  # the way x86 auto-import works. Inject the _fpreset stub into all linker
  # invocations so shared lib builds (libunwind.dll, libc++.dll, etc.) don't
  # hit the same error.
  if [[ "${LLVM_TRIPLET}" == aarch64-* ]]; then
    _fpreset_stub="${BUILD_PREFIX}/Library/lib/zig/libc/mingw/lib-common/_fpreset_arm64.o"
    # If zig-gcc package didn't ship the stub, build it inline as a fallback.
    # Mirrors recipes/zig-gcc/building/_win_arm64_stubs.sh:create_fpreset_stub.
    # ARM64 has no x87 FPU; _fpreset is a no-op.
    if [[ ! -f "${_fpreset_stub}" ]]; then
      echo "  _fpreset_arm64.o stub missing from zig-gcc package; building inline fallback"
      _fpreset_stub="${LLVM_BUILD}/_fpreset_arm64.o"
      _fpreset_src="${LLVM_BUILD}/_fpreset_arm64.c"
      mkdir -p "${LLVM_BUILD}"
      cat > "${_fpreset_src}" << 'EOF'
// Inline fallback for _fpreset_arm64.o (mirror of zig-gcc _win_arm64_stubs.sh).
// ARM64 has no x87 FPU; _fpreset is a no-op. Resolves IMAGE_REL_ARM64_BRANCH26
// auto-import error from CRT objects (crt2.obj, libmingw32.lib).
void _fpreset(void) {}
EOF
      "${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe" cc \
        -target aarch64-windows-gnu -c "${_fpreset_src}" -o "${_fpreset_stub}" \
        || { echo "ERROR: failed to compile inline _fpreset_arm64.o stub"; exit 1; }
      rm -f "${_fpreset_src}"
      [[ -f "${_fpreset_stub}" ]] || { echo "ERROR: _fpreset stub still missing after compile"; exit 1; }
      echo "    inline stub: ${_fpreset_stub} ($(wc -c < "${_fpreset_stub}") bytes)"
    fi
    _RUNTIMES_CMAKE+=(
      -DCMAKE_SHARED_LINKER_FLAGS="${_fpreset_stub}"
      -DCMAKE_EXE_LINKER_FLAGS="${_fpreset_stub}"
    )
  fi
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
# ZIG_LLVM_TRIPLET (3-component zig triple; see _cross_compile.sh:291-296 for
# the "-unknown-" stripping rationale) is recomputed here — independently of
# _cross_compile.sh, whose own copy of this line only runs inside its
# CONDA_BUILD_CROSS_COMPILATION guard — because this file's `is_cross` block
# below needs the value regardless of how _cross_compile.sh's guard evaluated.
ZIG_LLVM_TRIPLET="$(zig_triplet_from_llvm "${LLVM_TRIPLET}")"

if is_cross; then
  _RUNTIMES_CMAKE+=(
    -DCMAKE_C_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
    -DCMAKE_CXX_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
    -DCMAKE_ASM_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
    "-DCMAKE_ASM_FLAGS=--target=${ZIG_LLVM_TRIPLET}"
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

# zig wrapper needs build-arch libc++.so.1 on the loader path for the compiler check.
if is_linux; then
  export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib/zig-llvm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# Configure and build LLVM runtimes.
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

# Verify build-arch libc++ is present at the probe path before Phase 2 LLVM build.
# zig's libcxx_shared.zig probes ${_probe_dir}/libc++.so.1 (or equivalent on other
# platforms); if absent, zig falls back to its bundled static libc++.a from zig-cache,
# causing static merge of libc++ into every .so we build (failing the post-install
# LOCAL_DEFINED check).
# Platform-aware probe filename (matches what zig's libcxx_shared.zig actually probes for):
# Linux → libc++.so.1, macOS → libc++.1.dylib, Windows → libc++.dll.a
if is_not_unix; then
  _probe_file="${_probe_dir}/libc++.dll.a"
elif is_osx; then
  _probe_file="${_probe_dir}/libc++.1.dylib"
else
  _probe_file="${_probe_dir}/libc++.so.1"
fi
if [[ ! -f "${_probe_file}" ]]; then
  echo "FATAL: ${_probe_file} is missing."
  echo "       zig will fall back to bundled static libc++.a, causing static merge"
  echo "       into every shared library built (post-install LOCAL_DEFINED check will fail)."
  echo "       Verify zig-libcxx is in the build environment and installs to lib/zig-llvm/lib/."
  exit 1
fi
echo "=== libc++ probe path verified: ${_probe_file} present ==="

