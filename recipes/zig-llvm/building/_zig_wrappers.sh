# Use zig compiler wrappers provided by the zig-compiler package.
# These are pre-built wrappers with flag filtering and sysroot detection.
# On Windows, conda packages install under Library/
ZIG_WRAPPERS="${BUILD_PREFIX}/share/zig/wrappers"
is_not_unix && ZIG_WRAPPERS="${BUILD_PREFIX}/Library/share/zig/wrappers"
if [[ ! -d "${ZIG_WRAPPERS}" ]]; then
  echo "ERROR: zig wrappers not found at ${ZIG_WRAPPERS}"
  echo "  Is zig-compiler installed as a build dependency?"
  exit 1
fi

if is_not_unix; then
  # Use the pre-built shim wrappers — they hardcode the cc/c++ subcommand internally,
  # so cmake's compiler probe (--target=<triple> -print-target-triple) works correctly.
  # Shims are installed side-by-side in Library/share/zig/wrappers/ by both the
  # build-host and target-host wrapper packages.
  _shim_cc="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cc.exe"
  if [[ ! -x "${_shim_cc}" ]]; then
    echo "ERROR: zig cc shim not found at ${_shim_cc}"
    ls "${ZIG_WRAPPERS}/"*zig* 2>/dev/null || true
    exit 1
  fi
  "${_shim_cc}" --version

  export ZIG_CC="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cc.exe"
  export ZIG_CXX="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cxx.exe"
  export ZIG_ASM="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cc.exe"
  export ZIG_AR="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-ar.bat"
  export ZIG_RANLIB="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-ranlib.bat"
  export ZIG_RC="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-rc.bat"
else
  export ZIG_CC="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cc"
  export ZIG_CXX="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cxx"
  export ZIG_AR="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-ar"
  export ZIG_RANLIB="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-ranlib"
  export ZIG_ASM="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-asm"
  export ZIG_RC="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-rc"
fi

# setup_macos_sysroot: ensure /opt/MacOSX*.sdk exists for zig-cc path #3 lookup.
# The zig-cc wrapper (_zig-cc-common.sh) globs /opt/MacOSX*.sdk as its third
# macOS SDK search path. If neither that nor CONDA_BUILD_SYSROOT provides an
# SDK, download the pinned phracker MacOSX11.0.sdk tarball, verify sha256, and
# extract to /opt/. Falls back to ${SRC_DIR}/conda-sdks/ + symlink (or
# CONDA_BUILD_SYSROOT export) if /opt/ is not writable.
# Ported from conda-forge OCAML feedstock pattern (known-working).
setup_macos_sysroot() {
  local _sdk_primary="/opt"
  local _sdk_fallback="${SRC_DIR}/conda-sdks"
  local _sdk_url="https://github.com/phracker/MacOSX-SDKs/releases/download/11.3/MacOSX11.0.sdk.tar.xz"
  local _sdk_sha="d3feee3ef9c6016b526e1901013f264467bb927865a03422a9cb925991cc9783"
  local _sdk_name="MacOSX11.0.sdk"
  local _sdk_tarball="${_sdk_name}.tar.xz"

  # Path #3: /opt/MacOSX*.sdk glob — early-exit if already present
  for _existing in /opt/MacOSX*.sdk; do
    if [[ -d "${_existing}" ]]; then
      echo "  macOS SDK already present at path #3: ${_existing}"
      return 0
    fi
  done

  # CONDA_BUILD_SYSROOT (set by conda-build on native macOS via Xcode)
  if [[ -d "${CONDA_BUILD_SYSROOT:-}" ]]; then
    echo "  macOS SDK via CONDA_BUILD_SYSROOT: ${CONDA_BUILD_SYSROOT}"
    return 0
  fi

  echo "  Downloading macOS SDK (${_sdk_name})..."

  local _sdk_dir
  if mkdir -p "${_sdk_primary}" 2>/dev/null && [[ -w "${_sdk_primary}" ]]; then
    _sdk_dir="${_sdk_primary}"
    echo "  Extracting to ${_sdk_dir}/ (path #3 glob will find it)"
  else
    _sdk_dir="${_sdk_fallback}"
    mkdir -p "${_sdk_dir}"
    echo "  /opt/ not writable, extracting to ${_sdk_dir}/"
  fi

  curl -L --output "${_sdk_dir}/${_sdk_tarball}" "${_sdk_url}"
  echo "${_sdk_sha}  ${_sdk_dir}/${_sdk_tarball}" | shasum -a 256 -c

  echo "  Extracting ${_sdk_name}..."
  python3 << PYEOF
import lzma, tarfile
tarball = "${_sdk_dir}/${_sdk_tarball}"
outdir = "${_sdk_dir}"
with lzma.open(tarball, 'rb') as f:
    with tarfile.open(fileobj=f, mode='r:') as tar:
        tar.extractall(path=outdir, filter='data')
print(f"Extracted to {outdir}")
PYEOF
  if [[ $? -ne 0 ]]; then
    echo "ERROR: macOS SDK extraction failed"
    return 1
  fi

  local _sdk_path="${_sdk_dir}/${_sdk_name}"
  if [[ ! -d "${_sdk_path}" ]]; then
    echo "ERROR: SDK directory not found after extraction: ${_sdk_path}"
    return 1
  fi

  # Fallback path: try symlink into /opt/ for path #3 glob;
  # if symlink fails (no permission), export CONDA_BUILD_SYSROOT instead.
  if [[ "${_sdk_dir}" != "${_sdk_primary}" ]]; then
    if ln -sf "${_sdk_path}" "${_sdk_primary}/${_sdk_name}" 2>/dev/null; then
      echo "  Symlinked: ${_sdk_primary}/${_sdk_name} -> ${_sdk_path}"
    else
      echo "  Symlink to /opt/ failed — exporting CONDA_BUILD_SYSROOT=${_sdk_path}"
      export CONDA_BUILD_SYSROOT="${_sdk_path}"
    fi
  fi

  echo "  macOS SDK ready: ${_sdk_path}"
}

# macOS force-load wrapper: zig _14+ provides zig-force-load-cxx which handles
# -Wl,-all_load/-Wl,-force_load by extracting archives to .o files, in c++ mode.
# Set as CMAKE_CXX_COMPILER so it handles both compile and link commands;
# force-load logic only activates when those flags are present.
# _14 also fixes the relative-path bug (archives resolved to absolute before cd+ar x).
if is_osx; then
    setup_macos_sysroot

    if [[ -x "${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-force-load-cxx" ]]; then
        export ZIG_CXX="${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-force-load-cxx"
    else
        echo "ERROR: ${ZIG_TARGET_HOST}-zig-force-load-cxx not found in ${ZIG_WRAPPERS}"
        exit 1
    fi

    # Patch deployment target in zig wrappers to match conda's MACOSX_DEPLOYMENT_TARGET.
    # _zig-cc-common.sh contains the actual `-target aarch64-macos-none` (or versioned
    # macos.13.0-none in zig 0.15+). zig-force-load-cxx sources this at runtime — it does
    # NOT embed the target itself. zig-cc and zig-cxx have the target in a comment only.
    # ld64 rejects ADRP relocations when objects compiled for a newer target are linked
    # against a .dylib built for an older one (e.g. zig compiles at 13.0, linker at 11.0).
    # Patch _zig-cc-common.sh FIRST (fixes all sourcing wrappers), then individual scripts.
    _deploy_target="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    echo "  Patching zig wrappers: setting macOS deployment target to ${_deploy_target}"
    # _zig-cc-common.sh is sourced by all wrappers and contains the actual
    # -target @ZIG_TARGET@ substitution. zig-force-load-cxx does NOT embed
    # the target directly — it sources _zig-cc-common.sh at runtime.
    # Patching the common script fixes ALL wrappers that source it.
    for _wrapper in "${ZIG_WRAPPERS}/_zig-cc-common.sh" "${ZIG_CXX}" "${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cc" "${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cxx"; do
        [[ -f "${_wrapper}" ]] || continue
        # Check if this is a text file (shell script) — binaries cannot be sed-patched
        if ! file "${_wrapper}" | grep -q 'text\|script\|ASCII'; then
            echo "  SKIP $(basename "${_wrapper}"): not a text file (binary?), cannot patch deployment target"
            continue
        fi
        # grep -oE extracts the current macos*-none target triple (if any) for logging
        _before=$(grep -oE 'macos(\.[0-9]+\.[0-9]+)?-none' "${_wrapper}" | head -1 || true)
        # Replace macos-none (unversioned) OR macos.X.Y-none (versioned) with the correct target.
        # Two-pass: versioned first (more specific), then unversioned fallback.
        sed -i.deplbak \
            -e "s/macos\.[0-9][0-9]*\.[0-9][0-9]*-none/macos.${_deploy_target}-none/g" \
            -e "s/macos-none/macos.${_deploy_target}-none/g" \
            "${_wrapper}"
        _after=$(grep -oE 'macos(\.[0-9]+\.[0-9]+)?-none' "${_wrapper}" | head -1 || true)
        if [[ "${_before}" == "${_after}" ]] && [[ -n "${_before}" ]]; then
            echo "  $(basename "${_wrapper}"): no change needed (already: ${_before})"
        elif [[ -z "${_before}" ]]; then
            echo "  $(basename "${_wrapper}"): no macos*-none pattern found (wrapper may use a different format)"
        else
            echo "  $(basename "${_wrapper}"): patched ${_before} -> ${_after}"
        fi
    done

    # Diagnostic: show the macOS target triple in each wrapper used as a compiler
    echo "  === macOS wrapper deployment targets (after patching) ==="
    for _diag_wrapper in "${ZIG_WRAPPERS}/_zig-cc-common.sh" "${ZIG_CXX}" "${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cc" "${ZIG_WRAPPERS}/${ZIG_TARGET_HOST}-zig-cxx"; do
        [[ -f "${_diag_wrapper}" ]] || continue
        _diag_target=$(grep -oE 'macos(\.[0-9]+\.[0-9]+)?-none' "${_diag_wrapper}" | head -1 || true)
        echo "  $(basename "${_diag_wrapper}"): ${_diag_target:-<no macos*-none target found>}"
    done
fi

