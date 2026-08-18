#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# --- Functions ---

source "${RECIPE_DIR}/building/_common.sh"
source "${RECIPE_DIR}/building/_diag.sh"   # diag_phase/diag_fail/diag_ok/diag_report (accumulator, not yet gated)
source "${RECIPE_DIR}/building/_build.sh"  # configure_cmake_zigcpp, build_zig_with_zig

# --- Early exits ---

[[ -z "${CONDA_TRIPLET:-}" ]] && { echo "CONDA_TRIPLET must be specified in recipe.yaml env"; exit 1; }
[[ -z "${CONDA_ZIG_BUILD:-}" ]] && { echo "CONDA_ZIG_BUILD undefined, use zig_<arch> instead of _impl"; exit 1; }
[[ -z "${ZIG_TRIPLET:-}" ]] && { echo "ZIG_TRIPLET must be specified in recipe.yaml env"; exit 1; }

export ZIG_QEMU_ARCH="${ZIG_TRIPLET%%-*}"

# --- Main ---

# Bootstrap selection (build_number == 0 only: no-op otherwise)
source "${RECIPE_DIR}/building/_upstream_bootstrap.sh"
setup_upstream_zig_bootstrap

# Bootstrap zig runs on the build machine — always use CONDA_ZIG_BUILD
BUILD_ZIG="${CONDA_ZIG_BUILD}"

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

# Patch build.zig-02-doctest-forward-target adds -Ddoctest-target to build.zig.
# Gated to linux/osx where the patch applies and where doctest target forwarding matters.
if is_unix; then
  EXTRA_ZIG_ARGS+=(-Ddoctest-target=${ZIG_TRIPLET})
fi

# --- ppc64le R_PPC64_REL24 mitigation (defense in depth) ---
# Bundle approach: build libLLD and libzigcpp as separate .so files to split
# the 24-bit branch relocation domain across multiple PLT sections.
# Combined with cmake patch 0005 (-mlongcall via target_compile_options),
# this prevents R_PPC64_REL24 overflow when linking the full zig2 binary.
if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  export CFLAGS="${CFLAGS:-} -mlongcall -mcmodel=large -fno-partial-inlining -fno-ipa-cp-clone"
  export CXXFLAGS="${CXXFLAGS:-} -mlongcall -mcmodel=large -fno-partial-inlining -fno-ipa-cp-clone"
  export LDFLAGS="${LDFLAGS:-} -Wl,--stub-group-size=0"
  export NINJA_FLAGS="-v"
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_C_FLAGS="${CFLAGS}"
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}"
    -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}"
    -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}"
    -DCMAKE_C_COMPILER_WORKS=TRUE
    -DCMAKE_CXX_COMPILER_WORKS=TRUE
  )
  # Use PREFIX/lib here (not ZIG_LOCAL_CACHE_DIR): these paths are baked into
  # the zig binary's DT_NEEDED at link time. conda-build's patchelf/prefix
  # replacement then rewrites PREFIX to the install location correctly.
  # The lld bundle is installed to PREFIX/lib/ (before zig2 link).
  EXTRA_CMAKE_ARGS+=(
    -DZIG_LLD_BUNDLE_SO="${PREFIX}/lib/libzig-lld-bundle.so"
  )
elif [[ "${target_platform}" == "linux-64" || "${target_platform}" == "linux-aarch64" ]]; then
  # Link zig against zig-llvm-16's already-built liblldZig.so bundle instead of
  # the raw liblld*.a archives (zig-llvm-16/building/remove-unneeded.sh deletes
  # those immediately on these platforms — no need to rebuild a bundle here,
  # unlike linux-ppc64le which needs a -mlongcall relink).
  EXTRA_CMAKE_ARGS+=(
    -DZIG_LLD_BUNDLE_SO="${PREFIX}/lib/zig-llvm/lib/liblldZig.so"
  )
fi

# Strip host-arch flags injected by conda-build for cross builds.
# Safe for ppc64le/aarch64: intentional target-arch flags (e.g. -mlongcall,
# -march=armv8-a) are added in target-specific blocks elsewhere and don't
# match the sanitize filter for their own arch family.
if is_cross; then
  sanitize_and_export_cross_flags
fi

# Two-phase langref strategy: Phase 1 (here) ALWAYS skips langref HTML installation;
# Phase 2 (zig build langref) handles it separately when stage3 is runnable.
EXTRA_ZIG_ARGS+=(-Dno-langref)

if is_osx; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SYSTEM_LIBCXX=c++
    -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
    -DZIG_LLD_BUNDLE_SO="${PREFIX}/lib/zig-llvm/lib/liblldZig.dylib"
  )
  EXTRA_ZIG_ARGS+=(--maxrss 8589934592)
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SYSTEM_LIBCXX=c++)
  EXTRA_ZIG_ARGS+=(--maxrss 7800000000)
fi

if is_not_unix; then
  EXTRA_CMAKE_ARGS+=(
    # DLL-only LLVM on Windows (LLVM_BUILD_LLVM_DYLIB=ON; static .a removed by
    # zig-llvm/building/remove-unneeded.sh), so zig must link LLVM as a SHARED
    # library, same as unix. ZIG_SHARED_LLVM=OFF made zig's cmake/Findllvm.cmake
    # take the static path (llvm-config --libs), which returns empty because the
    # static archives are gone, crashing Findllvm.cmake at
    # `if(${LLVM_LINK_MODE} STREQUAL "shared")` (PR #123 win-64 CI, 2026-08-03).
    -DZIG_SHARED_LLVM=ON
    # Force dynamic CRT (/MD) for zigcpp objects so their /DEFAULTLIB
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
  )
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SHARED_LLVM=ON)
fi

# Embed PREFIX/lib RPATH at install time so binaries resolve libclang/libLLVM at runtime
if is_unix; then
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_INSTALL_RPATH="${PREFIX}/lib"
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
  )
fi

# Composed, not inherited: this recipe has no gcc dep, so the conda-forge
# compiler package that would normally export a sysroot variable is absent
# by design. ZIG_SYSROOT_SUBPATH comes from recipe.yaml's env: (prefix-
# relative, e.g. /riscv64-conda-linux-gnu/sysroot; empty on non-linux).
if [[ -n "${ZIG_SYSROOT_SUBPATH:-}" ]]; then
  export ZIG_SYSROOT="${BUILD_PREFIX}${ZIG_SYSROOT_SUBPATH}"
else
  export ZIG_SYSROOT="${BUILD_PREFIX}/${CONDA_TRIPLET}/sysroot"
fi

if is_linux && is_cross; then
  # CI run 31321865432 (linux-aarch64 cross, build_zig_with_zig):
  # `ld.lld: cannot open /lib64/libm.so.6: No such file or directory`.
  # Root cause: glibc >= 2.34 ships usr/lib64/libm.so as a GNU ld script
  # (GROUP/AS_NEEDED referencing /lib64/libm.so.6, /lib64/libmvec.so.1,
  # etc. as bare-absolute paths) -- the exact same class of bug already
  # documented below for riscv64's libc.so, just a different member of
  # the {libc,libpthread,libm,librt,libdl} script family and not gated
  # to one arch: it depends only on the sysroot's glibc version, so any
  # cross target (aarch64, ppc64le, riscv64, s390x) can hit it. Rewrite
  # the absolute paths in-place to sysroot-relative ones (preserves
  # GROUP/AS_NEEDED structure, unlike a symlink replacement) instead of
  # special-casing one library/arch. Idempotent and a no-op for any
  # library that is a real file/symlink rather than a linker script.
  # Was previously wired only into the debug-only build_native.sh path
  # (_sysroot_fix.sh); this is the first time it runs in the real CI
  # cross-build.
  source "${RECIPE_DIR}/building/_sysroot_fix.sh"
  fix_sysroot_libc_scripts "${BUILD_PREFIX}"

  # Ground-truthed via PR #123 run #728 DIAGNOSTIC: sysroot_linux-riscv64
  # ships libc.so/libc.so.6 flat under lib64/, no lp64d multilib subdir.
  # A prior CI round wrongly assumed an lp64d subdir here; use the plain
  # lib64 default like every other cross-linux target.
  #
  # PR #123 run aee3ccc6/90766634454: even with the plain lib64 path above,
  # `ld.lld: cannot open /lib64/lp64d/libc.so.6` still recurs. Root cause:
  # zig's OWN build system unconditionally appends "/lp64d" internally when
  # constructing libc-runtime paths for the riscv64-linux-gnu default ABI
  # (a Debian/Ubuntu multilib convention zig assumes), regardless of the
  # path string we pass via --libc-runtimes. conda-forge's sysroot is flat
  # (no lp64d subdir), so zig's self-appended path never resolves. Fix: a
  # self-referential symlink lib64/lp64d -> "." so any path zig builds as
  # lib64/lp64d/<file> transparently resolves back to the real flat
  # lib64/<file> through the symlink. riscv64-only: no other cross target
  # has this zig-internal lp64d assumption.
  if [[ "${target_platform}" == "linux-riscv64" ]] \
     && [[ -d "${ZIG_SYSROOT}/lib64" ]] \
     && [[ ! -e "${ZIG_SYSROOT}/lib64/lp64d" ]]; then
    ln -sf . "${ZIG_SYSROOT}/lib64/lp64d"
  fi
  # REMOVED (PR #17, run 31614917304). This block used to replace the riscv64
  # sysroot's usr/lib/libc.so GNU-ld script with a symlink, to work
  # around ld.lld resolving the script's bare-absolute GROUP() operands
  # against / (zig's link step passes no --sysroot).
  #
  # fix_sysroot_libc_scripts() above (_sysroot_fix.sh) ALREADY handles exactly
  # that: its sed rewrites those operands to sysroot-absolute, including the
  # `s| /lib/ld-|` rule that keeps AS_NEEDED(ld-linux-riscv64-lp64d.so.1)
  # resolvable. The old symlink then ran AFTER that rewrite and threw the whole
  # script away, taking the AS_NEEDED loader entry with it. __tls_get_addr is
  # defined ONLY in the dynamic loader, never in libc.so.6, so every langref
  # doctest link failed with `ld.lld: undefined symbol: __tls_get_addr`
  # (referenced from debug.defaultPanic). The ZIG_LLVM_LIBRARIES perl edit
  # further down diagnosed this but only patched the zig binary's own link via
  # config.h -- it never reached the doctest sub-compiles. Do not re-add.
  _libc_runtimes_dir="${ZIG_SYSROOT}"/lib64
  EXTRA_ZIG_ARGS+=(
    --libc "${zig_build_dir}"/libc_file
    --libc-runtimes "${_libc_runtimes_dir}"
  )
  # Preserved (not unset) for Phase 2 below: build.zig-02-doctest-forward-target.patch's
  # -Ddoctest-libc option threads this same value into the langref doctest sub-compiles,
  # mirroring what Phase 1 just received via EXTRA_ZIG_ARGS above (--libc). Only set for
  # is_linux && is_cross (this block), same gating Phase 2 relies on. --libc-runtimes is
  # NOT forwarded to doctest: it is a zig-build-frontend-only concept (Step.Run's qemu
  # sysroot injection), never accepted by build-exe/test's CLI parser (src/main.zig).
  ZIG_DOCTEST_LIBC_FILE="${zig_build_dir}/libc_file"
  unset _libc_runtimes_dir
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

# the extra lib search path that build.zig consumes via ZIG_EXTRA_LIBDIR
# (patch riscv64/build.zig-riscv64-lp64d-libpath.patch). Export it here too so
# native riscv64 gets the same lib search path as the cross jobs. Plain
# lib64, not an lp64d multilib subdir -- ground-truthed via PR #123 run #728
# (see recipe/building/build-zig.sh's cross-block comment above).
if is_linux && ! is_cross && [[ "${target_platform}" == "linux-riscv64" ]]; then
  # Same zig-internal lp64d assumption applies to native riscv64 builds
  # (see the cross-block comment above for the full root cause); mirror
  # the self-referential symlink here so it resolves identically.
  if [[ -d "${ZIG_SYSROOT}/lib64" ]] \
     && [[ ! -e "${ZIG_SYSROOT}/lib64/lp64d" ]]; then
    ln -sf . "${ZIG_SYSROOT}/lib64/lp64d"
  fi
  # REMOVED (PR #17) for the same reason as the cross block above: it discarded
  # AS_NEEDED(ld-linux-riscv64-lp64d.so.1) and broke __tls_get_addr resolution.
  # build_native.sh calls fix_sysroot_libc_scripts "${ENV_DIR}", which rewrites
  # the script's GROUP() operands correctly instead. Do not re-add.
  export ZIG_EXTRA_LIBDIR="${ZIG_SYSROOT}"/lib64
fi

# --- libzigcpp Configuration ---

if is_linux; then
  source "${RECIPE_DIR}/building/_libc_tuning.sh"
  create_gcc14_glibc28_compat_lib
fi

# zig-cc wrapper for the glibc-compat stub helpers below (_glibc217_syscall_stubs.sh,
# _atfork.sh). This output's build deps use ${{ stdlib('c') }}, not compiler('c'), so
# rattler-build never activates a gcc_impl/compiler package and CC is left unexported
# (previously crashed under `set -u`: "CC: unbound variable"). Route these small stub
# compiles through zig's own `zig cc` instead of a real gcc/clang dependency -- this
# project always compiles C through the zig cc wrapper. A tiny exec shim (not an
# array) is required because both helper files below invoke the compiler as a single
# quoted command word: "${cc_compiler}" -c file.c -o out.o -- an array expanded with
# "${ZIG_CC[@]}" would not fit that call signature without editing every call site
# and both helper bodies.
if is_linux; then
  ZIG_CC_STUB_WRAPPER="${ZIG_LOCAL_CACHE_DIR}/zig-cc-stub-wrapper.sh"
  cat > "${ZIG_CC_STUB_WRAPPER}" << EOF
#!/usr/bin/env bash
# -print-file-name= is answered by filesystem probe, bypassing zig's clang-driver
# -target parsing entirely (avoids "version '.2.39' in target triple
# 'x86_64-unknown-linux-gnu.2.39' is invalid" -- the driver normalizes our 3-component
# ZIG_TRIPLET to 4 components, vendor 'unknown', and then chokes on the fused glibc
# suffix). Ported from conda-forge/zig-feedstock recipe/building/_translate.gen.sh
# rule R3. Probe order: zig-llvm/lib first (where libc++.so actually lives), then lib.
for _a in "\$@"; do
  case "\$_a" in
    -print-file-name=*)
      _name="\${_a#-print-file-name=}"
      for _dir in "${PREFIX}/lib/zig-llvm/lib" "${PREFIX}/lib"; do
        if [[ -e "\${_dir}/\${_name}" ]]; then echo "\${_dir}/\${_name}"; exit 0; fi
      done
      echo "\${_name}"; exit 0
      ;;
  esac
done
# Drop flags zig's clang driver hard-errors on ("Unknown Clang option") but that
# reach this wrapper via CMAKE_C_FLAGS/CXXFLAGS/LDFLAGS on linux-ppc64le
# (build-zig.sh's -mlongcall block above); mirrors _zig-cc-common.sh:161's filter.
_filtered=()
for _a in "\$@"; do
  case "\$_a" in
    -fno-partial-inlining|-fno-ipa-cp-clone|-fno-ipa-cp) ;;
    -Wl,--stub-group-size=*|--stub-group-size=*) ;;
    *) _filtered+=("\$_a") ;;
  esac
done
exec "${BUILD_ZIG}" cc -target "${ZIG_TRIPLET}" "\${_filtered[@]}"
EOF
  chmod +x "${ZIG_CC_STUB_WRAPPER}"
fi

# Same rationale as the CC stub above, for the C++ side: build_lld_bundle_ppc64le
# (below, _lld_bundle.sh) invokes its compiler argument as a single quoted command
# word ("${cxx_compiler}" -shared ...), same calling convention as the CC helpers,
# so a tiny exec shim (not an array) is required here too.
if is_linux; then
  ZIG_CXX_STUB_WRAPPER="${ZIG_LOCAL_CACHE_DIR}/zig-cxx-stub-wrapper.sh"
  cat > "${ZIG_CXX_STUB_WRAPPER}" << EOF
#!/usr/bin/env bash
# -print-file-name= is answered by filesystem probe, bypassing zig's clang-driver
# -target parsing entirely (avoids "version '.2.39' in target triple
# 'x86_64-unknown-linux-gnu.2.39' is invalid" -- the driver normalizes our 3-component
# ZIG_TRIPLET to 4 components, vendor 'unknown', and then chokes on the fused glibc
# suffix). Ported from conda-forge/zig-feedstock recipe/building/_translate.gen.sh
# rule R3. Probe order: zig-llvm/lib first (where libc++.so actually lives), then lib.
for _a in "\$@"; do
  case "\$_a" in
    -print-file-name=*)
      _name="\${_a#-print-file-name=}"
      for _dir in "${PREFIX}/lib/zig-llvm/lib" "${PREFIX}/lib"; do
        if [[ -e "\${_dir}/\${_name}" ]]; then echo "\${_dir}/\${_name}"; exit 0; fi
      done
      echo "\${_name}"; exit 0
      ;;
  esac
done
# Drop flags zig's clang driver hard-errors on ("Unknown Clang option") but that
# reach this wrapper via CMAKE_C_FLAGS/CXXFLAGS/LDFLAGS on linux-ppc64le
# (build-zig.sh's -mlongcall block above); mirrors _zig-cc-common.sh:161's filter.
_filtered=()
for _a in "\$@"; do
  case "\$_a" in
    -fno-partial-inlining|-fno-ipa-cp-clone|-fno-ipa-cp) ;;
    -Wl,--stub-group-size=*|--stub-group-size=*) ;;
    *) _filtered+=("\$_a") ;;
  esac
done
exec "${BUILD_ZIG}" c++ -target "${ZIG_TRIPLET}" "\${_filtered[@]}"
EOF
  chmod +x "${ZIG_CXX_STUB_WRAPPER}"
fi

# Pin zigcpp's CMake configure (configure_cmake_zigcpp, invoked below) to the zig-cc
# stub wrappers just created above, instead of letting CMake auto-detect the CI
# runner's ambient system GCC. Root cause (PR #17, verified from full CI job log):
# without this, zigcpp/*.cpp compiles against the runner's libstdc++, emitting
# cxx11-dual-ABI symbols that zig-llvm's libLLVM/libclang-cpp (built via zig-cc
# against libc++, no [abi:cxx11] tags) never define, so the final self-hosted zig
# link fails with dozens of undefined-symbol errors. Never add compiler('c')/
# compiler('cxx') or a real gcc/clang dep here -- always route through zig's own
# cc/c++ wrappers (project bright-line rule). linux-only: these are the only
# platforms with ZIG_CC_STUB_WRAPPER/ZIG_CXX_STUB_WRAPPER defined; osx/win zigcpp
# configures do not currently pin a compiler either (no existing pattern to match).
if is_linux; then
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_C_COMPILER="${ZIG_CC_STUB_WRAPPER}"
    -DCMAKE_CXX_COMPILER="${ZIG_CXX_STUB_WRAPPER}"
  )
elif is_not_unix; then
  # win-64/win-arm64: same ABI-consistency requirement as linux above, different
  # mechanism. With no pin, CMake auto-detects MSVC and builds zigcpp.lib with it;
  # those objects carry /DEFAULTLIB:MSVCRT, OLDNAMES and msvcprt directives, and the
  # final `zig build-exe -target x86_64-windows-gnu` resolves them the gnu way:
  #   error: lld-link: could not open 'libmsvcprt.a': no such file or directory
  #   error: lld-link: could not open 'libMSVCRT.a':  no such file or directory
  #   error: lld-link: could not open 'libOLDNAMES.a': no such file or directory
  # (PR #17 run 31614917304 job 94226523362 lines 1083-1086; byte-identical in the
  # earlier job 93962966644, so this predates the 0.16.0 work.)
  #
  # The linux stub wrappers above are .sh and cannot serve as CMAKE_C_COMPILER on
  # Windows, and CMake requires a single executable -- `zig cc` as two words does
  # not work. These triple-prefixed .exe wrappers normally ship pre-built from the
  # zig_${{ cross_target_platform_ }} output (install_zig_activation.py's
  # _compile_c_shim(), compiling building/zig-cc-nonunix.c) -- but that output
  # pin_subpackages zig_impl_ with exact=True and is NOT a zig_impl_ build
  # dependency (adding one would be a cycle: it builds AFTER and FROM zig_impl_),
  # so it can never be present at this point. CI run 31720942719 confirmed this on
  # BOTH windows lanes (win-64 native job 94517681073, win-arm64 cross job
  # 94517680964): `ls -1` of BUILD_PREFIX/Library/bin (352 entries) contained no
  # *-zig-cc*/*-zig-cxx* at all, only the plain ${CONDA_ZIG_BUILD}.exe. Self-generate
  # the shims here instead, mirroring the dependency-free linux
  # ZIG_CC_STUB_WRAPPER/ZIG_CXX_STUB_WRAPPER pattern above: same source
  # (zig-cc-nonunix.c), same compile recipe and @PLACEHOLDER@ set as
  # _compile_c_shim()/install_zig_cc_wrappers() use, just run locally instead of
  # consuming a pre-built package. BUILD_PREFIX carries backslashes on Windows, so
  # normalize before composing paths.
  _bp_fwd="${BUILD_PREFIX//\\//}"

  # BUILD_ZIG is a bare command name (build_triplet-zig), not a path -- resolve via
  # PATH first, same fallback idiom as _mingw.sh:88-96.
  _win_build_zig_path="$(command -v "${BUILD_ZIG}" 2>/dev/null || true)"
  if [[ -z "${_win_build_zig_path}" ]]; then
    _win_build_zig_path="${_bp_fwd}/Library/bin/${BUILD_ZIG}"
  fi

  _win_zig_cc="${ZIG_LOCAL_CACHE_DIR}/${CONDA_TRIPLET}-zig-cc.exe"
  _win_zig_cxx="${ZIG_LOCAL_CACHE_DIR}/${CONDA_TRIPLET}-zig-cxx.exe"
  _win_shim_src="${RECIPE_DIR}/building/zig-cc-nonunix.c"
  _win_shim_log="${ZIG_LOCAL_CACHE_DIR}/win-cc-shim-compile.log"
  mkdir -p "${ZIG_LOCAL_CACHE_DIR}"
  : > "${_win_shim_log}"

  # find_zig() inside the compiled shim resolves the real zig binary at ITS OWN
  # (later) runtime via getenv("CONDA_PREFIX") + "\Library\bin\" + ZIG_BIN_NAME
  # (building/zig-cc-nonunix.c:170-178) -- the same lookup the shipped, install-time
  # shim uses. build-zig.sh never otherwise sets CONDA_PREFIX, so point it at
  # BUILD_PREFIX (where BUILD_ZIG actually lives) for the rest of this script.
  export CONDA_PREFIX="${_bp_fwd}"

  _win_compile_shim() {
    # $1=ZIG_CC_MODE (cc|c++)  $2=tmp source filename tag  $3=output .exe path
    local _mode="$1" _tag="$2" _dst="$3" _src_copy
    _src_copy="${ZIG_LOCAL_CACHE_DIR}/zig-${_tag}-nonunix.c"
    sed \
      -e "s/@ZIG_CC_MODE@/${_mode}/g" \
      -e "s/@ZIG_BIN_NAME@/${BUILD_ZIG}.exe/g" \
      -e "s/@ZIG_TARGET@/${ZIG_TRIPLET}/g" \
      -e "s/@ZIG_TARGET_ARCH@/${ZIG_TRIPLET%%-*}/g" \
      -e "s/@IS_MINGW_TARGET@/1/g" \
      "${_win_shim_src}" > "${_src_copy}"
    "${_win_build_zig_path}" cc -O2 -I"${_win_shim_src%/*}" -o "${_dst}" "${_src_copy}" -lkernel32
  }

  if ! { _win_compile_shim cc cc "${_win_zig_cc}" \
      && _win_compile_shim c++ cxx "${_win_zig_cxx}"; } >>"${_win_shim_log}" 2>&1 \
     || [[ ! -x "${_win_zig_cc}" ]] || [[ ! -x "${_win_zig_cxx}" ]]; then
    # Fail loudly and early. Falling through to CMake's auto-detection is what
    # produced the MSVC/gnu ABI split in the first place, and it only surfaces
    # ~10 minutes later at the final link.
    echo "FATAL: failed to self-compile zig-cc/zig-cxx shims, cannot pin zigcpp compiler:" >&2
    echo "         compiler used: ${_win_build_zig_path}" >&2
    echo "         ${_win_zig_cc}" >&2
    echo "         ${_win_zig_cxx}" >&2
    echo "       compile log:" >&2
    sed 's/^/         /' "${_win_shim_log}" >&2
    echo "       contents of ${_bp_fwd}/Library/bin:" >&2
    ls -1 "${_bp_fwd}/Library/bin" 2>&1 | sed 's/^/         /' >&2
    exit 1
  fi
  # COMPILER_FORCED (below) skips CMake's own compiler-identification probe,
  # which is also what normally populates CMAKE_<LANG>_COMPILER_VERSION. Left
  # unset, target_compile_features() dies with an empty "version ." error
  # (CMakeLists.txt:489; PR #17 CI run 31839606806 job 94893570540). Derive the
  # real version from the shim we just compiled -- it wraps zig's clang driver
  # -- same "clang version" banner probe used by
  # zig-llvm/zig-zig-llvm building/_zig_wrappers.sh.
  _win_clang_version_banner="$("${_win_zig_cc}" --version 2>&1 || true)"
  _win_clang_version="$(printf '%s\n' "${_win_clang_version_banner}" | grep -oE 'clang version [0-9]+\.[0-9]+\.[0-9]+' | head -n1 | awk '{print $3}')"
  if [[ -z "${_win_clang_version}" ]]; then
    echo "FATAL: could not determine clang version from '${_win_zig_cc} --version' output, cannot pin CMAKE_C_COMPILER_VERSION/CMAKE_CXX_COMPILER_VERSION:" >&2
    echo "         ${_win_clang_version_banner}" >&2
    exit 1
  fi
  # Pre-seed the CMake cache so CMake skips its compiler test-compile: it emits
  # MSVC-style link args that zig's driver rejects. COMPILER_FORCED is the
  # documented switch for "trust me, skip the ABI/works checks". The -target flags
  # force windows-gnu rather than the native windows-msvc default -- otherwise
  # _MSC_VER is defined and zig.h reaches for MSVC intrinsics (_InterlockedOr64).
  _win_cache_seed="${SRC_DIR}/zigcpp-win-cache.cmake"
  cat > "${_win_cache_seed}" << WCEOF
set(CMAKE_C_COMPILER_ID "Clang" CACHE STRING "")
set(CMAKE_CXX_COMPILER_ID "Clang" CACHE STRING "")
set(CMAKE_C_COMPILER_FORCED TRUE CACHE BOOL "")
set(CMAKE_CXX_COMPILER_FORCED TRUE CACHE BOOL "")
set(CMAKE_C_COMPILER_VERSION "${_win_clang_version}" CACHE STRING "")
set(CMAKE_CXX_COMPILER_VERSION "${_win_clang_version}" CACHE STRING "")
set(CMAKE_C_FLAGS "-target ${ZIG_TRIPLET}" CACHE STRING "")
set(CMAKE_CXX_FLAGS "-target ${ZIG_TRIPLET}" CACHE STRING "")
# COMPILER_FORCED above suppresses CMake's own compiler-standard detection, so
# CMAKE_<LANG>_STANDARD/EXTENSIONS_COMPUTED_DEFAULT are never computed; but
# find_package(Threads)'s TryCompile subproject re-runs project() and hard-
# requires them (CMakeCommonCompilerMacros.cmake:42: "CMAKE_C_STANDARD_COMPUTED_
# DEFAULT and CMAKE_C_EXTENSIONS_COMPUTED_DEFAULT should be set for Clang"; CI
# run 31912407764 job 95079442716). Seed clang 21's real defaults (gnu17/gnu++17).
set(CMAKE_C_STANDARD_COMPUTED_DEFAULT "17" CACHE STRING "")
set(CMAKE_C_EXTENSIONS_COMPUTED_DEFAULT "ON" CACHE STRING "")
set(CMAKE_CXX_STANDARD_COMPUTED_DEFAULT "17" CACHE STRING "")
set(CMAKE_CXX_EXTENSIONS_COMPUTED_DEFAULT "ON" CACHE STRING "")
# COMPILER_FORCED also suppresses Modules/Compiler/Clang-CXX.cmake, which is what
# normally populates CMAKE_<LANG>_COMPILE_FEATURES. zig's CMakeLists.txt:487 calls
# target_compile_features(zigcpp PRIVATE cxx_std_17), and with an empty feature
# table CMake fails "no known features for CXX compiler Clang version 21.1.8"
# (run 31976828144, jobs 95237537846 win-64 / 95237537840 win-arm64).
set(CMAKE_CXX_COMPILE_FEATURES "cxx_std_17" CACHE STRING "")
set(CMAKE_CXX17_STANDARD_COMPILE_OPTION "-std=c++17" CACHE STRING "")
set(CMAKE_CXX17_EXTENSION_COMPILE_OPTION "-std=gnu++17" CACHE STRING "")
WCEOF
  echo "  windows: pinned zigcpp compiler to ${_win_zig_cc##*/} / ${_win_zig_cxx##*/} (-target ${ZIG_TRIPLET})"
  cat -n "${_win_cache_seed}" >&2
  # Compiler paths go on the COMMAND LINE as -D args, not into the -C cache file:
  # long quoted FILEPATH values have been observed splitting across physical lines
  # in CMake's cache-file parser ("Parse error. Expected a command name"), while -D
  # args are read from argv and sidestep it entirely.
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_C_COMPILER:FILEPATH="${_win_zig_cc}"
    -DCMAKE_CXX_COMPILER:FILEPATH="${_win_zig_cxx}"
    -C "${_win_cache_seed}"
  )
fi

# llvm-config discovery for BOTH linux and osx cross is handled by the unified is_unix
# block below, consuming the staged native llvm-config at ${BUILD_PREFIX}/lib/zig-llvm/bin.

if is_osx && is_cross; then
  case "${target_platform}" in
    osx-64)     EXTRA_CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES=x86_64) ;;
    osx-arm64)  EXTRA_CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES=arm64) ;;
  esac
fi

# zigcpp's cmake configure (ZIG_USE_LLVM_CONFIG=ON) locates llvm-config via a bare
# find_program on PATH (cmake/Findllvm.cmake). Prepend the dir holding a RUNNABLE
# (build-arch) llvm-config: for cross, the self-sufficient one staged by
# build_native_llvm_config at ${BUILD_PREFIX}/lib/zig-llvm/bin (no longer the stale
# zig_impl build-dep); for native, this build's just-installed ${PREFIX}/lib/zig-llvm.
# llvm-config self-reports its lib/zig-llvm prefix from the binary location; for cross
# the ZIG_LLVM_* BUILD_PREFIX->PREFIX perl rewrite below repoints config.h to the
# shipped target tree. No file is added to the shipped package.
if is_unix; then
  # is_cross() is false for same-arch "self-cross" osx lanes (build_platform ==
  # target_platform; see the win-64 note below for the same is_cross()
  # semantics), so it alone is not what triggers the BUILD_PREFIX branch below --
  # the runnable check does the real distinguishing: whether PREFIX's own
  # llvm-config binary can actually execute on this host. For a genuine
  # cross-arch lane (e.g. osx_arm64->osx_64) it cannot, but for a same-arch
  # self-cross lane it can, and it is the FULL build (clang+lld) -- unlike the
  # minimal, llvm-config-only tree staged at BUILD_PREFIX below.
  if is_cross && ! { [[ -x "${PREFIX}/lib/zig-llvm/bin/llvm-config" ]] && "${PREFIX}/lib/zig-llvm/bin/llvm-config" --version &>/dev/null; }; then
    _llvm_config_dir="${BUILD_PREFIX}/lib/zig-llvm/bin"
    # PR #123, round 5: since build-zig.sh always configures zigcpp with
    # ZIG_SHARED_LLVM=ON on unix (see EXTRA_CMAKE_ARGS above), zig's own
    # cmake/Findllvm.cmake gates every llvm-config candidate with `llvm-config
    # --libs --link-shared` before accepting it. The native/minimal llvm-config
    # staged here by build_native_llvm_config() (_native_llvm_config.sh) now
    # configures with LLVM_LINK_LLVM_DYLIB=ON (so it performs the shared-library
    # existence probe at all), but it never builds/installs the actual libLLVM
    # shared-library file itself (that script only ever builds the `llvm-config`
    # CLI target, deliberately, to stay fast/self-sufficient) — so the probe
    # would still fail with "LLVM 21.x found at .../llvm-config does not support
    # linking as a shared library" (confirmed via source read of
    # llvm/tools/llvm-config/llvm-config.cpp: DyLibExists = sys::fs::exists(...)
    # on ActiveLibDir, i.e. this binary's own ../lib). Stage the real shared
    # library file(s) — already built by _llvm_build.sh into
    # ${PREFIX}/lib/zig-llvm/lib earlier in this same script (LLVM_RECIPE_DIR/
    # build.sh, sourced above build-zig.sh in recipe/build.sh) — into this
    # minimal tree's own lib dir. llvm-config only calls sys::fs::exists() on
    # this path; it never loads/executes the file, so a plain copy (even of a
    # foreign-arch binary, on a genuine cross lane) is sufficient. The real
    # ${PREFIX} copy is what's actually consumed at link time, via the
    # BUILD_PREFIX->PREFIX config.h rewrite a few lines below.
    mkdir -p "${BUILD_PREFIX}/lib/zig-llvm/lib"
    shopt -s nullglob
    _real_llvm_dylibs=("${PREFIX}"/lib/zig-llvm/lib/libLLVM*.so* "${PREFIX}"/lib/zig-llvm/lib/libLLVM*.dylib)
    shopt -u nullglob
    if [[ ${#_real_llvm_dylibs[@]} -gt 0 ]]; then
      cp -f "${_real_llvm_dylibs[@]}" "${BUILD_PREFIX}/lib/zig-llvm/lib/"
      echo "  unix cross: staged $(IFS=,; echo "${_real_llvm_dylibs[*]##*/}") to ${BUILD_PREFIX}/lib/zig-llvm/lib for llvm-config --link-shared probe"
    else
      echo "  WARNING: no libLLVM shared-library file found at ${PREFIX}/lib/zig-llvm/lib to stage for llvm-config --link-shared probe" >&2
    fi
    unset _real_llvm_dylibs
  else
    _llvm_config_dir="${PREFIX}/lib/zig-llvm/bin"
  fi
  if [[ ! -x "${_llvm_config_dir}/llvm-config" ]]; then
    echo "FATAL: expected runnable llvm-config at ${_llvm_config_dir}/llvm-config for zig configure" >&2
    exit 1
  fi
  export PATH="${_llvm_config_dir}:${PATH}"
  echo "  unix: prepended ${_llvm_config_dir} to PATH for zigcpp llvm-config discovery"
elif is_not_unix && ! is_cross; then
  # Windows (win-64 self-cross: build_platform == target_platform == win-64, so
  # is_cross() is false here -- see the osx self-cross note above for the same
  # is_cross() semantics). remove-unneeded.sh ships the real llvm-config binary
  # directly as "llvm-config.exe" (no bare extension-less wrapper -- CMake's
  # find_program(NAMES ... llvm-config) tries each candidate name AS-IS before
  # NAME+".exe", so a bare "#!/bin/sh" wrapper here would be matched first and
  # native CreateProcess cannot execute it, breaking zig's own
  # cmake/Findllvm.cmake --version probe with empty output; see that file's
  # comment, PR #123 win-64 CI failure 2026-08-01). A llvm-config.bat launcher
  # (direct native exec, no bash hop) is also emitted as a secondary access
  # point. The LLVM install tree lives under Library/ on Windows (conda
  # convention; see zig-llvm/building/_env.sh's LLVM_INSTALL split), not
  # PREFIX/lib directly. ZIG_SHARED_LLVM=OFF on windows (EXTRA_CMAKE_ARGS
  # above), so the unix-only ZIG_SHARED_LLVM=ON shared-library
  # existence-probe staging above does not apply here. True cross
  # (win-arm64/win-32 built on a win-64 agent, is_cross() true) is handled by
  # the dedicated elif branch below, via the llvm-tools build-dep staged at
  # ${BUILD_PREFIX}/Library/bin (see _native_llvm_config.sh's
  # build_native_llvm_config comment: that self-built native llvm-config path
  # is unix-only and returns early on windows).
  _llvm_config_dir="${PREFIX}/Library/lib/zig-llvm/bin"
  if [[ ! -f "${_llvm_config_dir}/llvm-config.exe" ]]; then
    echo "FATAL: expected llvm-config.exe at ${_llvm_config_dir} for zigcpp configure" >&2
    exit 1
  fi
  export PATH="${_llvm_config_dir}:${PATH}"
  echo "  windows: prepended ${_llvm_config_dir} to PATH for zigcpp llvm-config discovery"

  # zig now configures zigcpp with ZIG_SHARED_LLVM=ON on Windows too (LLVM is
  # DLL-only). zig's cmake/Findllvm.cmake runs `llvm-config --shared-mode
  # [--link-shared]`, and llvm-config's DyLibExists probe (llvm-config.cpp:
  # SharedDir = ActiveBinDir) requires the MERGED libLLVM dll to sit in
  # llvm-config's OWN bin dir. If it is absent there, --shared-mode prints
  # "<name> is missing", EXITS 1 with empty stdout, and Findllvm.cmake crashes at
  # `if(${LLVM_LINK_MODE} STREQUAL "shared")` (PR #123 win-64 CI, 2026-08-03).
  # Ensure the merged dll is adjacent to llvm-config.exe -- copy it in place from
  # Library/bin or the zig-llvm lib dir ONLY if bin lacks it (keeps the full
  # zig-llvm tree intact so llvm-config --libs still resolves the import libs from
  # ../lib). No-op if the dll is already present.
  shopt -s nullglob
  _probe_dll=("${_llvm_config_dir}"/libLLVM*.dll "${_llvm_config_dir}"/LLVM*.dll)
  if [[ ${#_probe_dll[@]} -eq 0 ]]; then
    _merged_dll_src=(
      "${PREFIX}"/Library/bin/libLLVM*.dll "${PREFIX}"/Library/bin/LLVM*.dll
      "${PREFIX}"/Library/lib/zig-llvm/lib/libLLVM*.dll
    )
    if [[ ${#_merged_dll_src[@]} -gt 0 ]]; then
      cp -f "${_merged_dll_src[0]}" "${_llvm_config_dir}/"
      echo "  windows: staged ${_merged_dll_src[0]##*/} -> ${_llvm_config_dir} for llvm-config DyLibExists probe"
    else
      echo "  WARNING: no merged libLLVM*.dll found under PREFIX to satisfy llvm-config DyLibExists probe" >&2
    fi
    unset _merged_dll_src
  else
    echo "  windows: merged libLLVM dll already adjacent to llvm-config.exe: ${_probe_dll[0]##*/}"
  fi
  unset _probe_dll
  shopt -u nullglob

  # Diagnostics (non-fatal): make the next CI log definitive on name-vs-location
  # if the shared-mode probe still fails.
  echo "  windows: llvm-config DyLibExists diagnostics"
  ls -la "${_llvm_config_dir}"/*LLVM*.dll "${PREFIX}"/Library/bin/*LLVM*.dll 2>&1 | sed 's/^/    /' || true
  for _q in --version --bindir --libdir --shared-mode; do
    echo "    llvm-config ${_q} ->"
    "${_llvm_config_dir}/llvm-config.exe" "${_q}" 2>&1 | sed 's/^/      /' || true
  done
  echo "    llvm-config --shared-mode --link-shared ->"
  "${_llvm_config_dir}/llvm-config.exe" --shared-mode --link-shared 2>&1 | sed 's/^/      /' || true
  unset _q

  # zig-llvm-16 builds Windows with CLANG_LINK_CLANG_DYLIB=ON (_llvm_build.sh:3),
  # producing one merged libclang-cpp.dll + import lib instead of per-component
  # static clang archives. Zig's stock cmake/Findclang.cmake searches for those
  # per-component archives (FIND_AND_ADD_CLANG_LIB) and finds nothing, aborting
  # CMake Generate on the zigcpp target (CLANG_LIBRARIES-NOTFOUND; PR #17 run
  # 31350564984). Mirror the linux-cross ZIG_LLVM_MANUAL_OVERRIDE feed (patches/
  # cmake/0007-manual-llvm-clang-lld-override.patch) using the .dll.a import
  # libs shipped alongside the runtime DLLs (recipe.yaml package_contents:
  # Library/lib/zig-llvm/lib/lib{LLVM,clang-cpp}*.dll.a, liblldZig.dll.a).
  _zig_llvm_win="${PREFIX}/Library/lib/zig-llvm"
  _libllvm_win=$(ls "${_zig_llvm_win}"/lib/libLLVM*.dll.a 2>/dev/null | head -n1)
  _libclang_win=$(ls "${_zig_llvm_win}"/lib/libclang-cpp*.dll.a 2>/dev/null | head -n1)
  _lldlibs_win="${_zig_llvm_win}/lib/liblldZig.dll.a"
  if [[ -z "${_libllvm_win}" || -z "${_libclang_win}" || ! -f "${_lldlibs_win}" ]]; then
    echo "FATAL: windows native manual override needs libLLVM/libclang-cpp/liblldZig .dll.a under ${_zig_llvm_win}/lib" >&2
    ls -la "${_zig_llvm_win}/lib" 2>&1 | sed 's/^/    /' >&2 || true
    exit 1
  fi
  EXTRA_CMAKE_ARGS+=(
    -DZIG_LLVM_MANUAL_OVERRIDE=1
    -DZIG_LLVM_MANUAL_LIBRARIES="${_libllvm_win}"
    -DZIG_LLVM_MANUAL_LIBDIRS="${_zig_llvm_win}/lib"
    -DZIG_LLVM_MANUAL_INCLUDE_DIRS="${_zig_llvm_win}/include"
    -DZIG_LLVM_MANUAL_CLANG_LIBRARIES="${_libclang_win}"
    -DZIG_LLVM_MANUAL_LLD_LIBRARIES="${_lldlibs_win}"
  )
  echo "  windows native: ZIG_LLVM_MANUAL_OVERRIDE on"
  echo "    libLLVM  = ${_libllvm_win}"
  echo "    libclang = ${_libclang_win}"
  echo "    lld      = ${_lldlibs_win}"

  # zig's gnu-target linker searches libNAME.a but NOT libNAME.dll.a; both are ar
  # import archives, so expose .a aliases so the Stage-2 self-hosted `zig build` links.
  # Ported from recipes/zig-0.15.2/build.sh:148-154, which this block otherwise mirrors.
  # Its absence here is why PR #17 run 31437494403 win-64 PHASE 2 failed with
  # "libLLVM-21.a: file not found" at the final zig build-exe.
  for _dlla in "${_libllvm_win}" "${_libclang_win}" "${_lldlibs_win}"; do
    if [[ -f "${_dlla}" ]]; then
      cp -f "${_dlla}" "${_dlla%.dll.a}.a"
    fi
  done
  unset _dlla
elif is_not_unix && is_cross; then
  # Windows cross (win-arm64/win-32 built on a win-64 agent; is_cross() is true
  # here since build_platform != target_platform, unlike the win-64 self-cross
  # case handled by the branch above). PREFIX's own llvm-config.exe is a
  # TARGET-arch (e.g. aarch64) binary -- it cannot execute on this x86_64
  # win-64 host. The previous fix here prepended a "build-arch llvm-config.exe"
  # from the llvm-tools build-dep at ${BUILD_PREFIX}/Library/bin, but that
  # premise is DISPROVEN: llvm-tools 21.1.8 IS installed there (recipe.yaml
  # selector "not unix and arm64"), yet it never ships llvm-config.exe at that
  # path -- only llvm-nm/llvm-readobj -- so the guard below always fired FATAL
  # (CI run 31912407764, job 95079442668). Abandon build-arch llvm-config
  # discovery entirely: with ZIG_LLVM_MANUAL_OVERRIDE defined,
  # cmake/Findllvm.cmake never calls execute_process(llvm-config ...) at all
  # (patches/cmake/0007-manual-llvm-clang-lld-override.patch), so no runnable
  # llvm-config is needed on this lane, build-arch or otherwise. Port the
  # same manual-override cache vars the windows-native branch above
  # (~lines 646-687) already uses, but resolve libraries from the TARGET
  # (PREFIX) zig-llvm tree, matching the linux-cross block below
  # (~lines 775-834). Existing zigcpp compiler pinning / -target
  # ${ZIG_TRIPLET} flags (elif is_not_unix block above, ~lines 380-502)
  # already apply to this lane unchanged.
  _zig_llvm_wincross="${PREFIX}/Library/lib/zig-llvm"
  _libllvm_wincross=$(ls "${_zig_llvm_wincross}"/lib/libLLVM*.dll.a 2>/dev/null | head -n1)
  _libclang_wincross=$(ls "${_zig_llvm_wincross}"/lib/libclang-cpp*.dll.a 2>/dev/null | head -n1)
  _lldlibs_wincross="${_zig_llvm_wincross}/lib/liblldZig.dll.a"
  if [[ -z "${_libllvm_wincross}" || -z "${_libclang_wincross}" || ! -f "${_lldlibs_wincross}" ]]; then
    echo "FATAL: windows cross manual override needs libLLVM/libclang-cpp/liblldZig .dll.a under ${_zig_llvm_wincross}/lib" >&2
    ls -la "${_zig_llvm_wincross}/lib" 2>&1 | sed 's/^/    /' >&2 || true
    exit 1
  fi
  EXTRA_CMAKE_ARGS+=(
    -DZIG_LLVM_MANUAL_OVERRIDE=1
    -DZIG_LLVM_MANUAL_LIBRARIES="${_libllvm_wincross}"
    -DZIG_LLVM_MANUAL_LIBDIRS="${_zig_llvm_wincross}/lib"
    -DZIG_LLVM_MANUAL_INCLUDE_DIRS="${_zig_llvm_wincross}/include"
    -DZIG_LLVM_MANUAL_CLANG_LIBRARIES="${_libclang_wincross}"
    -DZIG_LLVM_MANUAL_LLD_LIBRARIES="${_lldlibs_wincross}"
  )
  echo "  windows cross: ZIG_LLVM_MANUAL_OVERRIDE on"
  echo "    libLLVM  = ${_libllvm_wincross}"
  echo "    libclang = ${_libclang_wincross}"
  echo "    lld      = ${_lldlibs_wincross}"

  # .dll.a -> .a aliasing so zig's gnu-target linker (searches .dll/.lib/.a
  # but NOT .dll.a) resolves the final Stage-2 self-hosted `zig build` link.
  # Mirrors the windows-native branch above (~lines 677-687).
  for _dlla in "${_libllvm_wincross}" "${_libclang_wincross}" "${_lldlibs_wincross}"; do
    if [[ -f "${_dlla}" ]]; then
      cp -f "${_dlla}" "${_dlla%.dll.a}.a"
    fi
  done
  unset _dlla
fi

if is_linux && is_cross; then
  # llvmdev-free clang/lld detection for CMake Generate. On a genuine cross lane
  # the llvm-config on PATH is the MINIMAL build-arch tree staged at
  # ${BUILD_PREFIX}/lib/zig-llvm by build_native_llvm_config()
  # (zig-llvm-16/building/_native_llvm_config.sh builds only the llvm-config
  # target with LLVM_ENABLE_PROJECTS="", and the staging block above copies in
  # libLLVM* and nothing else). zig's Findclang.cmake/Findlld.cmake resolve
  # relative to that prefix, so they find no clang/lld and CMake Generate aborts
  # with CLANG_LIBRARIES/CLANG_INCLUDE_DIRS/LLD_INCLUDE_DIRS = NOTFOUND
  # (PR #17 run 31281895675: linux-aarch64 + linux-riscv64). Native lanes are
  # unaffected because they point llvm-config at the FULL ${PREFIX} tree.
  # Feed LLVM/Clang/LLD to cmake directly from the bundled target-arch zig-llvm
  # (linked only, never executed) via the ZIG_LLVM_MANUAL_OVERRIDE patch
  # (patches/cmake/0007-manual-llvm-clang-lld-override.patch). Never conda
  # llvmdev/clangdev. Mirrors recipes/zig-0.15.2/build.sh's is_linux && is_cross
  # block, with 0.16's per-arch lld bundle choices.
  _zig_llvm_lnx="${PREFIX}/lib/zig-llvm"
  # Prefer the dashed real .so; fall back to the dotted soname (same resolution as
  # zig-llvm-16/building/_lld_bundle.sh). Do not use `find -type f`: libLLVM.so is
  # a symlink on some lanes.
  _libllvm_lnx=$(ls "${_zig_llvm_lnx}"/lib/libLLVM-*.so "${_zig_llvm_lnx}"/lib/libLLVM.so.* 2>/dev/null | head -n1)
  _libclang_lnx=$(ls "${_zig_llvm_lnx}"/lib/libclang-cpp*.so* 2>/dev/null | head -n1)
  # Match the per-arch lld choice already made for ZIG_LLD_BUNDLE_SO at the top of
  # this script, so cmake is told about the same artifact the link will consume:
  #   ppc64le        -> zig's own -mlongcall relink (built just below, after configure)
  #   riscv64/s390x  -> no bundle exists at all (zig-llvm-16/building/_lld_bundle.sh
  #                     skips it: no conda-forge zstd/xml2/z), so feed the six static
  #                     archives that remove-unneeded.sh deliberately keeps on those
  #                     arches, in _lld_bundle.sh's link order -- format-specific
  #                     first, liblldCommon.a LAST since the others depend on it.
  #                     Alphabetical (`find | sort`) would break the link.
  #   otherwise      -> zig-llvm-16's prebuilt liblldZig.so
  case "${target_platform}" in
    linux-ppc64le)
      _lldlibs_lnx="${PREFIX}/lib/libzig-lld-bundle.so" ;;
    linux-riscv64|linux-s390x)
      _lldlibs_lnx="${_zig_llvm_lnx}/lib/liblldELF.a;${_zig_llvm_lnx}/lib/liblldCOFF.a;${_zig_llvm_lnx}/lib/liblldMachO.a;${_zig_llvm_lnx}/lib/liblldWasm.a;${_zig_llvm_lnx}/lib/liblldMinGW.a;${_zig_llvm_lnx}/lib/liblldCommon.a" ;;
    *)
      _lldlibs_lnx="${_zig_llvm_lnx}/lib/liblldZig.so" ;;
  esac
  if [[ -z "${_libllvm_lnx}" || -z "${_libclang_lnx}" ]]; then
    echo "FATAL: linux cross manual override needs libLLVM and libclang-cpp under ${_zig_llvm_lnx}/lib" >&2
    ls -la "${_zig_llvm_lnx}/lib" 2>&1 | sed 's/^/    /' >&2 || true
    exit 1
  fi
  # Pass as CMake cache vars (-D), NOT env exports: the Findllvm/clang/lld override
  # patch tests if(DEFINED ZIG_LLVM_MANUAL_OVERRIDE) at cmake scope.
  EXTRA_CMAKE_ARGS+=(
    -DZIG_LLVM_MANUAL_OVERRIDE=1
    -DZIG_LLVM_MANUAL_LIBRARIES="${_libllvm_lnx}"
    -DZIG_LLVM_MANUAL_LIBDIRS="${_zig_llvm_lnx}/lib"
    -DZIG_LLVM_MANUAL_INCLUDE_DIRS="${_zig_llvm_lnx}/include"
    -DZIG_LLVM_MANUAL_CLANG_LIBRARIES="${_libclang_lnx}"
    -DZIG_LLVM_MANUAL_LLD_LIBRARIES="${_lldlibs_lnx}"
  )
  echo "  linux cross: ZIG_LLVM_MANUAL_OVERRIDE on"
  echo "    libLLVM  = ${_libllvm_lnx}"
  echo "    libclang = ${_libclang_lnx}"
  echo "    lld      = ${_lldlibs_lnx}"
fi

configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

# --- ppc64le bundle .so build (after cmake configure, before zig2 link) ---
if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  mkdir -p "${PREFIX}/lib"
  source "${RECIPE_DIR}/building/_lld_bundle.sh"
  build_lld_bundle_ppc64le "${ZIG_CXX_STUB_WRAPPER}" "${PREFIX}" "${ZIG_LOCAL_CACHE_DIR}" || exit 1
  install -m 755 "${ZIG_LOCAL_CACHE_DIR}/libzig-lld-bundle.so" "${PREFIX}/lib/" || exit 1
fi

# --- Post CMake Configuration ---

# Append extra link deps to config.h (cmake doesn't know about conda's split packaging)
# Append LLVM deps that conda's split packaging doesn't bake into
# config.h's ZIG_LLVM_LIBRARIES: zlib (adler32 refs in lld-ELF),
# zstd (compression), libxml2. Needed on every native + cross linux
# build — linux-aarch64 failed linking zig2 with undefined adler32
# when this was gated on `is_cross`, and linux-64 NATIVE failed the same
# way (undefined adler32_combine/ZSTD_createCCtx/deflateInit2_) because
# the guard below still required is_cross. zlib/zstd/libxml2(-devel) are
# unconditional host deps (recipe.yaml, not riscv64) reachable via zig's
# --search-prefix PREFIX on every linux lane, so drop the is_cross gate.
# appended to the lld static-archive branch below (Part B).
is_unix && [[ "${target_platform}" != "linux-riscv64" && "${target_platform}" != "linux-s390x" ]] && \
  perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;-lzstd;-lxml2;-lz\"@" "${cmake_build_dir}"/config.h
is_osx && is_cross &&   perl -pi -e "s@(ZIG_LLVM_\w+ \")${BUILD_PREFIX}@\$1${PREFIX}@" "${cmake_build_dir}"/config.h
# linux cross now discovers llvm-config from ${BUILD_PREFIX}/lib/zig-llvm/bin (native
# staged config), so its ZIG_LLVM_* dirs also self-report BUILD_PREFIX -> repoint to PREFIX.
is_linux && is_cross && perl -pi -e "s@(ZIG_LLVM_\w+ \")${BUILD_PREFIX}@\$1${PREFIX}@" "${cmake_build_dir}"/config.h
# ZIG_SHARED_LIBCXX_DIR is exported only for ppc64le-cross (_cross_compile.sh:30); default it to the
# canonical zig-llvm shared-libcxx dir so native + other non-ppc64le lanes do not trip set -u here.
# Value equals the ppc64le-cross export, so that lane is unchanged.
: "${ZIG_SHARED_LIBCXX_DIR:=${PREFIX}/lib/zig-llvm/lib}"
is_osx &&               perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${ZIG_SHARED_LIBCXX_DIR}/libc++.dylib\"@" "${cmake_build_dir}"/config.h
is_linux &&             perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${ZIG_SHARED_LIBCXX_DIR}/libc++.so.1\"@" "${cmake_build_dir}"/config.h
# Note: do NOT inject ${PREFIX}/lib/libc++.dylib into ZIG_LLVM_LIBRARIES on macOS.
# build.zig sets mod.link_libcpp = true for darwin targets, which (via patches/
# Lld.zig-prefer-shared-libcxx.patch) already resolves to ${PREFIX}/lib/libc++.1.dylib.
# Injecting libc++.dylib here would add a second LC_LOAD_DYLIB to the same dylib;
# macOS SDK >= 26 dyld aborts on duplicate linked dylibs ("duplicate linked dylib
# '@rpath/libc++.1.dylib'" — Abort trap: 6).

# zig2.c (the pre-generated C bootstrap from 0.16) calls getrandom,
# copy_file_range, and statx — all absent from conda-forge's glibc 2.17
# sysroot. Compile weak-symbol syscall() stubs and inject the .o into
# both the zig-build path (via config.h's ZIG_LLVM_LIBRARIES) and the
# CMake fallback path (via cmake/0002 target_link_libraries).
# Guard on ZIG_SYSROOT: outside conda-forge CI (e.g. local
# dev with a modern glibc system), the stubs aren't needed.
if is_linux && [[ -n "${ZIG_SYSROOT:-}" ]]; then
  source "${RECIPE_DIR}/building/_glibc217_syscall_stubs.sh"
  create_glibc217_syscall_stubs "${ZIG_CC_STUB_WRAPPER}" "${ZIG_LOCAL_CACHE_DIR}"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/glibc217_syscall_stubs.o\"|g" "${cmake_build_dir}/config.h"
fi

dbg echo "=== DEBUG ===" && dbg cat "${cmake_build_dir}"/config.h && dbg echo "=== DEBUG ==="

# --- Cross-build setup (must happen BEFORE Stage 1 since EXTRA_ZIG_ARGS has --libc) ---

if is_linux; then
  source "${RECIPE_DIR}/building/_cross.sh"
  source "${RECIPE_DIR}/building/_atfork.sh"

  create_zig_linux_libc_file "${zig_build_dir}/libc_file"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"
  create_pthread_atfork_stub "${CONDA_TRIPLET%%-*}" "${ZIG_CC_STUB_WRAPPER}" "${ZIG_LOCAL_CACHE_DIR}"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/libc_single_threaded_stub.o\"|g" "${cmake_build_dir}/config.h"
  create_libc_single_threaded_stub "${CONDA_TRIPLET%%-*}" "${ZIG_CC_STUB_WRAPPER}" "${ZIG_LOCAL_CACHE_DIR}"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/cxa_thread_atexit_impl_stub.o\"|g" "${cmake_build_dir}/config.h"
  create_cxa_thread_atexit_impl_stub "${CONDA_TRIPLET%%-*}" "${ZIG_CC_STUB_WRAPPER}" "${ZIG_LOCAL_CACHE_DIR}"

  # riscv64: __tls_get_addr is genuinely present in this sysroot, but only
  # in the dynamic loader (ld-linux-riscv64-lp64d.so.1), not in libc.so.6 --
  # confirmed via nm -D on both files. It is normally pulled in via the
  # AS_NEEDED(ld-linux-riscv64-lp64d.so.1) entry of libc.so's GNU ld script,
  # but the libc.so ld-script replacement in the is_linux && is_cross block
  # above (symlink straight to libc.so.6, to dodge the no-sysroot absolute-
  # path open failure) dropped that loader reference. lld can then no longer
  # resolve the symbol against any linked library, so link the loader
  # directly here to restore it; it is the correct, real glibc implementation
  # (same mechanism already used for libc++.so.1 above). Not a stub -- no
  # reimplementation risk. The sysroot is sourced from the recipe-owned
  # BUILD_PREFIX + CONDA_TOOLCHAIN_HOST (the target triplet), NOT the
  # gcc-activation-only sysroot the conda-forge compiler would export.
  if [[ "${target_platform}" == "linux-riscv64" ]]; then
    perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${BUILD_PREFIX}/${CONDA_TOOLCHAIN_HOST}/sysroot/lib64/ld-linux-riscv64-lp64d.so.1\"|g" "${cmake_build_dir}/config.h"
  fi
fi


# TEMPORARY: riscv64 TLS CI debug probe (undefined __tls_get_addr in
# liblldELF.a plateaued at exactly 1432 refs across two CI rounds despite
# the -ftls-model=initial-exec CXXFLAGS fix in
# recipe/zig-llvm/building/_llvm_build.sh:170-197). Two competing
# hypotheses, neither confirmable locally (no riscv64 sysroot cached, no
# vendored LLVM source tree present): (a) the sysroot's libc.so.6 genuinely
# doesn't export __tls_get_addr, (b) the CXXFLAGS above never actually
# reached lld/ELF's compile invocations (a CMake propagation/shadowing
# issue). Mirrors the ppc64le qemu debug-probe idiom (recipe.yaml
# ~704-719): non-fatal, clearly labeled, removed once the root cause is
# confirmed/fixed. Runs here (not recipe.yaml test phase) because the
# failure is a BUILD-time link error in build_zig_with_zig below, before
# any test phase would ever run.
if [[ "${target_platform}" == "linux-riscv64" ]]; then
  echo "=== RISCV64 TLS DIAGNOSTIC ==="
  _riscv64_sysroot_libc="${ZIG_SYSROOT}/lib64/lp64d/libc.so.6"
  echo "  [1/2] __tls_get_addr export check: ${_riscv64_sysroot_libc}"
  nm -D --defined-only "${_riscv64_sysroot_libc}" 2>&1 | grep -i tls_get_addr || echo "  NOT FOUND"
  # LLVM_BUILD is a plain (unexported) variable set by zig-llvm/build.sh,
  # which runs as a separate process (recipe/build.sh:279) from this script
  # (recipe/build.sh:281); recompute the same path independently rather
  # than relying on inheritance (see recipe/zig-llvm/building/_env.sh:30).
  _riscv64_compile_commands="${SRC_DIR}/conda-llvm-build/compile_commands.json"
  echo "  [2/2] -ftls-model flag in lld/ELF compile commands: ${_riscv64_compile_commands}"
  if [[ -f "${_riscv64_compile_commands}" ]]; then
    grep -A2 'Relocations.cpp' "${_riscv64_compile_commands}" | grep -o -- '-ftls-model=[a-z-]*' || echo "  FLAG NOT FOUND IN COMPILE COMMAND"
  else
    echo "  NOT FOUND: ${_riscv64_compile_commands} does not exist (CMAKE_EXPORT_COMPILE_COMMANDS not honored?)"
  fi
  unset _riscv64_sysroot_libc _riscv64_compile_commands
  echo "=== end RISCV64 TLS DIAGNOSTIC ==="
fi

if build_zig_with_zig "${zig_build_dir}" "${BUILD_ZIG}" "${PREFIX}"; then
  dbg echo "=== ZIG BUILD: SUCCESS ==="
else
  echo "ERROR: zig-build failed." >&2
  exit 1
fi

# Deferred liblld*.a cleanup (unix). remove-unneeded.sh (zig-llvm phase) intentionally
# KEPT these static archives so zig's own find_package(LLD) could static-link zigcpp
# against them during build_zig_with_zig above. The unix zigcpp CMake links the raw
# liblld*.a (except ppc64le, whose patch-0006 redirects to the liblldZig bundle), so
# deleting them earlier broke find_package(LLD). Now that the self-build has consumed
# them, remove them so they do not ship. Skip linux-riscv64/linux-s390x, which have no
# liblldZig bundle and keep the archives permanently (mirrors remove-unneeded.sh).
if is_unix && [[ "${target_platform}" != "linux-riscv64" && "${target_platform}" != "linux-s390x" ]]; then
  find "${PREFIX}/lib/zig-llvm/lib" -name "liblld*.a" -type f -delete 2>/dev/null || true
  echo "  Deferred-removed liblld*.a from ${PREFIX}/lib/zig-llvm/lib after zig self-build"
fi


# Odd random occurence of zig.pdb
rm -f "${PREFIX}/bin/*.pdb"

# macOS: --search-prefix adds a library search but does not embed LC_RPATH in the Mach-O binary.
if is_osx; then
  # zig-llvm/building/post-install.sh rewrites every zig-llvm/lib/*.dylib's own
  # install name to "@loader_path/<basename>" for intra-dir sibling resolution.
  # zig's own binary links against those same dylibs and inherits that identical
  # @loader_path string verbatim -- but @loader_path there resolves relative to
  # $PREFIX/bin/ (zig's own dir), not $PREFIX/lib/zig-llvm/lib/, breaking Phase 2's
  # self-exec (dyld: Library not loaded: @loader_path/libclang-cpp.dylib). Rewrite
  # each such zig-llvm dependency to the correct relative path before adding rpath.
  while IFS= read -r _dep; do
    [[ -z "${_dep}" ]] && continue
    _dep_basename=$(basename "${_dep}")
    if [[ "${_dep}" == @loader_path/* ]] && [[ -f "${PREFIX}/lib/zig-llvm/lib/${_dep_basename}" ]]; then
      install_name_tool -change "${_dep}" "@loader_path/../lib/zig-llvm/lib/${_dep_basename}" "${PREFIX}/bin/zig"
    fi
  done < <(otool -L "${PREFIX}/bin/zig" | awk 'NR>1 {print $1}')
  install_name_tool -add_rpath "${PREFIX}/lib" "${PREFIX}/bin/zig"
  install_name_tool -add_rpath "${PREFIX}/lib/zig-llvm/lib" "${PREFIX}/bin/zig"
  # install_name_tool above invalidates any signature applied at link time.
  # arm64 (Apple Silicon) enforces valid code signatures strictly at the OS
  # level, unlike x86_64 macOS which has historically been lenient -- re-sign
  # ad-hoc so the mutated binary is runnable on arm64.
  codesign --force --sign - "${PREFIX}/bin/zig"
fi

# --- osx native fail-fast probe: staged zig cc smoke tests + libLLVM diagnostics -
# The post-build package test (recipe.yaml:568-578, `if: osx and is_native`)
# links a trivial program with `zig cc -fuse-ld=lld`; osx-arm64 has failed there
# with LLVM 'unable to create target: ... no targets are registered' (PR #123).
#
# ROUND 17 LEAD (REFUTED): we suspected liblldZig.dylib (ZIG_LLD_BUNDLE_SO) linked
# its OWN libLLVM, so lld::macho::link saw a SEPARATE (empty) TargetRegistry from
# the one zig's InitializeAllTargets populated. The round-17 probe disproved it:
# DYLD_PRINT_LIBRARIES showed libLLVM-*.dylib with the IDENTICAL UUID in both the
# driver and its forked codegen child (ONE shared image), liblldZig.dylib never
# appeared in the trace at all, and the error was raised by clang -cc1 during
# CODEGEN -- before lld is ever invoked. So the failing component is the single
# libLLVM itself, and -fuse-ld=lld is probably incidental.
#
# ROUND 18 = DIAGNOSTIC WIDENING. Two facts still unexplained:
#   (i)  osx-64 native is GREEN and runs this very same probe -- so whatever is
#        broken is arm64-SPECIFIC, not a blanket "libLLVM has no targets".
#   (ii) we never established whether plain compilation (no lld) also fails.
# Rather than exit at the first failure (which is why round 17 could only report
# THAT -fuse-ld=lld failed, never WHY), run three staged probes cheapest-first,
# record each, and fail at the END. Every diagnostic below prints on the GREEN
# osx-64 lane too, so the two lanes' logs can be diffed directly.
if is_osx && ! is_cross; then
  echo "=== osx probe: staged zig cc smoke tests + libLLVM target-registration diagnostics ==="
  _probe_dir="${zig_build_dir}/_osx_lld_probe"
  rm -rf "${_probe_dir}"; mkdir -p "${_probe_dir}"
  printf 'int main(void){return 0;}\n' > "${_probe_dir}/probe.c"
  _lldbundle="${PREFIX}/lib/zig-llvm/lib/liblldZig.dylib"
  _probe_fail=0

  echo "  --- image inventory -------------------------------------------------"
  echo "  otool -L ${PREFIX}/bin/zig:"
  otool -L "${PREFIX}/bin/zig" 2>&1 | sed 's/^/    /' || true
  if [[ -f "${_lldbundle}" ]]; then
    echo "  otool -L ${_lldbundle}:"
    otool -L "${_lldbundle}" 2>&1 | sed 's/^/    /' || true
  else
    echo "  NOTE: ${_lldbundle} not present"
  fi
  echo "  libLLVM dylibs present under PREFIX:"
  ls -la "${PREFIX}"/lib/libLLVM*.dylib "${PREFIX}"/lib/zig-llvm/lib/libLLVM*.dylib 2>&1 | sed 's/^/    /' || true

  # (A) DECISIVE: does the shipped libLLVM actually export the target-registration
  # symbols? If LLVMInitializeAArch64Target* is absent on arm64 but the X86 pair is
  # present on the green osx-64 lane, the defect is dead-strip / archive-member
  # selection in the LLVM build, NOT anything in zig or the lld bundle.
  echo "  --- (A) target-registration symbols in libLLVM -----------------------"
  _llvmdylib="$(ls "${PREFIX}"/lib/zig-llvm/lib/libLLVM*.dylib 2>/dev/null | head -n1 || true)"
  [[ -z "${_llvmdylib}" ]] && _llvmdylib="$(ls "${PREFIX}"/lib/libLLVM*.dylib 2>/dev/null | head -n1 || true)"
  if [[ -n "${_llvmdylib}" ]]; then
    echo "  inspecting: ${_llvmdylib}"
    echo "  exported LLVMInitialize*Target* symbols (AArch64 + X86, both lanes for diffing):"
    nm -gU "${_llvmdylib}" 2>/dev/null \
      | grep -E 'LLVMInitialize(AArch64|X86)(Target|TargetInfo|TargetMC|AsmPrinter|AsmParser)$' \
      | sort -u | sed 's/^/    /' || echo "    (none matched -- SMOKING GUN if empty)"
    echo "  total exported LLVMInitialize* symbol count: $(nm -gU "${_llvmdylib}" 2>/dev/null | grep -c 'LLVMInitialize' || echo 0)"
  else
    echo "  WARN: no libLLVM*.dylib found to inspect"
  fi

  # (B) confirm LLVM_NO_DEAD_STRIP actually reached the real cmake invocation
  # (_cmake_flags.sh sets it for exactly this symptom; verify it was not dropped).
  echo "  --- (B) LLVM_NO_DEAD_STRIP in the generated CMakeCache -----------------"
  while IFS= read -r _cc; do
    echo "  ${_cc}:"
    grep -E 'LLVM_NO_DEAD_STRIP|LLVM_TARGETS_TO_BUILD|LLVM_BUILD_LLVM_DYLIB|LLVM_LINK_LLVM_DYLIB' \
      "${_cc}" 2>/dev/null | sed 's|^|    |' || echo "    (no matching cache entries)"
  done < <(find "${SRC_DIR}" "${PREFIX}" -maxdepth 6 -name CMakeCache.txt 2>/dev/null | head -5)

  # (C) staged link probes, cheapest first. Stage 1 is pure codegen with no linker
  # involved at all -- if THAT fails, -fuse-ld=lld was never the variable and the
  # whole lld-bundle line of investigation is closed.
  echo "  --- (C) staged probes ------------------------------------------------"
  _probe_stage() { # $1=label  $2=logfile  $3...=zig cc args
    local _label="$1"; shift
    local _log="$1"; shift
    echo "  [${_label}] running: zig cc $*"
    if DYLD_PRINT_LIBRARIES=1 "${PREFIX}/bin/zig" cc "$@" > "${_log}" 2>&1; then
      echo "  [${_label}] OK"
      echo "  [${_label}] libLLVM images dyld loaded:"
      grep -i "libLLVM" "${_log}" | sort -u | sed 's/^/      /' || true
      return 0
    fi
    echo "  [${_label}] FAIL -- full -v/dyld log follows:" >&2
    while IFS= read -r _l; do printf '      [%s] %s\n' "${_label}" "${_l}"; done < "${_log}" >&2 || true
    _probe_fail=1
    return 1
  }

  # stage 1: compile only, no linker in the picture
  _rc1=0
  _probe_stage "1/compile-only" "${_probe_dir}/s1.log" \
    -v -c -o "${_probe_dir}/probe.o" "${_probe_dir}/probe.c" || _rc1=$?
  # stage 2: default linker path (no -fuse-ld=lld)
  _rc2=0
  _probe_stage "2/default-link" "${_probe_dir}/s2.log" \
    -v -o "${_probe_dir}/probe_default" "${_probe_dir}/probe.c" || _rc2=$?
  # stage 3: the exact invocation the package test uses
  _rc3=0
  _probe_stage "3/fuse-ld-lld" "${_probe_dir}/s3.log" \
    -fuse-ld=lld -v -Wl,-rpath,/tmp -o "${_probe_dir}/probe_out" "${_probe_dir}/probe.c" || _rc3=$?

  echo "  --- probe summary ------------------------------------------------------"
  echo "  stage 1 (compile-only) : $([[ "${_rc1}" -eq 0 ]] && echo PASS || echo FAIL)"
  echo "  stage 2 (default-link) : $([[ "${_rc2}" -eq 0 ]] && echo PASS || echo FAIL)"
  echo "  stage 3 (-fuse-ld=lld) : $([[ "${_rc3}" -eq 0 ]] && echo PASS || echo FAIL)"
  echo "  --- probe output files (existence only, NOT evidence of success -- zig cc"
  echo "      creates the -o target before failing codegen) ------------------------"
  echo "  stage 1 file exists    : $([[ -f "${_probe_dir}/probe.o"       ]] && echo YES || echo NO)"
  echo "  stage 2 file exists    : $([[ -f "${_probe_dir}/probe_default" ]] && echo YES || echo NO)"
  echo "  stage 3 file exists    : $([[ -f "${_probe_dir}/probe_out"     ]] && echo YES || echo NO)"
  echo "  INTERPRETATION: stage 1 FAIL => codegen/TargetRegistry defect, lld irrelevant."
  echo "                  (A stage-1 PASS + stage-3 FAIL split would point at the lld"
  echo "                  path specifically, but only when both PASS/FAIL come from the"
  echo "                  exit-status lines above, not from file existence.)"

  if [[ "${_probe_fail}" -ne 0 ]]; then
    echo "  FAIL: one or more osx probe stages failed (see per-stage logs above)" >&2
    exit 1
  fi
  rm -rf "${_probe_dir}"
fi

if is_linux; then
  # zig itself only needs $ORIGIN/../lib, but Phase 2 below runs this same binary to
  # build langref, which dlopens libclang-cpp.so from the zig-llvm sub-output.
  patchelf --set-rpath '$ORIGIN/../lib/zig-llvm/lib:$ORIGIN/../lib' "${PREFIX}/bin/zig"
fi

# --- Phase 2: build langref via stage3 (full compiler with translate_c) ---
# Policy: Phase 2 langref only runs on NATIVE lanes. langref.html is
# architecture-independent HTML, so a native lane's output is exactly what a
# cross lane would (eventually) produce -- emulating a cross-built compiler
# under qemu just to regenerate identical HTML costs hours (e.g. linux-riscv64
# burned 2h30m+ in this single step under qemu-riscv64, run 31823428053 job
# 94841924369) for zero content difference. Docs are provided by other
# (native) platforms, so every cross lane skips it outright.
# Historical note: ppc64le was the first lane special-cased this way, because
# 0.16.0 std/Io/Threaded uses pthread_*, and cross-linking to glibc 2.17 lacks
# -lpthread -- that pthread/glibc-2.17 gap is no longer the operative
# condition, since ALL cross lanes are now skipped regardless of reason.
_can_run_stage3() {
  if ! is_cross; then return 0; fi
  return 1
}

if [[ "${SKIP_LANGREF:-0}" == "1" ]]; then
  echo "INFO: Phase 2 langref skipped: SKIP_LANGREF=1 (local dev override)" >&2
elif _can_run_stage3; then
  dbg echo "=== PHASE 2: building langref via stage3 zig ==="
  _stage3_runner=()
  if is_cross && is_linux; then
    _stage3_runner=("qemu-${ZIG_QEMU_ARCH}")
  fi

  # Zig hardcodes qemu-<arch> lookup. The regular qemu-powerpc64le variant
  _qemu_shadow_dir=""
  if [ -n "${QEMU_EXECVE:-}" ] && [ -x "${QEMU_EXECVE}" ]; then
    _qemu_shadow_dir=$(mktemp -d)
    ln -sf "${QEMU_EXECVE}" "${_qemu_shadow_dir}/qemu-${ZIG_QEMU_ARCH}"
    export PATH="${_qemu_shadow_dir}:${PATH}"
    dbg echo "PATH shadow: qemu-${ZIG_QEMU_ARCH} -> ${QEMU_EXECVE}"
  fi

  # Mirror Phase 1's --libc (EXTRA_ZIG_ARGS above) into Phase 2's langref build so
  # build.zig-02-doctest-forward-target.patch's doctest-libc option can thread it into
  # the nested doctest sub-compiles alongside doctest-target. Only set for is_linux &&
  # is_cross (see that block above); empty on native and non-linux cross, so no extra
  # flags are added there. --libc-runtimes is deliberately NOT forwarded here: it is a
  # zig-build-frontend-only concept, never accepted by build-exe/test's CLI parser.
  _phase2_zig_args=(-Ddoctest-target="${ZIG_TRIPLET}")
  if [[ -n "${ZIG_DOCTEST_LIBC_FILE:-}" ]]; then
    _phase2_zig_args+=(-Ddoctest-libc="${ZIG_DOCTEST_LIBC_FILE}")
  fi

  # ZIGDIAG (PR17 win-64 native PHASE2 segfault, run 32062105848): capture the
  # exact zig binary and argv about to run, on every native lane, before the
  # invocation that is known to segfault on win-64. Diagnostics only -- must
  # not change pass/fail outcome.
  echo "=== ZIGDIAG langref pre-flight ===" >&2
  if [[ -f "${PREFIX}/bin/zig" ]]; then
    echo "  ${PREFIX}/bin/zig exists, size: $(wc -c < "${PREFIX}/bin/zig" 2>/dev/null || echo unknown) bytes" >&2
  else
    echo "  ${PREFIX}/bin/zig MISSING -- langref invocation below will fail immediately" >&2
  fi
  "${PREFIX}/bin/zig" version >&2 || echo "  WARN: zig version failed" >&2
  "${PREFIX}/bin/zig" env >&2 || echo "  WARN: zig env failed" >&2
  echo "  argv: $(IFS=' '; echo "${_stage3_runner[*]:-}") ${PREFIX}/bin/zig build langref --prefix ${PREFIX} -Dversion-string=${PKG_VERSION} $(IFS=' '; echo "${_phase2_zig_args[*]}")" >&2
  echo "=== end ZIGDIAG langref pre-flight ===" >&2

  (
    cd "${cmake_source_dir}" &&
    "${_stage3_runner[@]+"${_stage3_runner[@]}"}" "${PREFIX}/bin/zig" build langref \
      --prefix "${PREFIX}" \
      -Dversion-string="${PKG_VERSION}" \
      "${_phase2_zig_args[@]}"
  ) || {
    _phase2_rc=$?
    _phase2_sig=0
    [[ ${_phase2_rc} -gt 128 ]] && _phase2_sig=$(( _phase2_rc - 128 )) || true
    echo "  ZIGDIAG: langref invocation exit code ${_phase2_rc} (signal ${_phase2_sig})" >&2
    if is_not_unix; then
      # win-64-only: re-run once with --verbose so the log shows the last
      # build-runner step reached before the segfault (docgen compile,
      # doctest, or the build runner itself). Failure-tolerant; does not
      # change the outcome below. Gated to win-64 so the currently-GREEN
      # linux-64/osx-arm64 native lanes see no extra output.
      echo "=== ZIGDIAG win-64 langref failure: re-running with --verbose to localize crash step ===" >&2
      _zigdiag_verbose_log="$(mktemp "${TMPDIR:-/tmp}/zig-langref-verbose.XXXXXX" 2>/dev/null || echo "${TMPDIR:-/tmp}/zig-langref-verbose.$$")"
      _zigdiag_verbose_rc=0
      (
        cd "${cmake_source_dir}" &&
        "${_stage3_runner[@]+"${_stage3_runner[@]}"}" "${PREFIX}/bin/zig" build langref --verbose \
          --prefix "${PREFIX}" \
          -Dversion-string="${PKG_VERSION}" \
          "${_phase2_zig_args[@]}"
      ) >"${_zigdiag_verbose_log}" 2>&1 || _zigdiag_verbose_rc=$?
      echo "  --verbose retry exit code: ${_zigdiag_verbose_rc}" >&2
      echo "  --- last 80 lines of --verbose retry log ---" >&2
      tail -80 "${_zigdiag_verbose_log}" >&2 || true
      echo "  --- end --verbose retry log ---" >&2
      for _crash_glob in "${SRC_DIR}"/core* "${SRC_DIR}"/*.dmp "${TMPDIR:-/tmp}"/core* "${cmake_source_dir}"/core*; do
        compgen -G "${_crash_glob}" >/dev/null 2>&1 && echo "  possible crash artifact: ${_crash_glob}" >&2 || true
      done
      rm -f "${_zigdiag_verbose_log}"
      echo "=== end ZIGDIAG win-64 langref failure ===" >&2
    fi
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

dbg echo "Post-install implementation package: ${PKG_NAME}"
mv "${PREFIX}"/bin/zig "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig

# Non-unix conda convention: artifacts go under Library/
if is_not_unix; then
  dbg echo "Relocating to Library/ for non-unix conda convention"
  mkdir -p "${PREFIX}/Library/bin" "${PREFIX}/Library/lib" "${PREFIX}/Library/doc"
  mv "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig "${PREFIX}"/Library/bin/"${CONDA_TRIPLET}"-zig
  mv "${PREFIX}"/lib/zig "${PREFIX}"/Library/lib/zig
  [[ -d "${PREFIX}/doc" ]] && mv "${PREFIX}"/doc/* "${PREFIX}"/Library/doc/
fi

echo "=== MINGW IMPORT LIB DIAGNOSTIC ===" >&2
echo "BUILD_ZIG=${BUILD_ZIG}" >&2
echo "PATH=${PATH}" >&2
command -v "${BUILD_ZIG}" >&2 || echo "command -v ${BUILD_ZIG}: not found" >&2
type -a "${BUILD_ZIG}" >&2 2>&1 || true
echo "=== end MINGW IMPORT LIB DIAGNOSTIC ===" >&2
source "${RECIPE_DIR}/building/_mingw.sh"
generate_mingw_import_libs

dbg echo "=== Build installed for package: ${PKG_NAME} ==="
