# Reusable function: strip atexit from a MinGW import lib
# Used by both the fast-fail stub test AND the real Phase 1.5.
# Any bug here surfaces in ~5 s (stub) instead of ~90 min (post-build).
#
# Usage: strip_atexit_from_implib <implib_path> <zig_bin> [dll_fallback] [machine]
#   implib_path : path to .dll.a to clean in-place
#   zig_bin     : path to zig executable (for dlltool)
#   dll_fallback: DLL base name when __IMPORT_DESCRIPTOR_ is missing (default: libLLVM-20)
#   machine     : dlltool machine type (e.g. arm64, i386:x86-64). Auto-detected if omitted.
#
# Returns 0 on success (or if no atexit found), 1 on failure.
#
# Note on aarch64: GNU nm (MSYS2 binutils) cannot read aarch64 PE short import
# entries (IMAGE_FILE_MACHINE_ARM64), producing zero symbol output despite the
# import lib being valid. We use `strings` for both detection and extraction:
# short import entries store DLL name + symbol name as consecutive null-terminated
# strings, which `strings` reliably extracts regardless of COFF machine type.
strip_atexit_from_implib() {
  local _implib="$1"
  local _zig_bin="$2"
  local _dll_fallback="${3:-libLLVM-20}"
  local _machine="${4:-}"
  local _dir _dll_name _tmp

  _dir=$(dirname "${_implib}")
  _tmp="${_dir}/_strip_atexit_tmp"
  mkdir -p "${_tmp}"

  # Check if atexit is present.
  # Use `strings` instead of `nm` — GNU nm can't read aarch64 COFF short import
  # entries, but `strings` finds symbol names in any binary format.
  { set +x; } 2>/dev/null
  local _has_atexit=false
  if strings -a "${_implib}" 2>/dev/null | grep -qx 'atexit'; then
    _has_atexit=true
  fi
  set -x

  if ! ${_has_atexit}; then
    echo "    no atexit in import lib — nothing to do"
    rm -rf "${_tmp}"
    return 0
  fi
  echo "    atexit found — regenerating import lib via dlltool..."

  # Get DLL name from IMPORT_DESCRIPTOR (awk NR==1 avoids SIGPIPE from head -1)
  _dll_name=$(nm "${_implib}" 2>/dev/null \
    | grep '__IMPORT_DESCRIPTOR_' \
    | awk 'NR==1{print $3}' \
    | sed 's/__IMPORT_DESCRIPTOR_//')
  [[ -z "${_dll_name}" ]] && _dll_name="${_dll_fallback}"
  echo "    DLL name: ${_dll_name}.dll"

  # Extract exported symbols, exclude atexit.
  # Try nm first (works on x86_64 import libs), then fall back to strings
  # (works on all architectures including aarch64 short import entries).
  { set +x; } 2>/dev/null
  nm "${_implib}" 2>/dev/null | grep ' T ' | awk '{print $3}' | grep -v '^atexit$' > "${_tmp}/exports.txt"
  nm "${_implib}" 2>/dev/null | grep ' I __imp_' | awk '{print $3}' | sed 's/__imp_//' | grep -v '^atexit$' >> "${_tmp}/exports.txt"
  sort -u "${_tmp}/exports.txt" -o "${_tmp}/exports.txt"

  local _nsyms
  _nsyms=$(wc -l < "${_tmp}/exports.txt")

  # If nm produced too few symbols (< 100), it can't parse this import lib format.
  # Fall back to `strings`: short import entries contain "DLLname\0symbol\0" pairs,
  # so strings extracts all symbol names. Filter to C/C++ identifiers, exclude
  # known non-symbol strings (DLL name, section names, archive metadata).
  if [[ "${_nsyms}" -lt 100 ]]; then
    echo "    nm found only ${_nsyms} symbols — falling back to strings extraction..."
    strings -a "${_implib}" 2>/dev/null \
      | grep -xE '[_A-Za-z?@][_A-Za-z0-9?@$]*' \
      | grep -v "^${_dll_name}\$" \
      | grep -v "^${_dll_name}\.dll\$" \
      | grep -v '^__IMPORT_DESCRIPTOR_\|^__NULL_IMPORT_DESCRIPTOR' \
      | grep -v '^atexit$' \
      | sort -u > "${_tmp}/exports.txt"
    _nsyms=$(wc -l < "${_tmp}/exports.txt")
    echo "    strings extracted ${_nsyms} symbols"
  fi
  set -x

  echo "    .def has ${_nsyms} symbols (atexit excluded)"

  if [[ "${_nsyms}" -eq 0 ]]; then
    echo "    ERROR: export list is empty after stripping atexit!"
    rm -rf "${_tmp}"
    return 1
  fi

  # Create .def file — use awk (not while-read loop) to avoid 49K trace lines
  { set +x; } 2>/dev/null
  {
    echo "LIBRARY ${_dll_name}.dll"
    echo "EXPORTS"
    awk 'NF{print "  " $0}' "${_tmp}/exports.txt"
  } > "${_tmp}/llvm.def"
  set -x

  # Regenerate import lib (pass -m for machine type if specified)
  local _dlltool_args=(-d "${_tmp}/llvm.def" -l "${_implib}" -D "${_dll_name}.dll")
  [[ -n "${_machine}" ]] && _dlltool_args+=(-m "${_machine}")
  echo "    dlltool args: ${_dlltool_args[*]}"
  if ! "${_zig_bin}" dlltool "${_dlltool_args[@]}" 2>"${_tmp}/dlltool_err.txt"; then
    echo "    ERROR: zig dlltool failed"
    cat "${_tmp}/dlltool_err.txt" | head -10 | sed 's/^/      /'
    rm -rf "${_tmp}"
    return 1
  fi
  echo "    OK: import lib regenerated"

  # Verify atexit gone — use strings (same reason as detection: nm fails on aarch64)
  { set +x; } 2>/dev/null
  local _still_has_atexit=false
  if strings -a "${_implib}" 2>/dev/null | grep -qx 'atexit'; then
    _still_has_atexit=true
  fi
  set -x

  if ${_still_has_atexit}; then
    echo "    ERROR: atexit still present after dlltool!"
    rm -rf "${_tmp}"
    return 1
  fi
  echo "    OK: atexit removed"

  rm -rf "${_tmp}"
  return 0
}
