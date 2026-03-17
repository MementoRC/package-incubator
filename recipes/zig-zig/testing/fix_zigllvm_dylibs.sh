#!/usr/bin/env bash
# Simulate zig-llvm post-install: rewrite @rpath → @loader_path for all
# zig-llvm dylibs in the current PREFIX.  This runs during the zig-zig-compiler
# test to verify the rewrite logic works on the cached (un-fixed) zig-llvm
# package.  Once zig-llvm is rebuilt with the real post-install fix, this
# script becomes a no-op (everything already @loader_path).
set -euo pipefail

ZIGLLVM_LIB="${PREFIX}/lib/zig-llvm/lib"
if [[ ! -d "${ZIGLLVM_LIB}" ]]; then
  echo "zig-llvm lib dir not found at ${ZIGLLVM_LIB}, skipping"
  exit 0
fi

echo "=== [test] Rewriting zig-llvm dylib refs to @loader_path ==="
echo "  ZIGLLVM_LIB=${ZIGLLVM_LIB}"

_total=0
for _lib in "${ZIGLLVM_LIB}/"*.dylib; do
  [[ -L "${_lib}" ]] && continue
  [[ ! -f "${_lib}" ]] && continue
  _name=$(basename "${_lib}")
  _changed=0

  # Fix install name (LC_ID_DYLIB)
  _old_id=$(otool -D "${_lib}" 2>/dev/null | tail -1)
  if [[ -n "${_old_id}" && "${_old_id}" != "@loader_path/${_name}" ]]; then
    install_name_tool -id "@loader_path/${_name}" "${_lib}" || {
      echo "  WARN: -id failed for ${_name}, stripping codesign"
      codesign --remove-signature "${_lib}" 2>/dev/null || true
      install_name_tool -id "@loader_path/${_name}" "${_lib}"
    }
    echo "  id ${_name}: ${_old_id} -> @loader_path/${_name}"
    _changed=1
  fi

  # Fix load deps (LC_LOAD_DYLIB)
  while IFS= read -r _dep_line; do
    _dep=$(echo "${_dep_line}" | awk '{print $1}')
    _dep_base=$(basename "${_dep}")
    case "${_dep_base}" in
      libLLVM*|libclang*|libc++*|libunwind*)
        _new="@loader_path/${_dep_base}"
        if [[ "${_dep}" != "${_new}" ]]; then
          install_name_tool -change "${_dep}" "${_new}" "${_lib}" 2>/dev/null || {
            codesign --remove-signature "${_lib}" 2>/dev/null || true
            install_name_tool -change "${_dep}" "${_new}" "${_lib}"
          }
          _changed=1
        fi
        ;;
    esac
  done < <(otool -L "${_lib}" 2>/dev/null | tail -n +2)

  # Remove rpaths
  while IFS= read -r _rp; do
    _rp=$(echo "${_rp}" | awk '{print $2}')
    [[ -z "${_rp}" ]] && continue
    install_name_tool -delete_rpath "${_rp}" "${_lib}" 2>/dev/null || true
  done < <(otool -l "${_lib}" 2>/dev/null | grep -A2 'cmd LC_RPATH' | grep 'path ')

  if [[ ${_changed} -eq 1 ]]; then
    _total=$((_total + 1))
    echo "  fixed ${_name}"
  fi
done

# libc++.1.0.dylib references @rpath/libc++abi.1.dylib, but the rpath on the zig
# binary resolves to $PREFIX/lib/ (conda-forge) instead of $PREFIX/lib/zig-llvm/lib/
# where the real libc++abi lives. Rewrite to @loader_path so it finds its sibling.
# TODO: remove once zig-llvm integrates abi into libc++ (LIBCXX_STATICALLY_LINK_ABI_IN_SHARED_LIBRARY=ON)
_libcxx="${ZIGLLVM_LIB}/libc++.1.0.dylib"
if [[ -f "${_libcxx}" ]]; then
  _abi_ref=$(otool -L "${_libcxx}" 2>/dev/null | awk '{print $1}' | grep 'libc++abi' || true)
  if [[ -n "${_abi_ref}" ]] && [[ "${_abi_ref}" != "@loader_path/"* ]]; then
    _abi_base=$(basename "${_abi_ref}")
    install_name_tool -change "${_abi_ref}" \
      "@loader_path/${_abi_base}" "${_libcxx}" 2>/dev/null || {
      codesign --remove-signature "${_libcxx}" 2>/dev/null || true
      install_name_tool -change "${_abi_ref}" \
        "@loader_path/${_abi_base}" "${_libcxx}"
    }
    echo "  libc++: ${_abi_ref} -> @loader_path/${_abi_base}"
    _total=$((_total + 1))
  fi
fi

echo "  Total dylibs fixed: ${_total}"

# --- Fix zig binary's LC_LOAD_DYLIB entries ---
# Rewrite any LLVM/libc++ refs (bare names, @rpath/, or @loader_path/) to
# @loader_path/../lib/zig-llvm/lib/<name>.  Must use @loader_path (not @rpath)
# because rattler-build strips rpaths not in its prefix allowlist.
_zig_bin=$(find "${PREFIX}/bin" -name '*-zig' -not -type l 2>/dev/null | head -1)
if [[ -z "${_zig_bin}" ]]; then
  _zig_bin=$(find "${PREFIX}/bin" -name '*-zig' 2>/dev/null | head -1)
fi

_zig_llvm_rel="@loader_path/../lib/zig-llvm/lib"

if [[ -n "${_zig_bin}" ]]; then
  echo ""
  echo "=== [test] Fixing zig binary load commands ==="
  echo "  zig binary: ${_zig_bin}"
  _zig_fixed=0

  while IFS= read -r _dep_line; do
    _dep=$(echo "${_dep_line}" | awk '{print $1}')
    _dep_base=$(basename "${_dep}")
    case "${_dep_base}" in
      libLLVM*|libclang*|libc++*|libunwind*)
        _new="${_zig_llvm_rel}/${_dep_base}"
        if [[ "${_dep}" != "${_new}" ]] && [[ -f "${ZIGLLVM_LIB}/${_dep_base}" || -L "${ZIGLLVM_LIB}/${_dep_base}" ]]; then
          install_name_tool -change "${_dep}" "${_new}" "${_zig_bin}" 2>/dev/null || {
            codesign --remove-signature "${_zig_bin}" 2>/dev/null || true
            install_name_tool -change "${_dep}" "${_new}" "${_zig_bin}"
          }
          echo "  ${_dep} -> ${_new}"
          _zig_fixed=$((_zig_fixed + 1))
        fi
        ;;
    esac
  done < <(otool -L "${_zig_bin}" 2>/dev/null | tail -n +2)

  echo "  Total zig binary refs fixed: ${_zig_fixed}"
fi

echo "=== [test] Done ==="
