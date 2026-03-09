# Reusable function: strip atexit from a MinGW import lib
# Used by both the fast-fail stub test AND the real Phase 1.5.
# Any bug here surfaces in ~5 s (stub) instead of ~90 min (post-build).
#
# Usage: strip_atexit_from_implib <implib_path> <zig_bin> [dll_fallback]
#   implib_path : path to .dll.a to clean in-place
#   zig_bin     : path to zig executable (for dlltool)
#   dll_fallback: DLL base name when __IMPORT_DESCRIPTOR_ is missing (default: libLLVM-20)
#
# Returns 0 on success (or if no atexit found), 1 on failure.
strip_atexit_from_implib() {
  local _implib="$1"
  local _zig_bin="$2"
  local _dll_fallback="${3:-libLLVM-20}"
  local _dir _dll_name _tmp

  _dir=$(dirname "${_implib}")
  _tmp="${_dir}/_strip_atexit_tmp"
  mkdir -p "${_tmp}"

  # Check if atexit is present at all
  if ! nm "${_implib}" 2>/dev/null | grep -q ' T atexit'; then
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
  # Suppress xtrace: nm on a large import lib (49K+ symbols) floods the CI log.
  { set +x; } 2>/dev/null
  nm "${_implib}" 2>/dev/null | grep ' T ' | awk '{print $3}' | grep -v '^atexit$' > "${_tmp}/exports.txt"
  nm "${_implib}" 2>/dev/null | grep ' I __imp_' | awk '{print $3}' | sed 's/__imp_//' | grep -v '^atexit$' >> "${_tmp}/exports.txt"
  sort -u "${_tmp}/exports.txt" -o "${_tmp}/exports.txt"
  set -x

  local _nsyms
  _nsyms=$(wc -l < "${_tmp}/exports.txt")
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

  # Regenerate import lib
  if ! "${_zig_bin}" dlltool -d "${_tmp}/llvm.def" -l "${_implib}" \
      -D "${_dll_name}.dll" 2>"${_tmp}/dlltool_err.txt"; then
    echo "    ERROR: zig dlltool failed"
    cat "${_tmp}/dlltool_err.txt" | head -10 | sed 's/^/      /'
    rm -rf "${_tmp}"
    return 1
  fi
  echo "    OK: import lib regenerated"

  # Verify atexit gone
  if nm "${_implib}" 2>/dev/null | grep -q ' T atexit'; then
    echo "    ERROR: atexit still present after dlltool!"
    rm -rf "${_tmp}"
    return 1
  fi
  echo "    OK: atexit removed"

  rm -rf "${_tmp}"
  return 0
}
