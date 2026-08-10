# MinGW import lib pre-generation helpers.
# Source this file and call generate_mingw_import_libs().
# Requires: PREFIX, BUILD_PREFIX, BUILD_ZIG, ZIG_TRIPLET, RECIPE_DIR
# and the dbg() function defined in build.sh.

source "${RECIPE_DIR}/building/_common.sh"
source "${RECIPE_DIR}/building/_diag.sh"  # diag_fail (idempotent; build-zig.sh already sources this)

function generate_mingw_import_libs() {
  # Workaround for ziglang/zig#14919: add synchronization.def so zig can generate
  # libsynchronization.a when cross-compiling to Windows (consumers using -lsynchronization).
  # IMPORTANT: LIBRARY must be api-ms-win-core-synch-l1-2-0.dll, NOT synchronization.dll.
  # "synchronization.dll" is neither a real DLL on disk nor a valid API Set Schema name -- it doesn't
  # exist as a physical file in Windows or MSYS2. The real MinGW-w64 alias points to
  # libapi-ms-win-core-synch-l1-2-0.a, whose LIBRARY directive is api-ms-win-core-synch-l1-2-0.dll.
  # Windows API Set Schema resolves api-ms-win-* names to the actual host DLL at runtime.
  if is_not_unix; then
    _zig_lib="${PREFIX}/Library/lib/zig"
  else
    _zig_lib="${PREFIX}/lib/zig"
  fi
  _mingw_common="${_zig_lib}/libc/mingw/lib-common"
  if [[ -d "${_mingw_common}" ]]; then
    cat > "${_mingw_common}/synchronization.def" << 'SYNCHRONIZATION_DEF'
LIBRARY api-ms-win-core-synch-l1-2-0.dll

EXPORTS

DeleteSynchronizationBarrier
EnterSynchronizationBarrier
InitializeConditionVariable
InitializeSynchronizationBarrier
InitOnceBeginInitialize
InitOnceComplete
InitOnceExecuteOnce
InitOnceInitialize
SignalObjectAndWait
Sleep
SleepConditionVariableCS
SleepConditionVariableSRW
WaitOnAddress
WakeAllConditionVariable
WakeByAddressAll
WakeByAddressSingle
WakeConditionVariable
SYNCHRONIZATION_DEF
  fi

  # Pre-generate Windows PE import libraries (.a) from zig's MinGW .def/.def.in files.
  # MinGW consumers call -print-search-dirs to find library search paths, then look
  # for libXXX.a files at those paths.  zig generates import libs internally at link
  # time (cached in ~/.cache/zig/), but consumers need them at a fixed, known location.
  #
  # Two types of source files exist in lib-common/:
  #   .def     -- ready to use directly with dlltool (e.g. shlwapi.def)
  #   .def.in  -- C preprocessor templates that conditionally include exports by
  #              architecture using macros from def-include/func.def.in
  #              (e.g. kernel32.def.in, ws2_32.def.in, ole32.def.in)
  #
  # uuid is special: compiled from libsrc/uuid.c (no DLL import lib needed).
  # Only generates files that are missing; safe to re-run.
  #
  # Target arch detection for dlltool machine type and zig cc -target.
  # ZIG_TRIPLET is e.g. "x86_64-windows-gnu" or "aarch64-windows-gnu".
  _win_arch="${ZIG_TRIPLET%%-*}"
  case "${_win_arch}" in
    x86_64)         _dlltool_machine="i386:x86-64"; _win_target="x86_64-windows-gnu" ;;
    aarch64)        _dlltool_machine="arm64";        _win_target="aarch64-windows-gnu" ;;
    x86|i386|i686)  _dlltool_machine="i386";         _win_target="x86-windows-gnu" ;;
    *)              _dlltool_machine="i386:x86-64"; _win_target="x86_64-windows-gnu"
                    echo "WARN: unknown Windows arch '${_win_arch}', defaulting to x86_64" ;;
  esac
  if [[ -d "${_mingw_common}" ]]; then
    # Prefer the FRESHLY-BUILT zig we are about to ship (installed + renamed by
    # build-zig.sh:750 to "${CONDA_TRIPLET}-zig") so the staged import libs are
    # produced by the zig our own mingw patches govern, not a previously
    # published bootstrap package. CONDA_TRIPLET is the target triplet (set in
    # recipe.yaml env); layout mirrors build-zig.sh's is_not_unix relocation.
    if is_not_unix; then
      _zig_bin_fresh="${PREFIX}/Library/bin/${CONDA_TRIPLET}-zig"
    else
      _zig_bin_fresh="${PREFIX}/bin/${CONDA_TRIPLET}-zig"
    fi

    # Fallback: the BUILD machine's bootstrap zig (CONDA_ZIG_BUILD), needed for
    # cross-compilation targets (e.g. win-arm64 built on win-64) where the
    # freshly-built zig binary is for the wrong architecture and can't execute.
    # BUILD_ZIG is the binary name (not a full path), so resolve via PATH first,
    # then fall back to explicit BUILD_PREFIX locations.
    _zig_bin_boot="$(command -v "${BUILD_ZIG}" 2>/dev/null || true)"
    if [[ -z "${_zig_bin_boot}" ]]; then
      if is_not_unix; then
        _zig_bin_boot="${BUILD_PREFIX}/Library/bin/${BUILD_ZIG}"
      else
        _zig_bin_boot="${BUILD_PREFIX}/bin/${BUILD_ZIG}"
      fi
    fi

    # Selection gate. A file-mode test ([[ -x ]]) is NOT sufficient: on a cross
    # lane the freshly-built zig is a TARGET-arch ELF that is perfectly
    # executable-mode yet cannot run on this build host. It dies at the dynamic
    # loader (e.g. "libzstd.so.1: cannot open shared object file") and only
    # surfaces far downstream as "failed to compile crt2.o". Probe by actually
    # running it, so this cannot disagree with _can_run_stage3 (build-zig.sh:686),
    # which already skips Phase 2 langref for exactly this reason.
    _tgt_arch="${CONDA_TRIPLET%%-*}"
    _bld_arch="${BUILD_ZIG%%-*}"
    _zig_fresh_ver=""
    _zig_fresh_runs=0
    if [[ -x "${_zig_bin_fresh}" ]] && _zig_fresh_ver="$("${_zig_bin_fresh}" version 2>&1)"; then
      _zig_fresh_runs=1
    fi

    if [[ ${_zig_fresh_runs} -eq 1 ]]; then
      _zig_bin="${_zig_bin_fresh}"
      echo "INFO: [_mingw] cache-warm using FRESHLY-BUILT zig (shipped compiler): ${_zig_bin} (version ${_zig_fresh_ver})" >&2
    else
      _zig_bin="${_zig_bin_boot}"
      if [[ ! -e "${_zig_bin_fresh}" ]]; then
        echo "WARN: [_mingw] freshly-built zig absent at ${_zig_bin_fresh}; cache-warm falling back to BOOTSTRAP zig: ${_zig_bin}" >&2
        diag_fail "cache-warm zig selection" "freshly-built zig missing at ${_zig_bin_fresh}; used bootstrap ${_zig_bin} instead"
      elif [[ "${_tgt_arch}" != "${_bld_arch}" ]]; then
        # EXPECTED on cross lanes: target-arch binary, unrunnable here. Not a
        # defect, so it must NOT enter the diag accumulator -- otherwise every
        # cross lane would report a false failure.
        echo "INFO: [_mingw] freshly-built zig is ${_tgt_arch} and cannot run on this ${_bld_arch} build host (cross lane); cache-warm using BOOTSTRAP zig: ${_zig_bin}" >&2
        echo "INFO: [_mingw] consequence: import libs staged here are NOT produced by the zig our mingw patches govern; that pairing only holds on native lanes." >&2
      else
        # Same arch yet still will not run: the build produced a broken binary.
        echo "WARN: [_mingw] freshly-built zig at ${_zig_bin_fresh} is same-arch (${_tgt_arch}) but failed to execute; cache-warm falling back to BOOTSTRAP zig: ${_zig_bin}" >&2
        diag_fail "cache-warm zig selection" "same-arch freshly-built zig at ${_zig_bin_fresh} failed to run: ${_zig_fresh_ver}; used bootstrap ${_zig_bin} instead"
      fi
    fi
    if [[ -x "${_zig_bin}" ]]; then
      echo "INFO: [_mingw] cache-warm compiler: ${_zig_bin} (version $("${_zig_bin}" version 2>&1 || true))" >&2
    fi
    _def_include="${_mingw_common}/../def-include"
    _mingw_libsrc="${_mingw_common}/../libsrc"

    _dlltool=""
    for _cand in \
        "${BUILD_PREFIX}/bin/llvm-dlltool" \
        "${BUILD_PREFIX}/bin/llvm-dlltool.exe" \
        "${BUILD_PREFIX}/Library/bin/llvm-dlltool.exe" \
        "${BUILD_PREFIX}/Library/bin/llvm-dlltool" \
        "$(command -v llvm-dlltool 2>/dev/null || true)"; do
      if [[ -x "${_cand}" ]]; then
        _dlltool="${_cand}"
        break
      fi
    done

    dbg echo "=== MinGW import lib generation: zig=${_zig_bin} dlltool=${_dlltool:-not found} ==="
    if [[ -n "${_dlltool}" ]] && [[ -x "${_zig_bin}" ]]; then
      dbg echo "=== Generating MinGW import libs (dlltool=${_dlltool}) ==="
      _gen_count=0

      # Helper: generate .a from a processed .def file
      function _gen_implib() {
        local stem="$1" def="$2"
        local lib="${_mingw_common}/lib${stem}.a"
        [[ -f "${lib}" ]] && return 0
        local dll
        dll="$(awk '/^LIBRARY/{gsub(/"/, "", $2); print $2; exit}' "${def}")"
        [[ -z "${dll}" ]] && dll="${stem}.dll"
        "${_dlltool}" -m "${_dlltool_machine}" -D "${dll}" -d "${def}" -l "${lib}" 2>/dev/null || true
        _gen_count=$(( _gen_count + 1 ))
      }

      # Step 1: plain .def files (shlwapi.def, version.def, synchronization.def, etc.)
      for _def in "${_mingw_common}"/*.def; do
        [[ -f "${_def}" ]] || continue
        _stem="$(basename "${_def%.def}")"
        _gen_implib "${_stem}" "${_def}"
      done

      # Step 2: .def.in template files (ws2_32, kernel32, ole32, advapi32, user32, ...)
      # Process through zig's C preprocessor with x86_64 defines so architecture
      # macros (F_X64, F_I386, F64, F32, etc.) expand correctly.
      for _def_in in "${_mingw_common}"/*.def.in; do
        [[ -f "${_def_in}" ]] || continue
        _stem="$(basename "${_def_in%.def.in}")"
        _lib="${_mingw_common}/lib${_stem}.a"
        [[ -f "${_lib}" ]] && continue
        _def="${_mingw_common}/${_stem}.def"
        if [[ ! -f "${_def}" ]]; then
          "${_zig_bin}" cc -E -P \
            -target "${_win_target}" \
            -x assembler-with-cpp \
            -I"${_def_include}" \
            "${_def_in}" 2>/dev/null > "${_def}" || { rm -f "${_def}"; continue; }
        fi
        _gen_implib "${_stem}" "${_def}"
      done

      # Step 3: uuid -- compiled from C source (no DLL, no import lib needed).
      # zig compiles libsrc/uuid.c into a static archive.
      _uuid_lib="${_mingw_common}/libuuid.a"
      _uuid_src="${_mingw_libsrc}/uuid.c"
      if [[ ! -f "${_uuid_lib}" ]] && [[ -f "${_uuid_src}" ]]; then
        _uuid_obj="${_mingw_common}/_uuid.o"
        "${_zig_bin}" cc -target "${_win_target}" -c "${_uuid_src}" \
            -o "${_uuid_obj}" 2>/dev/null && \
          "${_zig_bin}" ar rcs "${_uuid_lib}" "${_uuid_obj}" 2>/dev/null || true
        rm -f "${_uuid_obj}"
        _gen_count=$(( _gen_count + 1 ))
      fi

      dbg echo "=== Generated ${_gen_count} import libs in ${_mingw_common} ==="

      # Step 4: Supplemental import libs from mingw-w64 .def.in templates.
      # Zig doesn't ship msvcrt.def -- we provide a complete mingw-w64 version
      # that covers all exports (stdio, math, POSIX I/O, etc.).
      # msvcrt.def.in uses #include "func.def.in" and #include "crt-aliases.def.in",
      # both of which live in zig's own def-include/.  We also include zig's
      # lib-common/ so any future templates can resolve ucrtbase-common.def.in etc.
      # _supp_defs remains first so pthread.def and msvcrt.def.in are still found.
      _supp_defs="${RECIPE_DIR}/building/mingw-defs"
      if [[ -d "${_supp_defs}" ]]; then
        dbg echo "=== Processing supplemental mingw-w64 .def.in templates ==="
        for _supp_in in "${_supp_defs}"/*.def.in; do
          [[ -f "${_supp_in}" ]] || continue
          _supp_stem="$(basename "${_supp_in%.def.in}")"
          # Skip pure include helpers (not standalone DLL definitions)
          case "${_supp_stem}" in
            func|ucrtbase-common|crt-aliases) continue ;;
          esac
          _supp_lib="${_mingw_common}/lib${_supp_stem}.a"
          [[ -f "${_supp_lib}" ]] && continue
          _supp_def="${_mingw_common}/${_supp_stem}.def"
          if [[ ! -f "${_supp_def}" ]]; then
            "${_zig_bin}" cc -E -P \
              -target "${_win_target}" \
              -x assembler-with-cpp \
              -I"${_supp_defs}" \
              -I"${_def_include}" \
              -I"${_mingw_common}" \
              "${_supp_in}" 2>/dev/null > "${_supp_def}" || { rm -f "${_supp_def}"; continue; }
          fi
          _gen_implib "${_supp_stem}" "${_supp_def}"
        done
        # Also process plain .def files (no preprocessing needed)
        for _supp_def in "${_supp_defs}"/*.def; do
          [[ -f "${_supp_def}" ]] || continue
          _supp_stem="$(basename "${_supp_def%.def}")"
          _supp_lib="${_mingw_common}/lib${_supp_stem}.a"
          [[ -f "${_supp_lib}" ]] && continue
          _gen_implib "${_supp_stem}" "${_supp_def}"
        done
        dbg echo "=== Supplemental import libs done (total ${_gen_count}) ==="
      fi

      # Step 5: arch-specific stubs and CRT output directory routing.
      # aarch64 emits CRT objects into libarm64/ (arch-specific dir, prevents
      # cross-arch contamination); i386 into lib32/; x86_64 keeps lib-common/.
      if [[ "${_win_arch}" == "aarch64" ]]; then
        _mingw_libarm64="${_mingw_common}/../libarm64"
        mkdir -p "${_mingw_libarm64}"
        _crt_outdir="${_mingw_libarm64}"
      elif [[ "${_win_arch}" == "x86" || "${_win_arch}" == "i386" || "${_win_arch}" == "i686" ]]; then
        _mingw_lib32="${_mingw_common}/../lib32"
        mkdir -p "${_mingw_lib32}"
        _crt_outdir="${_mingw_lib32}"
      else
        _crt_outdir="${_mingw_common}"
      fi

      # Pre-compile MinGW CRT startup objects.
      # Consumers explicitly link crt2.o (console exe), crt2win.o (GUI exe),
      # and dllcrt2.o (DLL) as the first object file.  Zig compiles these
      # internally, but flexlink searches for them on disk via -print-search-dirs
      # paths.  Compile from zig's bundled MinGW CRT sources.
      _mingw_crt="${_mingw_common}/../crt"
      _mingw_inc="${_mingw_common}/../include"
      _win_inc="${_zig_lib}/libc/include/any-windows-any"
      # ZIGDIAG (PR17 osx-64): search position 1 in clang's -cc1 -v include list
      # ($PREFIX/lib/zig/include), named by the failing "cannot open file
      # '.../lib/zig/include/oscalls.h'" error itself but never probed by any
      # existing diagnostic below (those cover positions 2/3 only).
      _zig_inc="${_zig_lib}/include"

      # PR17 osx-64: canonicalize away the ".." component before either path is
      # handed to clang. The crtdefs.h failure is a resolved-then-failed-open
      # ("cannot open file '<abs path>'"), NOT a search miss ("'crtdefs.h' file
      # not found") -- clang had already bound the include to this -I directory
      # even though crtdefs.h is absent from it and IS present in the
      # any-windows-any -isystem dir that appears in clang's own printed search
      # list. The embedded ".." is the only non-canonical thing about the path,
      # so remove it. Uses cd+pwd -P rather than realpath(1), which is not
      # guaranteed present on the macOS build image or under MSYS2.
      if [[ -d "${_mingw_inc}" ]]; then
        _mingw_inc="$(cd "${_mingw_inc}" && pwd -P)"
      fi
      if [[ -d "${_mingw_crt}" ]]; then
        _mingw_crt="$(cd "${_mingw_crt}" && pwd -P)"
      fi

      if [[ -d "${_mingw_crt}" ]]; then
        dbg echo "=== Compiling MinGW CRT startup objects from ${_mingw_crt} -> ${_crt_outdir} ==="
        dbg echo "=== CRT sources: $(ls "${_mingw_crt}" | tr '\n' ' ') ==="

        # CRT compile flags must match zig's internal addCrtCcArgs (src/libs/mingw.zig)
        # exactly, otherwise oscalls.h and other internal headers reject inclusion via
        # `#error ERROR: Use of C runtime library internal header file.`. Keep this in
        # lockstep with upstream zig's addCcArgs+addCrtCcArgs flag set. (No -mfpu=vfp:
        # this recipe never targets thumb.)
        #
        # PR17 osx-64 crtdefs.h fix: both mingw/include and any-windows-any are
        # passed as -isystem here, NOT -I (upstream zig uses -I for mingw/include).
        # crtdefs.h does not exist under libc/mingw/include upstream (only a sparse
        # 5-header dir) and is only present under libc/include/any-windows-any/.
        # Clang buckets #include <> search dirs into "Angled" (-I) and "System"
        # (-isystem), and always searches every Angled dir before any System dir
        # regardless of argv order -- so with mingw/include passed via -I it won
        # unconditionally over any-windows-any and clang never fell through to the
        # -isystem candidate (confirmed via -H trace, CI run 31839606806 job
        # 94893475923). Relative order WITHIN the System bucket IS preserved, so
        # listing any-windows-any before mingw/include here makes any-windows-any
        # win the lookup. This is a deliberate divergence from upstream zig, made
        # because clang was observed not to fall through past the first candidate.
        _crt_flags=(-target "${_win_target}" -mcpu=baseline -c
                    -std=gnu11
                    -D__USE_MINGW_ANSI_STDIO=0
                    -D__MSVCRT_VERSION__=0x700
                    -D_CRTBLD
                    -D_SYSCRT=1
                    -D_WIN32_WINNT=0x0f00
                    -DCRTDLL=1
                    -DHAVE_CONFIG_H
                    -isystem "${_win_inc}"
                    -isystem "${_mingw_inc}")

        # DIAGNOSTIC (PR17 osx-64): crt2.o compile has failed with
        # "cannot open file '<_mingw_inc>/crtdefs.h'" despite crtdefs.h being a plain
        # regular file in the source tarball under libc/include/any-windows-any/.
        # Verify both include roots exist and are populated BEFORE the first compile,
        # so this failure names itself instead of surfacing as an opaque clang error.
        for _inc_dir in "${_win_inc}" "${_mingw_inc}"; do
          if [[ -d "${_inc_dir}" ]]; then
            echo "INFO: [_mingw] include dir OK: ${_inc_dir} ($(ls -1 "${_inc_dir}" 2>/dev/null | wc -l | tr -d ' ') entries)" >&2
            # TEMPORARY DIAGNOSTIC (PR17 osx-64): full long listing (type/perm/size/
            # symlink arrow), not just the entry count above.
            echo "INFO: [_mingw] ls -la ${_inc_dir}:" >&2
            ls -la "${_inc_dir}" >&2 || true
          else
            echo "ERROR: [_mingw] include dir MISSING: ${_inc_dir}" >&2
          fi
        done
        if [[ -e "${_win_inc}/crtdefs.h" ]]; then
          echo "INFO: [_mingw] crtdefs.h present: $(ls -l "${_win_inc}/crtdefs.h" 2>&1)" >&2
        else
          echo "ERROR: [_mingw] crtdefs.h ABSENT from ${_win_inc}" >&2
        fi
        # TEMPORARY DIAGNOSTIC (PR17 osx-64, remove once header-search order is known):
        # dump the -I mingw include dir contents so we can confirm at failure time
        # that this is really the sparse 5-file dir and not something else.
        echo "INFO: [_mingw] -I mingw include dir contents (${_mingw_inc}): $(ls -1 "${_mingw_inc}" 2>/dev/null | tr '\n' ' ')" >&2
        # TEMPORARY DIAGNOSTIC (PR17 osx-64): canonicalize both crtdefs.h candidates.
        # readlink -f resolves symlinks/relative components; falls back to the same
        # cd+pwd -P trick already used above for _mingw_inc/_mingw_crt in case the
        # build host's BSD readlink lacks -f. Distinguishes a plain regular file from
        # a symlink whose resolved target differs from what ls/stat report.
        for _crtdefs_cand in "${_mingw_inc}/crtdefs.h" "${_win_inc}/crtdefs.h"; do
          # set -e-safe: BSD readlink (macOS) has no -f and exits non-zero; this
          # assignment's status would otherwise be the substitution's exit status
          # and abort the script before the cd+pwd -P fallback below ever runs.
          _crtdefs_resolved="$(readlink -f "${_crtdefs_cand}" 2>/dev/null || true)"
          if [[ -z "${_crtdefs_resolved}" ]]; then
            if [[ -e "${_crtdefs_cand}" ]]; then
              _crtdefs_resolved="$(cd "$(dirname "${_crtdefs_cand}")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "${_crtdefs_cand}")" || true)"
            else
              _crtdefs_resolved="MISSING"
            fi
          fi
          echo "INFO: [_mingw] readlink -f ${_crtdefs_cand} -> ${_crtdefs_resolved}" >&2
        done
        # ZIGDIAG position-1 include (_zig_inc) probe (PR17 osx-64): the -cc1 -v
        # search list is $PREFIX/lib/zig/include (position 1), then any-windows-any
        # (position 2, _win_inc), then mingw/include (position 3, _mingw_inc). The
        # failing compile's own error names position 1
        # ('.../lib/zig/include/oscalls.h'), but every existing diagnostic in this
        # file probes only positions 2/3. Leading hypothesis: a stale/dangling
        # directory entry for oscalls.h specifically at position 1 -- vadefs.h is
        # known to open fine from that same directory in the same compile, so this
        # is per-file, not per-directory. No CI log to date has shown this
        # directory's contents, so dump it in full alongside both header
        # candidates.
        # set -e/pipefail-safe: every command below is diagnostics-only and must
        # never be able to preempt or abort before the real compile/return below.
        echo "=== ZIGDIAG position-1 include (_zig_inc) probe: ${_zig_inc} ===" >&2
        echo "--- ls -1 ${_zig_inc} (full directory listing) ---" >&2
        ls -1 "${_zig_inc}" >&2 || true
        for _zig_inc_cand in "${_zig_inc}/oscalls.h" "${_zig_inc}/crtdefs.h"; do
          echo "--- candidate: ${_zig_inc_cand}" >&2
          echo "    ls -la (no -L, symlink arrow visible if present):" >&2
          ls -la "${_zig_inc_cand}" >&2 || true
          echo "    ls -laL (-L dereferences; dangling symlink reports 'No such file or directory'):" >&2
          ls -laL "${_zig_inc_cand}" >&2 || true
          echo "    readlink -f:" >&2
          readlink -f "${_zig_inc_cand}" >&2 || true
        done
        echo "=== end ZIGDIAG position-1 include (_zig_inc) probe ===" >&2
        # TEMPORARY DIAGNOSTIC (PR17 osx-64): print the exact resolved -I/-isystem
        # flag array clang will receive, verbatim, immediately before the first CRT
        # compile call -- rules out any shell-quoting/expansion mismatch between what
        # this script constructed and what actually reaches clang's argv.
        # set -u-safe: expanding "${_crt_flags[@]}" when the array is empty
        # errors as "unbound variable" on bash < 4.4 (macOS ships bash 3.2).
        # _crt_flags is always populated above, but guard explicitly anyway
        # since this is diagnostics-only and must never be able to abort.
        if [[ ${#_crt_flags[@]} -gt 0 ]]; then
          echo "INFO: [_mingw] resolved _crt_flags argv: $(printf '%q ' "${_crt_flags[@]}" 2>/dev/null || true)" >&2
        else
          echo "INFO: [_mingw] resolved _crt_flags argv: (empty)" >&2
        fi

        # Helper: compile one CRT object, surface errors (do NOT swallow).
        # Captures stderr to a log; on success emits dbg trace; on failure
        # prints log to stderr and returns 1 to abort import-lib generation.
        _compile_crt_obj() {
          local src="$1" obj="$2" extra="${3:-}"
          local log; log=$(mktemp)
          # TEMPORARY DIAGNOSTIC (PR17 osx-64, remove once header-search order is known):
          # -v makes clang print its resolved "#include <...> search starts here:"
          # directory list/order to stderr. -H makes clang trace every header as it
          # is actually opened (one line per #include, showing which directory it
          # resolved from) -- this is what will show whether crtdefs.h is reached via
          # a directory other than the one named in the "cannot open file" error.
          # Neither flag affects codegen or exit status; both write to stderr, which
          # is already captured into ${log} below and surfaced on failure.
          # shellcheck disable=SC2086
          if "${_zig_bin}" cc -v -H "${_crt_flags[@]}" ${extra} "${src}" -o "${obj}" >"${log}" 2>&1; then
            dbg cat "${log}"
            dbg echo "=== Compiled $(basename "${obj}") ==="
            rm -f "${log}"
            return 0
          fi
          echo "ERROR: failed to compile $(basename "${obj}") for ${_win_target}:" >&2
          cat "${log}" >&2 || true
          rm -f "${log}"
          # DEEP DIAGNOSTIC (PR17 osx-64 crtdefs.h). This failure is a
          # resolved-then-failed-open, not a search miss: clang reports
          # "cannot open file '<full path>'" rather than "'crtdefs.h' file not
          # found", and zig-feedstock-2's round-20 confirmed the -cc1 -v search
          # list is correct and does carry any-windows-any. Flag permutations are
          # ruled out -- _crt_flags order is pinned to upstream zig's
          # addCrtCcArgs, and -D_CRTBLD makes reordering trip mingw's
          # "Use of C runtime library internal header file" guard. So capture the
          # real argv plus the physical state of both include roots instead.
          # set -e/pipefail-safe: every command below is diagnostics-only and
          # must not be able to preempt the `return 1` that follows this
          # block (a diagnostic-dump command failing must not masquerade as
          # -- or abort before -- the real compile failure being reported).
          {
            echo "=== ZIGDIAG crt-compile failure dump: $(basename "${src}") -> $(basename "${obj}") ==="
            echo "--- _crt_flags (declare -p) ---"
            declare -p _crt_flags 2>&1 || true
            echo "--- extra args: ${extra}"
            echo "--- zig binary: ${_zig_bin}"
            echo "--- resolved cc1 argv (-###) ---"
            # shellcheck disable=SC2086
            "${_zig_bin}" cc -### "${_crt_flags[@]}" ${extra} "${src}" -o "${obj}" 2>&1 | head -40 || true
            echo "--- ls -laL _mingw_inc (${_mingw_inc}) --- (-L dereferences: a dangling symlink shows as unreadable)"
            ls -laL "${_mingw_inc}" 2>&1 || true
            echo "--- ls -laL _win_inc (${_win_inc}) ---"
            ls -laL "${_win_inc}" 2>&1 | head -30 || true
            for _cand in "${_mingw_inc}/crtdefs.h" "${_win_inc}/crtdefs.h"; do
              echo "--- candidate: ${_cand}"
              ls -la "${_cand}" 2>&1 || true
              stat "${_cand}" 2>&1 | head -12 || true
              if [[ -r "${_cand}" ]]; then
                echo "    readable; first 100 bytes follow:"
                head -c 100 "${_cand}" 2>&1 || true
                echo
              else
                echo "    NOT readable (absent, dangling symlink, or permission denied)"
              fi
            done
            echo "=== end ZIGDIAG crt-compile failure dump ==="
          } >&2
          return 1
        }

        # ZIGDIAG pre-compile crtdefs.h probe (PR17 osx-64 search-order fix): dump
        # existence + byte size of the crtdefs.h candidate in both include roots
        # right before the first CRT object is compiled, so the next CI log makes
        # it decisive whether the -isystem reorder above alone resolved the
        # "cannot open file '.../mingw/include/crtdefs.h'" failure. `|| true` on
        # every line: diagnostics-only, must never be able to fail the build.
        echo "=== ZIGDIAG pre-crt2-compile crtdefs.h probe ===" >&2
        echo "--- candidate (any-windows-any, expected present): ${_win_inc}/crtdefs.h" >&2
        ls -l "${_win_inc}/crtdefs.h" >&2 || true
        echo "--- candidate (mingw/include, expected absent): ${_mingw_inc}/crtdefs.h" >&2
        ls -l "${_mingw_inc}/crtdefs.h" >&2 || true
        echo "=== end ZIGDIAG pre-crt2-compile crtdefs.h probe ===" >&2

        # crt2.o -- console application entry (main)
        _crt2_obj="${_crt_outdir}/crt2.o"
        if [[ ! -f "${_crt2_obj}" ]] && [[ -f "${_mingw_crt}/crtexe.c" ]]; then
          _compile_crt_obj "${_mingw_crt}/crtexe.c" "${_crt2_obj}" || return 1
        fi

        # crt2win.o -- GUI application entry (WinMain)
        _crt2win_obj="${_crt_outdir}/crt2win.o"
        if [[ ! -f "${_crt2win_obj}" ]] && [[ -f "${_mingw_crt}/crtexewin.c" ]]; then
          _compile_crt_obj "${_mingw_crt}/crtexewin.c" "${_crt2win_obj}" "-D_WINDOWS" || return 1
        fi

        # dllcrt2.o -- DLL entry (DllMain)
        _dllcrt2_obj="${_crt_outdir}/dllcrt2.o"
        if [[ ! -f "${_dllcrt2_obj}" ]] && [[ -f "${_mingw_crt}/crtdll.c" ]]; then
          _compile_crt_obj "${_mingw_crt}/crtdll.c" "${_dllcrt2_obj}" || return 1
        fi
      else
        dbg echo "=== MinGW CRT sources not found at ${_mingw_crt} ==="
      fi

      # Step 6: empty stub archives for libs external consumers expect by convention
      # but zig folds elsewhere (winpthread -> mingw32), uses compiler-rt for
      # (gcc, gcc_eh, ssp), or doesn't provide (stdc++).  These satisfy -lXXX
      # filename checks without symbols; any actual symbol references must be
      # satisfied by other libs the consumer links.
      #
      # Helper: compile a one-symbol weak C stub and archive it.
      # Args: out_dir  target_triple  lib_name
      _create_stub_lib_archive() {
        local out_dir="$1"
        local target_triple="$2"
        local lib_name="$3"
        local lib_path="${out_dir}/lib${lib_name}.a"
        [[ -f "${lib_path}" ]] && return 0
        # Sanitize lib_name to a valid C identifier (replace +, -, . with _)
        local sym_name
        sym_name="$(printf '%s' "${lib_name}" | tr -c 'a-zA-Z0-9_' '_')"
        local stub_c="${out_dir}/.zig_${sym_name}_stub.c"
        local stub_o="${out_dir}/.zig_${sym_name}_stub.o"
        printf 'int __zig_%s_stub __attribute__((weak)) = 0;\n' "${sym_name}" > "${stub_c}"
        if ! "${_zig_bin}" cc -c "${stub_c}" -o "${stub_o}" -target "${target_triple}" 2>/dev/null; then
          rm -f "${stub_c}" "${stub_o}"
          return 1
        fi
        if ! "${_zig_bin}" ar rcs "${lib_path}" "${stub_o}" 2>/dev/null; then
          rm -f "${stub_c}" "${stub_o}"
          return 1
        fi
        rm -f "${stub_c}" "${stub_o}"
        dbg echo "[_mingw] stub archive: ${lib_path}"
      }

      dbg echo "=== Generating stub archives for ${_win_target} in ${_crt_outdir} ==="
      # Real archives ship for all three arches now (cache-warm loop below),
      # so only the toolchain convenience libs need empty stubs.
      local _stub_libs=(gcc gcc_eh stdc++ ssp)
      for _stub_lib in "${_stub_libs[@]}"; do
        _create_stub_lib_archive "${_crt_outdir}" "${_win_target}" "${_stub_lib}"
      done

      # Cache-warm + stage real libmingw32.lib for all three Windows targets so
      # non-zig linkers (flexlink, mingw-gcc) can resolve -lmingw32 / -lucrt /
      # -lmingwex / -lwinpthread without falling back to empty stubs. Zig compiles
      # its full mingw source tree into a single ~10MB libmingw32.lib at link time
      # and caches it; we trigger materialization with a real link of a tiny program
      # that references snprintf + pthread_self, then harvest the cached artifact.
      # Each target gets its own ZIG_GLOBAL_CACHE_DIR to avoid cross-arch contamination.
      # Soft-fail on missing libmingw32.lib: WARN + continue (not a hard error).
      local _warm_dir
      _warm_dir="$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/zig-warm-$$")"
      mkdir -p "${_warm_dir}"
      cat > "${_warm_dir}/warm.c" <<'WARM_EOF'
#include <stdio.h>
#include <pthread.h>
int main(void) {
    char b[8]; (void)snprintf(b, 8, "%d", 0);
    pthread_t t = pthread_self(); (void)t;
    return 0;
}
WARM_EOF

      # Pre-initialize cross-arch staging paths so the multi-target cache-warm loop
      # below can reference them regardless of which arch this function call targets.
      # The if/elif block at lines 205–215 only sets these conditionally per arch.
      : "${_mingw_libarm64:=${_mingw_common}/../libarm64}"
      : "${_mingw_lib32:=${_mingw_common}/../lib32}"

      # Map: zig target triple -> staging dir name under lib/libc/mingw/
      for _warm_pair in \
          "x86_64-windows-gnu:${_mingw_common}" \
          "aarch64-windows-gnu:${_mingw_libarm64}" \
          "x86-windows-gnu:${_mingw_lib32}"; do
          _warm_tgt="${_warm_pair%%:*}"
          _warm_stage="${_warm_pair##*:}"
          _warm_cache="${_warm_dir}/cache-${_warm_tgt}"
          rm -rf "${_warm_cache}"
          mkdir -p "${_warm_cache}"

          # Real link (NOT -c compile-only) to force libmingw32 materialization.
          local _warm_rc=0
          ZIG_GLOBAL_CACHE_DIR="${_warm_cache}" \
                  "${_zig_bin}" cc -target "${_warm_tgt}" -pthread \
                  "${_warm_dir}/warm.c" \
                  -o "${_warm_cache}/warm.exe" 2>"${_warm_cache}/warm.err" || _warm_rc=$?
          if [[ ${_warm_rc} -ne 0 ]]; then
              echo "WARN: cache-warm failed for ${_warm_tgt}; skipping stage. Errors:" >&2
              tail -5 "${_warm_cache}/warm.err" >&2 || true
              # Non-fatal skip-and-continue is unchanged; also record it so a real
              # linker error here (e.g. PR #123's swallowed lld-link "unable to
              # automatically import from _fpreset" / "undefined symbol: __setjmp3")
              # surfaces in the end-of-run diag_report instead of only in mid-log WARN.
              diag_fail "cache-warm ${_warm_tgt}" "exit ${_warm_rc}: $(tail -5 "${_warm_cache}/warm.err")"
              continue
          fi

          local _warm_lib
          _warm_lib="$(find "${_warm_cache}" -name 'libmingw32.lib' -print -quit 2>/dev/null)"
          if [[ -z "${_warm_lib}" || ! -f "${_warm_lib}" ]]; then
              echo "WARN: libmingw32.lib not found in cache for ${_warm_tgt}; skipping stage" >&2
              continue
          fi

          mkdir -p "${_warm_stage}"
          # Stage under conventional library names + both .lib (Windows MSVC) and
          # .a (Unix toolchain) extensions so consumers spelling -lucrt /
          # -lmingwex / -lwinpthread all resolve to the single zig-built archive.
          # DO NOT overwrite libpthread.a — it's the 2KB import lib for
          # libwinpthread-1.dll; overwriting would silently switch consumers from
          # dynamic to static threading runtime.
          local _name
          for _name in libmingw32 libucrt libmingwex libwinpthread; do
              cp -f "${_warm_lib}" "${_warm_stage}/${_name}.lib"
              cp -f "${_warm_lib}" "${_warm_stage}/${_name}.a"
          done
          dbg echo "[_mingw] staged libmingw32+aliases for ${_warm_tgt} under ${_warm_stage}"
      done

      rm -rf "${_warm_dir}"

      dbg echo "=== Stub archive generation done ==="

    else
      dbg echo "=== llvm-dlltool or zig not found; skipping import lib pre-generation ==="
    fi
  fi
}
