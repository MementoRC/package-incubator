# Force-load helper for zig cc/c++ on macOS.
# Sourced by zig-force-load-cc.sh and zig-force-load-cxx.sh.
#
# Intercepts -Wl,-all_load and -Wl,-force_load,<archive> flags that zig's
# Mach-O linker doesn't support. Extracts .o files from the archives and
# passes them directly to zig.
#
# Expects caller to set: _ZIG_MODE ("cc" or "c++")

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_self_dir}/_zig-cc-common.sh"

# _exec_args is now set by _zig-cc-common.sh (mode, -target, -mcpu, sysroot, filtered args).
# But _zig-cc-common.sh already strips -Wl,-all_load and -Wl,-force_load,* silently.
# We need to intercept them BEFORE that filtering. Re-scan the original "$@".

_tmpdir=""
_cleanup() { [[ -n "${_tmpdir}" ]] && rm -rf "${_tmpdir}"; }
trap _cleanup EXIT

_all_load=0
_force_load_archives=()
_other_args=()

_i=0
_argv=("$@")
_argc=${#_argv[@]}

while [[ $_i -lt $_argc ]]; do
    _arg="${_argv[$_i]}"
    case "$_arg" in
        -Wl,-all_load)
            _all_load=1
            ;;
        -Wl,-force_load,*)
            _archive="${_arg#-Wl,-force_load,}"
            _force_load_archives+=("${_archive}")
            ;;
        -all_load)
            _all_load=1
            ;;
        -force_load)
            _next_i=$((_i + 1))
            if [[ $_next_i -lt $_argc ]]; then
                _force_load_archives+=("${_argv[$_next_i]}")
                _i=$_next_i
            fi
            ;;
        *)
            _other_args+=("$_arg")
            ;;
    esac
    ((_i++))
done

# If no force-load flags found, just exec normally
if [[ ${_all_load} -eq 0 ]] && [[ ${#_force_load_archives[@]} -eq 0 ]]; then
    exec "@ZIG_BIN@" "${_exec_args[@]}"
fi

# Collect archives to extract
_archives_to_extract=()

if [[ ${_all_load} -eq 1 ]]; then
    for _a in "${_other_args[@]}"; do
        if [[ "$_a" == *.a ]] && [[ -f "$_a" ]]; then
            _archives_to_extract+=("$(cd "$(dirname "$_a")" && pwd)/$(basename "$_a")")
        fi
    done
fi

for _a in "${_force_load_archives[@]}"; do
    if [[ -f "$_a" ]]; then
        _archives_to_extract+=("$(cd "$(dirname "$_a")" && pwd)/$(basename "$_a")")
    else
        echo "WARNING: zig-force-load-${_ZIG_MODE}: archive not found: $_a" >&2
    fi
done

# Dedupe archives by basename (skip if same .a appears twice)
_seen_archives=""
_archives_dedup=()
for _archive in "${_archives_to_extract[@]}"; do
    _abase="$(basename "${_archive}")"
    case " ${_seen_archives} " in
        *" ${_abase} "*) ;;  # already seen — skip
        *) _archives_dedup+=("${_archive}"); _seen_archives="${_seen_archives} ${_abase}" ;;
    esac
done
_archives_to_extract=("${_archives_dedup[@]}")

# Extract .o files from archives. Dedup is scoped to (archive, basename):
# we skip an object only when it is the same file extracted twice from the
# *same* archive (which `ar x` already prevents in normal cases). We do NOT
# dedup across archives by bare basename: many LLVM archives contain
# same-named-but-different-source objects (Driver.cpp.o appears in 6 archives:
# liblld{COFF,ELF,MachO,MinGW,Wasm} and libclangDriver; Error.cpp.o in
# LLVM{Support,TableGen,Object}; Utils.cpp.o in 4 LLVM archives, etc.).
# Cross-archive basename dedup silently dropped legitimate code.
# (The earlier rationale claiming libLLVMSupport.a re-archives
# libLLVMDemangle.a was wrong: build.ninja shows it as an order-only `||`
# dependency, and the two archives share no member basenames.)
_extracted_objects=()
_seen_objs=""
if [[ ${#_archives_to_extract[@]} -gt 0 ]]; then
    _tmpdir="$(mktemp -d)"
    _idx=0
    for _archive in "${_archives_to_extract[@]}"; do
        _subdir="${_tmpdir}/ar_${_idx}"
        mkdir -p "${_subdir}"
        (cd "${_subdir}" && ar x "${_archive}")
        _arch_base="$(basename "${_archive}")"
        for _obj in "${_subdir}"/*.o; do
            [[ -f "$_obj" ]] || continue
            _obase="$(basename "${_obj}")"
            _dedup_key="${_arch_base}:${_obase}"
            case " ${_seen_objs} " in
                *" ${_dedup_key} "*) ;;  # same object extracted twice from same archive — skip
                *) _extracted_objects+=("$_obj"); _seen_objs="${_seen_objs} ${_dedup_key}" ;;
            esac
        done
        ((_idx++))
    done
fi

# Strip force-load directives and bare .a paths whose contents are now
# inlined as _extracted_objects. _exec_args was built by _zig-cc-common.sh
# from the full original argv, so it still contains -Wl,-all_load,
# -Wl,-force_load,*, -force_load <archive>, and the bare *.a paths.
# Leaving those in causes ld64.lld to force-load the archives a second time
# (in addition to the already-extracted .o objects) → duplicate symbols.
_final_exec_args=()
_skip_next_fa=0
for _ea in "${_exec_args[@]}"; do
    if (( _skip_next_fa )); then
        _skip_next_fa=0
        continue
    fi
    case "$_ea" in
        -Wl,-all_load|-all_load) ;;
        -Wl,-force_load,*) ;;
        -force_load) _skip_next_fa=1 ;;
        *.a)
            # When -all_load was set, every .a in args got extracted; drop them all.
            # Otherwise keep .a paths (only force_load archives were extracted, and
            # those came embedded inside -Wl,-force_load,X.a which is already stripped).
            if [[ ${_all_load} -eq 1 ]]; then
                :
            else
                _final_exec_args+=("$_ea")
            fi
            ;;
        *) _final_exec_args+=("$_ea") ;;
    esac
done

exec "@ZIG_BIN@" "${_final_exec_args[@]}" "${_extracted_objects[@]}"
