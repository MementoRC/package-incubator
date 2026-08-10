source "${RECIPE_DIR}/building/_common.sh"

function create_zig_linux_libc_file() {
  local output_file=$1

  if [[ -z "${output_file}" ]]; then
    echo "ERROR: create_zig_libc_file requires: output_file" >&2
    return 1
  fi

  dbg echo "Creating Zig libc configuration file: ${output_file}"

  # Find GCC library directory (contains crtbegin.o, crtend.o)
  # Rewrite sysroot path: replace $BUILD_PREFIX with $BUILD_PREFIX/lib/gcc to reach the gcc multilib subdir.
  local gcc_lib_dir="${ZIG_SYSROOT//${BUILD_PREFIX}/${BUILD_PREFIX}\/lib\/gcc}"
  gcc_lib_dir=${gcc_lib_dir//\/sysroot/}
  gcc_lib_dir=$(dirname "$(find "${gcc_lib_dir}" -name "crtbeginS.o" | head -1)")

  if [[ -z "${gcc_lib_dir}" ]] || [[ ! -d "${gcc_lib_dir}" ]]; then
    echo "WARNING: Could not find GCC library directory for ${ZIG_SYSROOT}" >&2
    gcc_lib_dir=""
  else
    dbg echo "  Found GCC library directory: ${gcc_lib_dir}"
  fi

  # Create libc configuration file
  cat > "${output_file}" << EOF
include_dir=${ZIG_SYSROOT}/usr/include
sys_include_dir=${ZIG_SYSROOT}/usr/include
crt_dir=${ZIG_SYSROOT}/usr/lib
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=${gcc_lib_dir}
EOF

  # DIAGNOSTIC (PR17 ppc64le ld64.so.2): the GCC-linker fallback in
  # patches/ppc64le/0003-gcc-linker-comprehensive-Lld.zig.patch derives the
  # --dynamic-linker path from the crt_dir written above by walking ".." upward.
  # Record which sysroot dirs actually hold the loader, so a wrong derivation
  # names itself here instead of surfacing as an opaque
  # "ld: cannot find <sysroot>/usr/lib/../../lib64/ld64.so.2".
  for _sr_dir in "${ZIG_SYSROOT}/lib64" "${ZIG_SYSROOT}/usr/lib64" \
                 "${ZIG_SYSROOT}/lib" "${ZIG_SYSROOT}/usr/lib"; do
    if [[ -d "${_sr_dir}" ]]; then
      echo "INFO: [_cross] sysroot ${_sr_dir}: loader(s)=[$(ls -1 "${_sr_dir}" 2>/dev/null | grep -E '^ld(64)?[-.]' | tr '\n' ' ')]" >&2
    else
      echo "INFO: [_cross] sysroot ABSENT: ${_sr_dir}" >&2
    fi
  done

  dbg echo "Zig libc file created: ${output_file}"
  :
}
