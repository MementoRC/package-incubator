#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

source "${RECIPE_DIR}/building/_bash_check.sh"

# Local-only debug overrides — file is gitignored; create from recipe/local-scripts/debug-env.sh.example
if [[ -f "${RECIPE_DIR}/local-scripts/debug-env.sh" ]]; then
    source "${RECIPE_DIR}/local-scripts/debug-env.sh"
fi

build_platform="${build_platform:-${target_platform}}"

# --- Functions ---

source "${RECIPE_DIR}/building/_common.sh"
source "${RECIPE_DIR}/building/_build.sh"  # configure_cmake_zigcpp, build_zig_with_zig

# --- Early exits ---

[[ -z "${CONDA_TRIPLET:-}" ]] && { echo "CONDA_TRIPLET must be specified in recipe.yaml env"; exit 1; }
[[ -z "${CONDA_ZIG_BUILD:-}" ]] && { echo "CONDA_ZIG_BUILD undefined, use zig_<arch> instead of _impl"; exit 1; }
[[ -z "${ZIG_TRIPLET:-}" ]] && { echo "ZIG_TRIPLET must be specified in recipe.yaml env"; exit 1; }

# zig 0.15+ requires macOS OS version as major.minor (e.g. "11.0" not bare "11").
# conda-forge c_stdlib_version may supply a bare major integer.
if is_osx; then
  _zig_os_ver="${ZIG_TRIPLET#*-macos.}"   # "11-none" or "10.13-none"
  _zig_os_ver="${_zig_os_ver%%-*}"         # "11"  or "10.13"
  if [[ "${_zig_os_ver}" != *.* ]]; then
    ZIG_TRIPLET="${ZIG_TRIPLET/-macos.${_zig_os_ver}-/-macos.${_zig_os_ver}.0-}"
    export ZIG_TRIPLET
  fi
fi
export ZIG_QEMU_ARCH="${ZIG_TRIPLET%%-*}"

# === Build caching for quick recipe iteration ===
# Set ZIG_USE_CACHE=1 to enable build caching:
#   - First run: builds normally, caches result
#   - Subsequent runs: restores from cache, skips build
if [[ "${ZIG_USE_CACHE:-0}" == "1" ]]; then
  source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
  if stub_cache_restore; then
    echo "=== Build restored from cache (skipping compilation) ==="
    exit 0
  fi
  echo "=== No cache found - will build and cache result ==="
  # Continue with normal build, cache will be saved at the end
fi

# --- Main ---

export CMAKE_BUILD_PARALLEL_LEVEL="${CPU_COUNT}"
export CMAKE_GENERATOR=Ninja
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR_OVERRIDE:-${SRC_DIR}/zig-global-cache}"
export ZIG_LOCAL_CACHE_DIR="${SRC_DIR}/zig-local-cache"

cmake_source_dir="${SRC_DIR}/zig-source"
cmake_build_dir="${SRC_DIR}/build-release"
cmake_install_dir="${PREFIX}"
zig_build_dir="${SRC_DIR}/conda-zig-source"

mkdir -p "${zig_build_dir}" && cp -r "${cmake_source_dir}"/* "${zig_build_dir}"
mkdir -p "${cmake_install_dir}" "${ZIG_LOCAL_CACHE_DIR}" "${ZIG_GLOBAL_CACHE_DIR}"

# --- Common CMake/zig configuration ---

EXTRA_CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DZIG_TARGET_MCPU=baseline
  -DZIG_TARGET_TRIPLE=${ZIG_TRIPLET}
  -DZIG_USE_LLVM_CONFIG=ON
)

# Remember: CPU MUST be baseline, otherwise it create non-portable zig code (optimized for a given hardware)
EXTRA_ZIG_ARGS=(
  --search-prefix "${PREFIX}"
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

# Tell the prefer-shared-libcxx patch where to find target-arch libc++.so.
if is_osx; then
  export ZIG_SHARED_LIBCXX_DIR="${PREFIX}/lib"
else
  export ZIG_SHARED_LIBCXX_DIR="${PREFIX}/lib/zig-llvm/lib"
fi

# Native (non-cross) builds pull no conda llvmdev, and zig-llvm isolates its toolchain
# under ${PREFIX}/lib/zig-llvm (llvm-config shipped by the transitive zig-llvm-tblgen dep,
# NOT on PATH). Expose it so cmake's Findllvm.cmake find_program(llvm-config) resolves it.
# Cross builds are intentionally excluded: they keep using the BUILD_PREFIX (conda llvmdev)
# llvm-config copied to ${PREFIX}/bin plus the config.h perl rewrites, and must NOT pick up
# zig-llvm's target-arch (unrunnable) llvm-config first.
if is_unix && ! is_cross; then
  export ZIG_LLVM_ROOT="${PREFIX}/lib/zig-llvm"
  export PATH="${ZIG_LLVM_ROOT}/bin:${PATH}"
  # Port from recipes/zig-zig: make the final `zig build-exe zig` linker search
  # zig-llvm's isolated lib dir so libLLVM-20.so / libclang-cpp.so / liblldZig.so
  # resolve the ~43 LLVM/Clang C++ symbols pulled from libzigcpp.a. Native-only:
  # cross builds intentionally keep BUILD_PREFIX llvmdev and must NOT add this prefix.
  EXTRA_ZIG_ARGS+=(--search-prefix "${ZIG_LLVM_ROOT}")
fi

# Windows native: zig-llvm ships llvm-config as an unusable #!/bin/sh wrapper plus
# llvm-config.real.exe (remove-unneeded.sh). The is_unix guard above skips Windows,
# so cmake's find_package(llvm)/Findllvm.cmake cannot locate llvm-config. Point it at
# the real PE binary directly. Native-only (cross keeps BUILD_PREFIX llvmdev).
if is_not_unix && ! is_cross; then
  export ZIG_LLVM_ROOT="${PREFIX}/Library/lib/zig-llvm"
  export PATH="${ZIG_LLVM_ROOT}/bin:${PATH}"
  # zig's cmake/Findllvm.cmake force-unsets LLVM_CONFIG_EXE and runs its own
  # find_program(LLVM_CONFIG_EXE NAMES ... llvm-config) over PATH, so the
  # -DLLVM_CONFIG override below is ignored and the extensionless #!/bin/sh wrapper
  # on PATH gets picked (its output breaks the LLVM 20.x version check). Mirror
  # recipes/zig-zig: drop the bare wrapper and expose the real PE binary as a plain
  # llvm-config.exe so find_program resolves the real llvm-config.
  rm -f "${ZIG_LLVM_ROOT}/bin/llvm-config"
  if [[ -f "${ZIG_LLVM_ROOT}/bin/llvm-config.real.exe" ]]; then
    cp "${ZIG_LLVM_ROOT}/bin/llvm-config.real.exe" "${ZIG_LLVM_ROOT}/bin/llvm-config.exe"
  fi
  _llvm_config=$(find "${ZIG_LLVM_ROOT}/bin" \( -name 'llvm-config.real.exe' -o -name 'llvm-config.exe' \) -type f 2>/dev/null | head -1)
  EXTRA_CMAKE_ARGS+=(-DLLVM_CONFIG:FILEPATH="${_llvm_config//\\//}")

  # zig's Findclang.cmake can't match zig-llvm's Windows import lib (libclang-cpp.dll.a),
  # so CLANG_LIBRARIES resolves NOTFOUND. Feed LLVM/Clang/LLD to cmake directly from the
  # bundled zig-llvm import libs via the ZIG_LLVM_MANUAL_OVERRIDE patch (never conda clangdev).
  _win_libllvm=$(find "${ZIG_LLVM_ROOT}/lib" -name 'libLLVM*.dll.a' -type f 2>/dev/null | head -1)
  _win_libclang=$(find "${ZIG_LLVM_ROOT}/lib" -name 'libclang-cpp*.dll.a' -type f 2>/dev/null | head -1)
  EXTRA_CMAKE_ARGS+=(
    -DZIG_LLVM_MANUAL_OVERRIDE=1
    -DZIG_LLVM_MANUAL_LIBRARIES="${_win_libllvm}"
    -DZIG_LLVM_MANUAL_LIBDIRS="${ZIG_LLVM_ROOT}/lib"
    -DZIG_LLVM_MANUAL_INCLUDE_DIRS="${ZIG_LLVM_ROOT}/include"
    -DZIG_LLVM_MANUAL_CLANG_LIBRARIES="${_win_libclang}"
    -DZIG_LLVM_MANUAL_LLD_LIBRARIES="${ZIG_LLVM_ROOT}/lib/liblldZig.dll.a"
  )

  # zig's gnu-target linker searches libNAME.a but NOT libNAME.dll.a; both are ar
  # import archives, so expose .a aliases so the Stage-2 self-hosted `zig build` links.
  for _dlla in "${_win_libllvm}" "${_win_libclang}" "${ZIG_LLVM_ROOT}/lib/liblldZig.dll.a"; do
    if [[ -f "${_dlla}" ]]; then
      cp -f "${_dlla}" "${_dlla%.dll.a}.a"
    fi
  done
fi

# Patch build.zig-doctest-forward-target adds -Ddoctest-target to build.zig.
# Applied universally; gated here to platforms that benefit from explicit
# target forwarding to zig2 self-hosted backend (avoids comptime f16->f32 bug).
if is_unix; then
  EXTRA_ZIG_ARGS+=(-Ddoctest-target=${ZIG_TRIPLET})
fi

# ppc64le: zig2.c is a ~11M-line auto-generated C TU. PowerPC direct branches
# are limited to 26-bit signed displacement (+/-32MB), and inter-function
# distances inside zig2.c exceed that range, producing GAS errors:
#   "Error: operand out of range (... is not between 0xfffffffffe000000 and 0x1fffffc)"
# -mlongcall makes GCC emit indirect calls via CTR for any-distance reach.
# Applies to both native and cross ppc64le builds (same generated source).
# -fno-partial-inlining/-fno-ipa-cp-clone were dropped: those GCC-specific
# IPA/inlining pass toggles are rejected by Clang/zig-cc, which now compiles
# zigcpp for the cross-linux ppc64le path (see is_linux && is_cross block above).
if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  export CFLAGS="${CFLAGS:-} -mlongcall -mcmodel=large"
  export CXXFLAGS="${CXXFLAGS:-} -mlongcall -mcmodel=large"
  # REL24 mitigation: --stub-group-size=0 lets binutils auto-size stub groups
  # -L${PREFIX}/lib/zig-llvm/lib: reuse zig-llvm's self-built libunwind.so
  # (already a host dep of this output) instead of relying on the linker's
  # default search path to happen to find it.
  export LDFLAGS="${LDFLAGS:-} -Wl,--stub-group-size=0 -Wl,--wrap=pthread_atfork -L${PREFIX}/lib/zig-llvm/lib"
  export NINJA_FLAGS="-v"
  # zig-llvm's ppc64le package only ships a versioned libunwind.so.1.0, no
  # unversioned dev symlink, so CMake's own compiler sanity-check link fails
  # with "cannot find -lunwind". Create the symlink so -lunwind resolves.
  if [[ -f "${PREFIX}/lib/zig-llvm/lib/libunwind.so.1.0" && ! -e "${PREFIX}/lib/zig-llvm/lib/libunwind.so" ]]; then
    ln -sf libunwind.so.1.0 "${PREFIX}/lib/zig-llvm/lib/libunwind.so"
  fi
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_C_FLAGS="${CFLAGS}"
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}"
    -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}"
    -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}"
  )
  EXTRA_CMAKE_ARGS+=(
    -DZIG_LLD_BUNDLE_SO="${ZIG_LOCAL_CACHE_DIR}/libzig-lld-bundle.so"
    -DZIG_ZIGCPP_BUNDLE_SO="${ZIG_LOCAL_CACHE_DIR}/libzig-zigcpp-bundle.so"
  )
fi

# Strip host-arch flags injected by conda-build for all cross targets.
# Safe for ppc64le: intentional -mlongcall etc. are target-arch flags
# (set in the ppc64le block above) and don't match the _drop_ppc filter.
if is_cross; then
  sanitize_and_export_cross_flags
fi

# Two-phase langref strategy: Phase 1 (here) ALWAYS skips langref
EXTRA_ZIG_ARGS+=(-Dno-langref)
EXTRA_CMAKE_ARGS+=(-DZIG_NO_LANGREF=ON)

if is_unix; then
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_INSTALL_RPATH="${PREFIX}/lib"
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
  )
  if is_osx; then
    _zig_extra="--search-prefix;${PREFIX};--maxrss;8589934592"
  else
    _zig_extra="--search-prefix;${PREFIX}"
  fi
  # Wire --libc to the cmake path (ZIG_EXTRA_BUILD_ARGS); without this, zig2 under
  # qemu auto-augments the target triple with kernel-version range and fails libc resolution.
  if is_linux && is_cross; then
    _zig_extra="${_zig_extra};--libc;${zig_build_dir}/libc_file"
  fi
  EXTRA_CMAKE_ARGS+=(
    "-DZIG_EXTRA_BUILD_ARGS=${_zig_extra}"
  )
  unset _zig_extra
fi

if is_osx; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SYSTEM_LIBCXX=c++
    -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
  )
  EXTRA_ZIG_ARGS+=(--maxrss 8589934592)
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SYSTEM_LIBCXX=stdc++)
  EXTRA_ZIG_ARGS+=(--maxrss 7500000000)
fi

if is_not_unix; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SHARED_LLVM=OFF
    # Force dynamic CRT (/MD) for zigcpp objects so their /DEFAULTLIB
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
  )
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SHARED_LLVM=ON)
fi

if is_linux && is_cross; then
  # CONDA_BUILD_SYSROOT is normally exported by the gcc cross-activation, which this
  # toolchain deliberately does not depend on; without it the var is unbound under
  # set -u. Derive it from the predictable conda-host-triple sysroot path (where
  # stdlib('c')/sysroot_* installs the files). Also covers create_zig_linux_libc_file
  # (_cross.sh), which reads CONDA_BUILD_SYSROOT in the same cross path.
  export CONDA_BUILD_SYSROOT="${CONDA_BUILD_SYSROOT:-${BUILD_PREFIX}/${CONDA_TRIPLET}/sysroot}"
  EXTRA_ZIG_ARGS+=(
    --libc "${zig_build_dir}"/libc_file
    --libc-runtimes "${CONDA_BUILD_SYSROOT}"/lib64
  )
  # TODO: drop once qemu-execve-ppc64le ships qemu-powerpc64le upstream.
  if [[ "${target_platform}" == "linux-ppc64le" ]] \
     && ! command -v qemu-powerpc64le &>/dev/null \
     && command -v qemu-ppc64le &>/dev/null; then
    ln -sf "$(command -v qemu-ppc64le)" "${BUILD_PREFIX}/bin/qemu-powerpc64le"
  fi
  # Enable qemu if qemu-execve-<arch> package is installed (conda-forge).
  # Provides qemu-<arch> in PATH which is what zig's -fqemu expects.
  if command -v "qemu-${ZIG_QEMU_ARCH}" &>/dev/null; then
    EXTRA_ZIG_ARGS+=(-fqemu)
  fi
fi

# --- libzigcpp Configuration ---

if is_linux; then
  source "${RECIPE_DIR}/building/_libc_tuning.sh"
  create_gcc14_glibc28_compat_lib

  is_cross && rm "${PREFIX}"/bin/llvm-config && cp "${BUILD_PREFIX}"/bin/llvm-config "${PREFIX}"/bin/llvm-config
fi

# LLVM_LIBRARIES from llvm-config which omits zstd/xml2/z. LLD's
# riscv64 excluded: it uses namespaced host packages (zig-zstd/zig-xml2/
# zig-zlib) and already gets correct absolute-path linker flags injected
# below (build.sh:536-541); the bare -lzstd/-lxml2/-lz names injected here
# are unresolvable there and break the final link.
is_linux && [[ "${target_platform}" != "linux-riscv64" ]] && perl -pi -e 's@(find_package\(Threads\))@$1\nlist(APPEND LLVM_LIBRARIES "-lzstd" "-lxml2" "-lz")@' "${cmake_source_dir}"/CMakeLists.txt

if is_osx && is_cross; then
  case "${target_platform}" in
    osx-64)     EXTRA_CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES=x86_64) ;;
    osx-arm64)  EXTRA_CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES=arm64) ;;
  esac

  # llvmdev-free: source LLVM from the target ($PREFIX) zig-llvm host dep, never
  # conda llvmdev. The host-arch (BUILD_PREFIX) zig-llvm is not needed here since
  # zigcpp must link the TARGET-arch libLLVM; headers are arch-independent so the
  # target copy suffices. Version comes from zig-llvm headers; cmake skips
  # llvm-config via the ZIG_LLVM_MANUAL_OVERRIDE patch.
  _zig_llvm="${PREFIX}/lib/zig-llvm"
  _libllvm=$(find "${_zig_llvm}/lib" -name 'libLLVM*.dylib' -type f 2>/dev/null | head -1)
  _libclang=$(find "${_zig_llvm}/lib" -name 'libclang-cpp*.dylib' -type f 2>/dev/null | head -1)
  # Pass as CMake cache vars (-D), NOT env exports: the Findllvm/clang/lld
  # override patch tests if(DEFINED ZIG_LLVM_MANUAL_OVERRIDE) at cmake scope.
  EXTRA_CMAKE_ARGS+=(
    -DZIG_LLVM_MANUAL_OVERRIDE=1
    -DZIG_LLVM_MANUAL_LIBRARIES="${_libllvm}"
    -DZIG_LLVM_MANUAL_LIBDIRS="${_zig_llvm}/lib"
    -DZIG_LLVM_MANUAL_INCLUDE_DIRS="${_zig_llvm}/include"
    -DZIG_LLVM_MANUAL_CLANG_LIBRARIES="${_libclang}"
    -DZIG_LLVM_MANUAL_LLD_LIBRARIES="${_zig_llvm}/lib/liblldZig.dylib"
  )
fi

if is_linux && is_cross; then
  # llvmdev-free clang/lld detection for CMake Generate: conda's llvmdev ships
  # LLVM only (never clang/lld dev files, per project policy), so zig's
  # Findclang.cmake/Findlld.cmake probing (via the BUILD_PREFIX llvm-config
  # copied over above) resolves CLANG_LIBRARIES to NOTFOUND on some target
  # arches (e.g. riscv64 cross), aborting the zigcpp CMake Generate step.
  # Feed LLVM/Clang/LLD to cmake directly from the bundled target-arch
  # zig-llvm host package (linking only, never executed) via the
  # ZIG_LLVM_MANUAL_OVERRIDE patch. Mirrors the is_osx && is_cross block
  # above (same mechanism; Linux .so instead of macOS .dylib naming).
  _zig_llvm_lnx="${PREFIX}/lib/zig-llvm"
  _libllvm_lnx=$(find "${_zig_llvm_lnx}/lib" -name 'libLLVM*.so*' -type f 2>/dev/null | head -1)
  _libclang_lnx=$(find "${_zig_llvm_lnx}/lib" -name 'libclang-cpp*.so*' -type f 2>/dev/null | head -1)
  # zig-llvm never builds liblldZig.so on linux-riscv64/linux-s390x (see
  # recipes/zig-llvm/building/_lld_bundle.sh:18-23 — no conda-forge
  # zstd/xml2/z there), so the hardcoded .so path below is never present on
  # those arches, and CMake's ZIG_LLVM_MANUAL_OVERRIDE patch would report a
  # false "Found lld" that later dies at zig link time with "liblldZig.so:
  # file not found". Feed the six static liblld*.a archives directly instead,
  # in the exact order _lld_bundle.sh links them (format-specific archives
  # first, liblldCommon.a last since it is the shared base component other
  # archives depend on) — do NOT use `find | sort`, alphabetical order would
  # put lldCommon before lldELF and break the link. Mirrors the arch
  # exclusion at build.sh:402, but ppc64le is intentionally NOT excluded here:
  # the bundle IS built on ppc64le, so the .so path remains correct there.
  if [[ "${target_platform}" == "linux-riscv64" || "${target_platform}" == "linux-s390x" ]]; then
    _lldlibs_lnx="${_zig_llvm_lnx}/lib/liblldELF.a;${_zig_llvm_lnx}/lib/liblldCOFF.a;${_zig_llvm_lnx}/lib/liblldMachO.a;${_zig_llvm_lnx}/lib/liblldWasm.a;${_zig_llvm_lnx}/lib/liblldMinGW.a;${_zig_llvm_lnx}/lib/liblldCommon.a"
  else
    _lldlibs_lnx="${_zig_llvm_lnx}/lib/liblldZig.so"
  fi
  EXTRA_CMAKE_ARGS+=(
    -DZIG_LLVM_MANUAL_OVERRIDE=1
    -DZIG_LLVM_MANUAL_LIBRARIES="${_libllvm_lnx}"
    -DZIG_LLVM_MANUAL_LIBDIRS="${_zig_llvm_lnx}/lib"
    -DZIG_LLVM_MANUAL_INCLUDE_DIRS="${_zig_llvm_lnx}/include"
    -DZIG_LLVM_MANUAL_CLANG_LIBRARIES="${_libclang_lnx}"
    -DZIG_LLVM_MANUAL_LLD_LIBRARIES="${_lldlibs_lnx}"
  )
fi

# Local-only additional patches (gitignored directory)
if [[ -n "${LOCAL_PATCHES_DIR:-}" && -d "${LOCAL_PATCHES_DIR}" ]]; then
    for _p in "${LOCAL_PATCHES_DIR}"/*.patch; do
        [[ -f "${_p}" ]] || continue
        echo "Applying local patch: $(basename "${_p}")"
        patch -p1 < "${_p}"
    done
fi

# Native linux: zig-llvm's libLLVM/libclang-cpp are built with libc++ (_llvm_build.sh
# LLVM_ENABLE_LIBCXX=ON), but conda g++ compiles zigcpp against libstdc++, so the final
# self-hosted link fails with undefined std::__cxx11 (abi:cxx11) symbols. Compile zigcpp
# with the host zig's `c++` (clang + bundled libc++) to match zig-llvm's ABI, and request
# the c++ runtime. Ported from recipes/zig-zig (build.sh:152-166,375-379). Native-only:
# cross-linux uses conda llvmdev (libstdc++, already matched) and osx conda clang is
# already libc++. The "never zig-cc" note in _build.sh is scoped to cross-build target
# conflicts, which do not apply to this native self-host path.
if is_linux && ! is_cross; then
  printf '#!/bin/sh\nexec %s cc "$@"\n'  "${CONDA_ZIG_BUILD}" > "${SRC_DIR}/zig-cc-early"
  printf '#!/bin/sh\nexec %s c++ "$@"\n' "${CONDA_ZIG_BUILD}" > "${SRC_DIR}/zig-cxx-early"
  chmod +x "${SRC_DIR}/zig-cc-early" "${SRC_DIR}/zig-cxx-early"
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_C_COMPILER="${SRC_DIR}/zig-cc-early"
    -DCMAKE_CXX_COMPILER="${SRC_DIR}/zig-cxx-early"
    -DZIG_SYSTEM_LIBCXX=c++
  )
elif is_linux && is_cross; then
  # Cross builds must also use zig-cc for zigcpp (maintainer decision 2026-07-24:
  # these recipes never depend on real GCC/Clang; zig-cc is used everywhere,
  # including cross). Without CMAKE_C_COMPILER/CXX_COMPILER set here, CMake's
  # CMakeTestCCompiler configure-time check falls back to the bare host
  # /usr/bin/cc, which then rejects target-arch flags (e.g. ppc64le -mlongcall).
  # zig-cc has a baked-in native target, so pass --target=${ZIG_TRIPLET}
  # explicitly (same precedent as _WRAPPER_CC_EXTRA below) via CMAKE_C_FLAGS/
  # CMAKE_CXX_FLAGS, appended to the already-sanitized cross CFLAGS/CXXFLAGS.
  printf '#!/bin/sh\nexec %s cc "$@"\n'  "${CONDA_ZIG_BUILD}" > "${SRC_DIR}/zig-cc-early"
  printf '#!/bin/sh\nexec %s c++ "$@"\n' "${CONDA_ZIG_BUILD}" > "${SRC_DIR}/zig-cxx-early"
  chmod +x "${SRC_DIR}/zig-cc-early" "${SRC_DIR}/zig-cxx-early"
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_C_COMPILER="${SRC_DIR}/zig-cc-early"
    -DCMAKE_CXX_COMPILER="${SRC_DIR}/zig-cxx-early"
    -DCMAKE_C_FLAGS="${CFLAGS:-} --target=${ZIG_TRIPLET}"
    -DCMAKE_CXX_FLAGS="${CXXFLAGS:-} --target=${ZIG_TRIPLET}"
  )
elif is_not_unix; then
  # On Windows, CMake detects zig-cc as ClangCL and injects MSVC-style linker flags
  # (/MANIFEST:EMBED, /subsystem:console, -fuse-ld=lld-link) that zig doesn't support.
  # Without CMAKE_C_COMPILER set here, CMake auto-detects MSVC (cl.exe) for zigcpp:
  # its COFF objects embed /DEFAULTLIB:MSVCPRT,MSVCRT,OLDNAMES, which the
  # windows-gnu Stage-2 link can't resolve ("lld-link: could not open 'libMSVCRT.a'").
  # Ported from recipes/zig-zig/build.sh (is_not_unix cmake-cache-seed block).
  # ninja invokes CMAKE_C_COMPILER/CMAKE_CXX_COMPILER/CMAKE_AR/CMAKE_RANLIB via
  # raw Win32 CreateProcess, which cannot execute a bare shebang text file
  # ("CreateProcess failed... %1 is not a valid Win32 application", confirmed
  # from CI log). Compile tiny C forwarders instead, mirroring the proven
  # "compile a tiny C forwarder via zig cc -O2" technique already used in
  # install_zig_activation.py:161-168 (zig_bin, "cc", "-O2", ..., "-lkernel32").
  # CONDA_ZIG_BUILD can arrive with backslashes on Windows; normalize to
  # forward slashes (same sed idiom used elsewhere in this file) before
  # embedding it as a C string literal below.
  _conda_zig_build_fwd="$(printf '%s' "${CONDA_ZIG_BUILD}" | tr -d '[:cntrl:]' | sed 's|\\|/|g')"

  # NOTE: values are baked directly into each generated .c file via bash
  # variable substitution in an UNQUOTED heredoc (not passed as compiler -D
  # flags) -- an earlier attempt using `-DZIG_BIN="..."` failed because the
  # embedded quotes did not survive zig-cc's argument handling on this
  # Windows runner (confirmed via CI log: the compiler's own macro dump
  # showed the quotes stripped, e.g. `#define ZIG_BIN x86_64-w64-mingw32-zig`,
  # causing "use of undeclared identifier" errors on the hyphenated value).
  # Baking the string into the source text sidesteps that entirely, matching
  # the @PLACEHOLDER@-substitution technique already used by
  # building/cross-zig-shim.c in this same recipe.
  for _pair in "cc:zig-cc-early" "c++:zig-cxx-early" "ar:zig-ar-early" "ranlib:zig-ranlib-early"; do
    _subcmd="${_pair%%:*}"
    _outname="${_pair#*:}"
    _shim_src="${SRC_DIR}/${_outname}.c"
    cat > "${_shim_src}" << SHIMEOF
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <process.h>

static const char *ZIG_BIN = "${_conda_zig_build_fwd}";
static const char *ZIG_SUBCMD = "${_subcmd}";

int main(int argc, char *argv[]) {
    const char **new_argv = (const char **)malloc(sizeof(char *) * (size_t)(argc + 2));
    if (!new_argv) {
        fprintf(stderr, "zig-early-shim: malloc failed\n");
        return 1;
    }
    int ni = 0;
    new_argv[ni++] = ZIG_BIN;
    new_argv[ni++] = ZIG_SUBCMD;
    for (int i = 1; i < argc; i++) {
        new_argv[ni++] = argv[i];
    }
    new_argv[ni] = NULL;
    int ret = (int)_spawnvp(_P_WAIT, ZIG_BIN, new_argv);
    free(new_argv);
    if (ret == -1) {
        fprintf(stderr, "zig-early-shim: failed to exec %s: %s\n", ZIG_BIN, strerror(errno));
        return 1;
    }
    return ret;
}
SHIMEOF
    "${CONDA_ZIG_BUILD}" cc -O2 -o "${SRC_DIR}/${_outname}.exe" "${_shim_src}" -lkernel32
  done

  # Pre-seed the cmake cache so CMake skips the compiler test entirely.
  _cache_seed="${SRC_DIR}/zig-cmake-cache.cmake"
  _zig_cc_cmake="${SRC_DIR}/zig-cc-early.exe"
  _zig_cxx_cmake="${SRC_DIR}/zig-cxx-early.exe"
  _zig_ar_cmake="${SRC_DIR}/zig-ar-early.exe"
  _zig_ranlib_cmake="${SRC_DIR}/zig-ranlib-early.exe"
  # BUILD_PREFIX/SRC_DIR-derived paths can arrive with backslashes and stray
  # control characters (CR/LF) on Windows; a lone control char is parsed by
  # CMake as a line break inside a quoted set() value ("Parse error. Expected
  # a command name, got unquoted argument"). Strip control chars and
  # normalize backslashes to forward slashes for every path used below. sed
  # (not perl) for the substitution: perl mangles \o \p \a as escapes even
  # inside \Q..\E. Ported verbatim (idiom) from recipes/zig-zig/build.sh.
  for _v in _zig_cc_cmake _zig_cxx_cmake _zig_ar_cmake _zig_ranlib_cmake; do
    printf -v "${_v}" '%s' "$(printf '%s' "${!_v}" | tr -d '[:cntrl:]')"
    printf -v "${_v}" '%s' "$(printf '%s' "${!_v}" | sed 's|\\|/|g')"
  done
  cat > "${_cache_seed}" << TCEOF
# Pre-seed compiler identification so CMake skips the test program
set(CMAKE_C_COMPILER_ID "Clang" CACHE STRING "")
set(CMAKE_CXX_COMPILER_ID "Clang" CACHE STRING "")
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
TCEOF

  # -D command-line args (not -C cache-file lines): byte-exact CI diagnostics on
  # recipes/zig-zig proved the -C file is written clean and single-line, yet CMake
  # parsed a long quoted FILEPATH value as split across two physical lines. -D
  # args are parsed from argv, not the cache-file line parser, sidestepping that.
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_C_COMPILER:FILEPATH="${_zig_cc_cmake}"
    -DCMAKE_CXX_COMPILER:FILEPATH="${_zig_cxx_cmake}"
    -DCMAKE_AR:FILEPATH="${_zig_ar_cmake}"
    -DCMAKE_RANLIB:FILEPATH="${_zig_ranlib_cmake}"
  )
  EXTRA_CMAKE_ARGS+=(-C "${_cache_seed}")
fi

configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

# --- ppc64le bundle .so build (after cmake configure, before zig2 link) ---
if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  dbg echo "=== ppc64le lld bundle ==="
  mkdir -p "${PREFIX}/lib"
  source "${RECIPE_DIR}/building/_lld_bundle.sh"
  build_lld_bundle_ppc64le "${CXX}" "${PREFIX}" "${ZIG_LOCAL_CACHE_DIR}" || exit 1
  install -m 755 "${ZIG_LOCAL_CACHE_DIR}/libzig-lld-bundle.so" "${PREFIX}/lib/" || exit 1
  source "${RECIPE_DIR}/building/_zigcpp_bundle.sh"
  build_zigcpp_bundle_ppc64le "${CXX}" "${PREFIX}" "${ZIG_LOCAL_CACHE_DIR}" "${cmake_build_dir}" || exit 1
  install -m 755 "${ZIG_LOCAL_CACHE_DIR}/libzig-zigcpp-bundle.so" "${PREFIX}/lib/" || exit 1
fi

# --- Post CMake Configuration ---

# Append extra link deps to config.h (cmake doesn't know about conda's split packaging)
if is_linux && is_cross && [[ "${target_platform}" == "linux-riscv64" ]]; then
  # riscv64 uses namespaced host packages (zig-zstd/zig-xml2/zig-zlib), not
  # plain conda-forge zstd/libxml2/zlib, so bare -l names don't resolve at
  # link time. Wire in absolute .so paths instead. Note: the xml2 package
  # installs to a dir literally named "zig-xml2", not "zig-libxml2".
  perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${PREFIX}/lib/zig-zstd/lib/libzstd.so;${PREFIX}/lib/zig-xml2/lib/libxml2.so;${PREFIX}/lib/zig-zlib/lib/libz.so\"@" "${cmake_build_dir}"/config.h
elif is_linux && is_cross; then
  perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;-lzstd;-lxml2;-lz\"@" "${cmake_build_dir}"/config.h
fi
is_osx && is_cross &&   perl -pi -e "s@(ZIG_LLVM_\w+ \")${BUILD_PREFIX}@\$1${PREFIX}@" "${cmake_build_dir}"/config.h
is_osx &&               perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${PREFIX}/lib/zig-llvm/lib/libc++.dylib\"@" "${cmake_build_dir}"/config.h

# Wire zig-llvm's liblldZig bundle into config.h ZIG_LLVM_LIBRARIES so the final
# self-hosted zig link resolves lld::{elf,coff,wasm,macho}::link. zig-llvm ships
# only the single liblldZig bundle (remove-unneeded.sh strips the individual
# liblld*.a archives). Ported from recipes/zig-zig/build.sh. Scoped to the
# native-link arches (x86_64/aarch64 linux + osx); riscv64/s390x/ppc64le and
# windows keep their existing arch-specific handling untouched.
if is_linux && [[ "${target_platform}" != "linux-riscv64" && "${target_platform}" != "linux-s390x" && "${target_platform}" != "linux-ppc64le" ]]; then
  _lld_lib="${PREFIX}/lib/zig-llvm/lib"
  perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${_lld_lib}/liblldZig.so;-lzstd;-lxml2;-lz;-L${_lld_lib};-lc++;-lc++abi;-lunwind\"@" "${cmake_build_dir}"/config.h
elif is_osx; then
  _lld_lib="${PREFIX}/lib/zig-llvm/lib"
  perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${_lld_lib}/liblldZig.dylib;-L${_lld_lib}\"@" "${cmake_build_dir}"/config.h
fi

# --- Cross-build setup (must happen BEFORE Stage 1 since EXTRA_ZIG_ARGS has --libc) ---

if is_linux && is_cross; then
  source "${RECIPE_DIR}/building/_cross.sh"
  source "${RECIPE_DIR}/building/_atfork.sh"

  create_zig_linux_libc_file "${zig_build_dir}/libc_file"

  # pthread_atfork stub + --wrap mechanism is cmake-path-only. zig-build path
  # falls through to libpthread_nonshared.a's pthread_atfork (REL24 risk --
  # bundles will address that separately).
  if [[ "${CMAKE_BUILD:-0}" == "1" ]]; then
    perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"
    create_pthread_atfork_stub "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
  fi

  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/libc_single_threaded_stub.o\"|g" "${cmake_build_dir}/config.h"
  create_libc_single_threaded_stub "${SRC_DIR}/zig-cc-early" "${ZIG_LOCAL_CACHE_DIR}"
elif is_linux; then
  # Native linux still links the final zig against -Dtarget=...gnu.2.17 (old glibc),
  # but GCC15+/libc++ objects in zigcpp reference glibc-2.32's __libc_single_threaded.
  # Provide the same weak stub the cross path uses so the self-hosted link resolves it.
  source "${RECIPE_DIR}/building/_atfork.sh"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/libc_single_threaded_stub.o\"|g" "${cmake_build_dir}/config.h"
  # Native unix has no conda C compiler (compiler('c') is Windows-only); use the
  # host zig cc wrapper created above (same compiler that builds zigcpp).
  create_libc_single_threaded_stub "${SRC_DIR}/zig-cc-early" "${ZIG_LOCAL_CACHE_DIR}"
fi

# Always-linux: sysroot ld-script rewrite (needed by wrapper compile and any zig cc
# invocation that lacks --sysroot flags). On native linux-64 the sysroot's
# libpthread.so contains absolute /usr/lib64/... paths that LLD can't resolve.
if is_linux; then
  source "${RECIPE_DIR}/building/_sysroot_fix.sh"
  fix_sysroot_libc_scripts "${BUILD_PREFIX}"
fi

if is_linux && is_cross; then
  export QEMU_LD_PREFIX="${BUILD_PREFIX}/${CONDA_TRIPLET}/sysroot"
fi

# Resolve bootstrap zig binary: prefer the conda_triplet/build_triplet-suffixed
# name (legacy self-built zig15_impl wrapper), then any *-zig binary, then
# fall back to conda-forge zig's plain `zig`/`zig.exe` (no triplet prefix).
zig="$(find "${BUILD_PREFIX}/bin" "${BUILD_PREFIX}/Library/bin" \( -name "${CONDA_ZIG_BUILD}" -o -name "${CONDA_ZIG_BUILD}.exe" -o -name "${CONDA_ZIG_HOST}" -o -name "${CONDA_ZIG_HOST}.exe" \) 2>/dev/null | head -1 || true)"
if [[ -z "${zig}" ]]; then
  zig="$(find "${BUILD_PREFIX}/bin" "${BUILD_PREFIX}/Library/bin" -name '*-zig' -o -name '*-zig.exe' 2>/dev/null | head -1 || true)"
fi
if [[ -z "${zig}" ]]; then
  zig="$(find "${BUILD_PREFIX}/bin" "${BUILD_PREFIX}/Library/bin" \( -name 'zig' -o -name 'zig.exe' \) 2>/dev/null | head -1 || true)"
fi
if [[ -z "${zig}" ]]; then
  echo "ERROR: could not locate bootstrap zig binary in BUILD_PREFIX/bin or BUILD_PREFIX/Library/bin" >&2
  exit 1
fi
echo "Bootstrap zig binary: ${zig}"

dbg echo "=== zig build env ==="
if [[ "${CMAKE_BUILD:-0}" == "1" ]]; then
  source "${RECIPE_DIR}/building/_cmake.sh"
  cmake_build "${cmake_source_dir}" "${cmake_build_dir}" "${PREFIX}"
elif build_zig_with_zig "${zig_build_dir}" "${zig}" "${PREFIX}"; then
  :
else
  echo "ERROR: zig-build failed. Set CMAKE_BUILD=1 to force the cmake path explicitly." >&2
  exit 1
fi


# macOS: --search-prefix adds a library search but does not embed LC_RPATH in the Mach-O binary.
if is_osx; then
  install_name_tool -add_rpath "${PREFIX}/lib" "${PREFIX}/bin/zig"
fi

if is_linux; then
  # zig dynamically links zig-llvm's libLLVM/libclang-cpp/liblldZig, which install
  # under $PREFIX/lib/zig-llvm/lib (not $PREFIX/lib). Include that dir on the rpath
  # so the shipped zig (and the Phase 2 `zig build langref` invocation) can load them.
  patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN/../lib/zig-llvm/lib' "${PREFIX}/bin/zig"
fi


# --- Phase 2: build langref via stage3 (full compiler with translate_c) ---
_can_run_stage3() {
  if ! is_cross; then return 0; fi
  if is_linux; then
    command -v "qemu-${ZIG_QEMU_ARCH}" &>/dev/null && return 0
  fi
  return 1
}

if [[ "${SKIP_LANGREF:-0}" == "1" ]]; then
  echo "INFO: Phase 2 langref skipped: SKIP_LANGREF=1 (local dev override)" >&2
elif _can_run_stage3; then
  dbg echo "=== phase 2 langref ==="
  _stage3_runner=()
  if is_cross && is_linux; then
    _stage3_runner=("qemu-${ZIG_QEMU_ARCH}")
  fi

  # Zig hardcodes qemu-<arch> lookup. The regular qemu-powerpc64le variant
  # ships the binary as qemu-ppc64le, but zig looks for qemu-powerpc64le,
  # so a shadow directory with a correctly-named symlink is required.
  _qemu_shadow_dir=""
  if [ -n "${QEMU_EXECVE:-}" ] && [ -x "${QEMU_EXECVE}" ]; then
    _qemu_shadow_dir=$(mktemp -d)
    ln -sf "${QEMU_EXECVE}" "${_qemu_shadow_dir}/qemu-${ZIG_QEMU_ARCH}"
    export PATH="${_qemu_shadow_dir}:${PATH}"
  fi

  (
    cd "${cmake_source_dir}" || exit 1
    # macOS: the just-built ${PREFIX}/bin/zig references zig-llvm dylibs via
    # @loader_path/<name> (inherited from libclang-cpp.dylib's LC_ID), which
    # resolves to ${PREFIX}/bin/ where those dylibs do not live. For this
    # transient langref run let dyld fall back to zig-llvm/lib by leaf name.
    # The final zig-real binary gets its dep paths rewritten after the wrapper
    # split (see "Fixing zig-real dylib refs" below).
    if is_osx; then
      export DYLD_FALLBACK_LIBRARY_PATH="${PREFIX}/lib/zig-llvm/lib${DYLD_FALLBACK_LIBRARY_PATH:+:${DYLD_FALLBACK_LIBRARY_PATH}}"
    fi
    "${_stage3_runner[@]+"${_stage3_runner[@]}"}" "${PREFIX}/bin/zig" build langref \
      --prefix "${PREFIX}" \
      -Dversion-string="${PKG_VERSION}" \
      -Ddoctest-target="${ZIG_TRIPLET}"
  ) || {
    if ! is_cross; then
      echo "ERROR: Phase 2 langref build failed (native build, expected to succeed)" >&2
      exit 1
    fi
    echo "WARNING: Phase 2 langref build failed (cross build, non-fatal)" >&2
  }

  if [ -n "${_qemu_shadow_dir:-}" ]; then
    rm -rf "${_qemu_shadow_dir}"
    unset _qemu_shadow_dir
  fi
else
  echo "INFO: Phase 2 langref skipped: stage3 not runnable on this host (cross without qemu/wine)" >&2
fi

# === Phase 2: Unified wrapper install ===
WRAPPER_SRC="${RECIPE_DIR}/building/zig-wrapper.c"
WRAPPER_OBJDIR="${SRC_DIR}/_wrapper_build"
mkdir -p "${WRAPPER_OBJDIR}"

# Determine platform-specific directories first
if is_not_unix; then
    WRAPPER_BIN_DIR="${PREFIX}/Library/bin"
    REAL_ZIG_DIR="${PREFIX}/Library/share/zig"
    REAL_ZIG_NAME="zig-real.exe"
    EXE_EXT=".exe"
else
    WRAPPER_BIN_DIR="${PREFIX}/bin"
    REAL_ZIG_DIR="${PREFIX}/share/zig"
    REAL_ZIG_NAME="zig-real"
    EXE_EXT=""
fi

WRAPPER_C="${WRAPPER_OBJDIR}/zig-wrapper-built.c"

# Wrapper's baked default -target. On Windows the wrapper is named
# <arch>-w64-mingw32-zig and the feedstock ships MinGW (.dll.a) import libs, so
# default to the GNU/MinGW ABI; users can still select MSVC explicitly with
# -target <arch>-windows-msvc (the wrapper suppresses its default when the user
# passes -target). This is independent of ZIG_TRIPLET, which still controls how
# the zig binary itself is built (zig is multi-target).
case "${target_platform}" in
    win-64)    WRAPPER_DEFAULT_TARGET="x86_64-windows-gnu" ;;
    win-arm64) WRAPPER_DEFAULT_TARGET="aarch64-windows-gnu" ;;
    win-32)    WRAPPER_DEFAULT_TARGET="x86-windows-gnu" ;;
    *)         WRAPPER_DEFAULT_TARGET="${ZIG_TRIPLET%%.[0-9]*}" ;;
esac

# Substitute compile-time placeholders. Substitute @ZIG_REAL_PATH@ with the
# absolute zig-real path; conda's binary prefix-replacement handles relocation at install time.
sed -e "s|@ZIG_TARGET@|${WRAPPER_DEFAULT_TARGET}|g" \
    -e "s|@ZIG_REAL_PATH@|${REAL_ZIG_DIR//\\//}/${REAL_ZIG_NAME}|g" \
    "${WRAPPER_SRC}" > "${WRAPPER_C}"

mkdir -p "${WRAPPER_BIN_DIR}" "${REAL_ZIG_DIR}"

# macOS Mach-O needs header padding for conda's install_name_tool relinking
WRAPPER_LDFLAGS=""
case "${target_platform}" in
    osx-*) WRAPPER_LDFLAGS="-Wl,-headerpad_max_install_names" ;;
esac

dbg echo "=== pre-wrapper compile ==="

# Per-target wrapper compile flags:
# - linux-ppc64le: pass explicit --target= so zig resolves the ppc64le dynamic
#   linker (/lib64/ld64.so.2) instead of the build-host's x86_64 one, and
#   selects ppc64le's 128-bit-long-double ABI so glibc's bits/stdio-ldbl.h skips
#   the __LDBL_REDIR_DECL asm-label redirect (clang rejects it, gcc accepts).
#   Do NOT add -mlong-double-128: zig 0.15's cc driver folds it into the target
#   query string, producing an InvalidAbiVersion parse error.
# - win-*: compile with -g0 (no debug info) so zig's PE/COFF link does not emit
#   a CodeView .pdb sidecar, which trips package_contents strict checks. A
#   defensive *.pdb removal after the build catches any sidecar that slips through.
# - osx-* (cross only, e.g. osx-64 built from linux-64/osx-arm64 host): the
#   just-built cross zig's runtime native-target detection can disagree with
#   its own build-time target when invoked under host/Rosetta emulation, so
#   `zig cc` with no -target picks the wrong bundled Darwin headers and fails
#   to find stdio.h. Pass --target= explicitly (no -isysroot/SDK needed: per
#   zig-wrapper.c's macOS notes, zig resolves libSystem/headers via its own
#   bundled stubs, not a shipped SDK). Native osx builds are unaffected.
#   Even with --target= set, zig's own libc-detection (LibCDirs.zig
#   detectFromBuilding, confirmed via grep of
#   tmp/src/zig-0.15.2/lib/std/zig/LibCDirs.zig:157:
#   "{s}/libc/include/any-macos-any" under zig_lib_dir) can still fail to
#   surface the bundled cross-libc headers on this host/target combo.
#   CONFIRMED (CI run 31027435721, job 92379661683): passing the headers via
#   `-idirafter` is silently DROPPED by zig's cc frontend for this triple
#   (x86_64-macos.11.0-none) — the flag is present on the invoked command
#   line and the header exists on disk, but LibCDirs' triple-based
#   auto-detection still falls back to zig's bundled freestanding headers.
#   Fix: bypass auto-detection entirely with an explicit libc file via
#   `--libc <path>` (zig's documented libc.txt key=value format) instead of
#   `-idirafter`. Darwin dynamic executables don't need crt objects from this
#   file, so only include_dir/sys_include_dir are populated. Packaged path
#   confirmed via recipe.yaml's `lib/zig/libc/*` glob ->
#   ${PREFIX}/lib/zig/libc/include/any-macos-any.
# Array (not scalar string): IFS is set to $'\n\t' near the top of this file
# (excludes space), so an unquoted scalar expansion of a multi-token value
# like the osx-* case below would NOT word-split and would be passed to
# `zig cc` as a single malformed argument. Array expansion is immune to IFS.
_WRAPPER_CC_EXTRA=()
case "${target_platform}" in
    linux-ppc64le) _WRAPPER_CC_EXTRA=(--target="${ZIG_TRIPLET}") ;;
    win-*)         _WRAPPER_CC_EXTRA=(-g0) ;;
    osx-*)
        if is_cross; then
          _WRAPPER_OSX_LIBC_TXT="${WRAPPER_OBJDIR}/osx-cross-libc.txt"
          cat > "${_WRAPPER_OSX_LIBC_TXT}" <<EOF
include_dir=${PREFIX}/lib/zig/libc/include/any-macos-any
sys_include_dir=${PREFIX}/lib/zig/libc/include/any-macos-any
crt_dir=
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF
          _WRAPPER_CC_EXTRA=(--target="${ZIG_TRIPLET}" --libc "${_WRAPPER_OSX_LIBC_TXT}")
        fi
        ;;
esac

# macOS: bin/zig references zig-llvm dylibs via @loader_path/<name> (inherited from
# libclang-cpp.dylib's LC_ID, zig-llvm post-install.sh), which resolve next to bin/
# where they are absent. Rewrite to @loader_path/../lib/zig-llvm/lib/<name> BEFORE
# bin/zig is invoked below to compile the wrapper. Mirrors the zig-real block further
# down, but at ../lib depth (not ../../lib) since bin/ is one level shallower than
# share/zig/. Verify-gated.
if is_osx; then
  _zig_bin="${PREFIX}/bin/zig"
  _zig_llvm_rel="@loader_path/../lib/zig-llvm/lib"
  echo "=== Fixing zig binary dylib refs to @loader_path (macOS, pre-wrapper) ==="
  while IFS= read -r _dep_line; do
    _dep=$(echo "${_dep_line}" | awk '{print $1}')
    _dep_base=$(basename "${_dep}")
    case "${_dep_base}" in
      libLLVM*|libclang*|libc++*|libunwind*|liblldZig*)
        _new="${_zig_llvm_rel}/${_dep_base}"
        if [[ "${_dep}" != "${_new}" ]] && { [[ -f "${PREFIX}/lib/zig-llvm/lib/${_dep_base}" ]] || [[ -L "${PREFIX}/lib/zig-llvm/lib/${_dep_base}" ]]; }; then
          install_name_tool -change "${_dep}" "${_new}" "${_zig_bin}"
          echo "  ${_dep} -> ${_new}"
        fi
        ;;
    esac
  done < <(otool -L "${_zig_bin}" 2>/dev/null | tail -n +2)

  echo "=== Verifying zig binary dylib isolation (macOS, pre-wrapper) ==="
  _bad_refs=$(otool -L "${_zig_bin}" 2>/dev/null | awk '{print $1}' | grep -E '(libLLVM|libclang|libc\+\+|libunwind|liblldZig)' | grep -v '@loader_path/\.\./lib/zig-llvm/lib/' || true)
  if [[ -n "${_bad_refs}" ]]; then
    echo "ERROR: bin/zig still has non-isolated refs to zig-llvm libraries:" >&2
    echo "${_bad_refs}" | sed 's/^/  /' >&2
    exit 1
  fi
fi

# Non-fatal diagnostic: confirm whether zig's bundled libc headers landed on
# disk for osx cross builds. Never allowed to fail the build.
if is_osx && is_cross; then
  echo "=== osx cross libc header diagnostic ===" || true
  ls -la "${PREFIX}/lib/zig" 2>/dev/null || true
  ls -la "${PREFIX}/lib/zig/libc" 2>/dev/null || true
  ls -la "${PREFIX}/lib/zig/libc/include" 2>/dev/null || true
  if [[ -f "${PREFIX}/lib/zig/libc/include/any-macos-any/stdio.h" ]]; then
    echo "  FOUND: any-macos-any/stdio.h present" || true
  else
    echo "  MISSING: any-macos-any/stdio.h not present" || true
  fi
  ls -la "${PREFIX}/share/zig" 2>/dev/null || true
fi

# Compile wrapper using the just-built zig
PRIMARY_WRAPPER="${WRAPPER_BIN_DIR}/${CONDA_TRIPLET}-zig${EXE_EXT}"
"${PREFIX}/bin/zig" cc -O2 "${_WRAPPER_CC_EXTRA[@]}" ${WRAPPER_LDFLAGS} -iquote "${RECIPE_DIR}/building" "${WRAPPER_C}" -o "${PRIMARY_WRAPPER}"

# Cross-arch wrapper detection note for downstream consumers:
# All Windows variant wrappers (x86_64-w64-mingw32-zig.exe,
# aarch64-w64-mingw32-zig.exe, i686-w64-mingw32-zig.exe) land in the SAME
# ${PREFIX}/Library/bin directory when multiple zig_<cross-target> activation
# packages are stacked in a build environment. Consumer recipes probing for
# compiler presence by filename alone (e.g.,
#   test -x .../aarch64-w64-mingw32-zig.exe
# ) will FALSE-POSITIVE on an x86_64 host: the file exists but is an
# x86_64-PE executable and cannot natively run aarch64 code. Consumers MUST
# disambiguate by either:
#   (a) inspecting the PE machine header (file, objdump -f, dumpbin /headers)
#   (b) actually invoking the wrapper and checking exit status / output
# See P-5 in zig_cc_consumer_pain_points.md.

# Install ergonomic-name copies (canonical suffix list at
# ${RECIPE_DIR}/building/wrapper_modes.txt).
# Portable: simple file redirect, inline filter, CRLF strip — works in
# m2-bash 3.1 (no mapfile, no process substitution) and tolerates files
# checked out with CRLF line endings on Windows.
while IFS= read -r suffix || [ -n "${suffix}" ]; do
    suffix="${suffix%$'\r'}"
    case "${suffix}" in
        ''|'#'*) continue ;;
    esac
    cp -f "${PRIMARY_WRAPPER}" "${WRAPPER_BIN_DIR}/${CONDA_TRIPLET}-zig-${suffix}${EXE_EXT}"
done < "${RECIPE_DIR}/building/wrapper_modes.txt"

# Install wrapper_modes.txt for runtime self-test (A4)
case "${target_platform}" in
    win-*) SHARE_DIR="${PREFIX}/Library/share/zig-wrapper" ;;
    *)     SHARE_DIR="${PREFIX}/share/zig-wrapper" ;;
esac
mkdir -p "${SHARE_DIR}"
cp "${RECIPE_DIR}/building/wrapper_modes.txt" "${SHARE_DIR}/wrapper_modes.txt"

# zig's PE/COFF link can still emit a .pdb sidecar named after the output;
# it is not needed for the wrapper and trips package_contents strict checks.
case "${target_platform}" in
    win-*) rm -f "${WRAPPER_BIN_DIR}"/*.pdb "${PREFIX}/bin/zig.pdb" ;;
esac

# Move raw zig out of PATH
mv "${PREFIX}/bin/zig" "${REAL_ZIG_DIR}/${REAL_ZIG_NAME}"

# macOS: rewrite the real zig binary's dylib references to @loader_path so it
# loads zig-llvm's dylibs (not conda-forge copies in ${PREFIX}/lib/). zig-real
# now lives at ${PREFIX}/share/zig/zig-real and zig-llvm is at
# ${PREFIX}/lib/zig-llvm/lib, so from share/zig/ the relative path is
# @loader_path/../../lib/zig-llvm/lib (one level deeper than zig-zig's bin/ case
# because of the wrapper/zig-real split). Verify-gated.
if is_osx; then
  _zig_real="${REAL_ZIG_DIR}/${REAL_ZIG_NAME}"
  _zig_llvm_rel="@loader_path/../../lib/zig-llvm/lib"
  echo "=== Fixing zig-real dylib refs to @loader_path (macOS) ==="
  while IFS= read -r _dep_line; do
    _dep=$(echo "${_dep_line}" | awk '{print $1}')
    _dep_base=$(basename "${_dep}")
    case "${_dep_base}" in
      libLLVM*|libclang*|libc++*|libunwind*|liblldZig*)
        _new="${_zig_llvm_rel}/${_dep_base}"
        if [[ "${_dep}" != "${_new}" ]] && { [[ -f "${PREFIX}/lib/zig-llvm/lib/${_dep_base}" ]] || [[ -L "${PREFIX}/lib/zig-llvm/lib/${_dep_base}" ]]; }; then
          install_name_tool -change "${_dep}" "${_new}" "${_zig_real}"
          echo "  ${_dep} -> ${_new}"
        fi
        ;;
    esac
  done < <(otool -L "${_zig_real}" 2>/dev/null | tail -n +2)

  echo "=== Verifying zig-real dylib isolation (macOS) ==="
  _bad_refs=$(otool -L "${_zig_real}" 2>/dev/null | awk '{print $1}' | grep -E '(libLLVM|libclang|libc\+\+|libunwind|liblldZig)' | grep -v '@loader_path/\.\./\.\./lib/zig-llvm/lib/' || true)
  if [[ -n "${_bad_refs}" ]]; then
    echo "ERROR: zig-real still has non-isolated refs to zig-llvm libraries:" >&2
    echo "${_bad_refs}" | sed 's/^/  /' >&2
    exit 1
  fi
  echo "  OK: all zig-llvm refs use @loader_path/../../lib/zig-llvm/lib"
fi

# Linux analog of the macOS re-fix above: zig-real was moved from bin/ to share/zig/
# (two levels deeper), so re-base its $ORIGIN-relative rpath. From share/zig/,
# $ORIGIN/../../lib reaches $PREFIX/lib and $ORIGIN/../../lib/zig-llvm/lib reaches the
# dynamic zig-llvm libs. The bin/zig rpath set before the move is stale for this binary;
# testing/test_dtneeded.py invokes zig-real directly (the wrapper execs it unchanged).
if is_linux; then
  patchelf --set-rpath '$ORIGIN/../../lib:$ORIGIN/../../lib/zig-llvm/lib' "${REAL_ZIG_DIR}/${REAL_ZIG_NAME}"
fi

# === end Phase 2 ===

# Non-unix conda convention: artifacts go under Library/
if is_not_unix; then
  mkdir -p "${PREFIX}/Library/lib" "${PREFIX}/Library/doc"
  mv "${PREFIX}"/lib/zig "${PREFIX}"/Library/lib/zig
  [[ -d "${PREFIX}/doc" ]] && mv "${PREFIX}"/doc/* "${PREFIX}"/Library/doc/
fi

# MinGW import lib pre-generation (Windows targets only)
source "${RECIPE_DIR}/building/_mingw.sh"
generate_mingw_import_libs

dbg echo "=== Build installed for package: ${PKG_NAME} ==="

# ZIG_USE_CACHE trinary semantics (intentional):
#   unset / empty → no cache action (CI default)
#   "0"           → save current build artifacts into cache
#   "1"           → attempt restore from cache; build normally and save on miss
#   any other     → no-op (filters garbage values silently)
# Cache successful build (saves before rattler-build cleanup)
if [[ "${ZIG_USE_CACHE:-}" == "0" || "${ZIG_USE_CACHE:-}" == "1" ]] && [[ -f "${RECIPE_DIR}/local-scripts/stub_cache.sh" ]]; then
  # stub_cache.sh already sourced at the top if ZIG_USE_CACHE=1
  [[ "$(type -t stub_cache_save)" != "function" ]] && source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
  stub_cache_save
  dbg echo "=== Build cached for future restoration ==="
fi

