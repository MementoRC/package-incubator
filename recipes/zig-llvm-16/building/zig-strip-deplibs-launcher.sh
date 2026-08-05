#!/usr/bin/env bash
# zig-strip-deplibs-launcher.sh -- CMAKE_C/CXX_COMPILER_LAUNCHER shim for the
# runtimes (libc++/libc++abi/libunwind) build. CMake invokes launchers as:
#   <launcher> <real-compiler> <args...>
# for COMPILE rules only -- CMAKE_*_COMPILER_LAUNCHER is never applied to
# link rules (CMake documented behaviour), so this never touches the final
# libc++.so/.dylib/.dll link, only individual .o compiles.
#
# Background (linux-ppc64le CI run 31321865432, and any lane building a
# NATIVE build-arch libc++ for host tools): zig's clang frontend embeds ELF
# .deplibs records (SHT_LLVM_DEPENDENT_LIBRARIES) for pthread/rt in some
# libc++/libc++abi translation units (cxa_guard.cpp.o, chrono.cpp.o). lld
# fails to resolve the bare "pthread"/"rt" specifiers because all glibc
# deps are passed to the link as absolute zig-cache paths (zero -L flags
# cover them). The explicit -lpthread/-lc on the link line already provide
# the real linkage -- the .deplibs record is pure redundancy.
# See _runtimes_build.sh:326-354 for the full history of ruled-out fixes
# (--no-dependent-libraries is silently dropped by zig cc's -Wl, translator;
# -fno-autolink / LIBCXX_HAS_*_LIB knobs do not suppress these two TUs).
#
# Fix: strip the .deplibs section from the compiled .o with objcopy,
# post-compile. Gated by ZIG_STRIP_DEPLIBS=1, exported around both runtimes
# phases (_runtimes_build.sh:443/454 native, _runtimes_target.sh:55/58
# target). Strict no-op when unset -- this script also runs unconditionally
# on non-Linux / unaffected builds via CMAKE_*_COMPILER_LAUNCHER.
#
# objcopy source: system PATH (binutils), NOT llvm-objcopy (this recipe
# builds LLVM with -DLLVM_TOOL_LLVM_OBJCOPY_BUILD=OFF -- see _llvm_build.sh
# -- and Phase 2 LLVM runs AFTER this runtimes phase regardless) and NOT
# `zig objcopy` (zig 0.16.0's built-in objcopy has no --remove-section flag
# at all, and its ELF-to-ELF path is a hard `fatal("unimplemented")` --
# verified against compiler/objcopy.zig shipped by the pinned zig package).
# System objcopy is not declared in requirements:build, matching the
# existing precedent of `readelf` (part of the same binutils package) being
# invoked unconditionally and successfully in this recipe's own
# post-install.sh on every Linux lane. Guarded with `command -v` below and
# never fails the build if missing, or if the object has no .deplibs
# section (the normal case for the vast majority of objects).

"$@"
_rc=$?

# Strict no-op: unset, or the compile itself already failed.
if [[ "${ZIG_STRIP_DEPLIBS:-0}" != "1" ]] || [[ ${_rc} -ne 0 ]]; then
  exit "${_rc}"
fi

# Locate the -o <file> argument. argv here is <real-compiler> <args...>;
# only object-file compiles (-o *.o) are candidates -- link invocations
# (-o libc++.so.1 etc.) are structurally excluded already (CMAKE_*_COMPILER_
# LAUNCHER never wraps link rules), this is belt-and-suspenders on top.
_out=""
_prev=""
for _arg in "$@"; do
  if [[ "${_prev}" == "-o" ]]; then
    _out="${_arg}"
    break
  fi
  _prev="${_arg}"
done

[[ "${_out}" == *.o ]] || exit "${_rc}"
[[ -f "${_out}" ]] || exit "${_rc}"

_objcopy="$(command -v objcopy 2>/dev/null || true)"
if [[ -z "${_objcopy}" ]]; then
  echo "WARNING: zig-strip-deplibs-launcher.sh: no objcopy on PATH, cannot strip .deplibs from ${_out} (pthread/rt deplib link failures may recur)" >&2
  exit "${_rc}"
fi

# --remove-section silently no-ops on objects without a .deplibs section
# (the normal case); any other objcopy failure must never fail the build --
# the real compile already succeeded above and is the source of truth.
"${_objcopy}" --remove-section=.deplibs "${_out}" >/dev/null 2>&1 || true

exit "${_rc}"
