#!/usr/bin/env bash
# Fix sysroot linker scripts to use sysroot-qualified absolute paths instead of bare absolute /usr/lib64

function fix_sysroot_libc_scripts() {
  local sysroot_base="${1:-${BUILD_PREFIX}}"

  dbg echo "Fixing sysroot linker scripts for absolute sysroot-qualified paths..."

  # Find all sysroot directories
  for sysroot_dir in "${sysroot_base}"/*-conda-linux-gnu/sysroot; do
    [[ -d "${sysroot_dir}" ]] || continue

    local arch_name
    arch_name=$(basename "$(dirname "${sysroot_dir}")")
    dbg echo "  Processing sysroot: ${arch_name}"

    # ppc64le is the only arch linked with GNU ld (see ppc64le
    # 0003-gcc-linker-comprehensive-Lld.zig.patch). GNU ld already resolves
    # bare-absolute GROUP() paths against its own --sysroot, so rewriting them
    # here would sysroot-prefix them a second time. lld does not pass
    # --sysroot and needs the rewrite, so skip only powerpc64le here.
    case "${arch_name}" in
      powerpc64le*)
        dbg echo "  Skipping ${arch_name}: GNU ld already sysroot-qualifies bare absolute paths"
        continue
        ;;
    esac

    # Fix libc.so, libpthread.so, libm.so, etc. in usr/lib and usr/lib64
    for lib_dir in "${sysroot_dir}"/usr/lib "${sysroot_dir}"/usr/lib64; do
      [[ -d "${lib_dir}" ]] || continue

      # Find all .so files that are actually linker scripts
      for script_file in "${lib_dir}"/{libc,libpthread,libm,librt,libdl}.so; do
        [[ -f "${script_file}" ]] || continue

        # Check if it's a linker script (contains "GROUP" or "INPUT")
        if grep -q -E "^(GROUP|INPUT)" "${script_file}" 2>/dev/null; then
          dbg echo "    Patching ${script_file}"

          # Backup original
          cp "${script_file}" "${script_file}.orig"

          # Replace bare-absolute paths (and any already-relative paths from a
          # prior run) with fully-qualified sysroot-absolute paths, since
          # ld.lld resolves relative GROUP paths against CWD/search paths,
          # not against the linker script's directory.
          sed -i \
            -e "s| /lib64/| ${sysroot_dir}/lib64/|g" \
            -e "s|( /lib64/|( ${sysroot_dir}/lib64/|g" \
            -e "s| /usr/lib64/| ${sysroot_dir}/usr/lib64/|g" \
            -e "s|( /usr/lib64/|( ${sysroot_dir}/usr/lib64/|g" \
            -e "s| /lib/ld-| ${sysroot_dir}/lib/ld-|g" \
            -e "s|( /lib/ld-|( ${sysroot_dir}/lib/ld-|g" \
            -e "s| \.\./\.\./lib64/| ${sysroot_dir}/lib64/|g" \
            -e "s|( \.\./\.\./lib64/|( ${sysroot_dir}/lib64/|g" \
            -e "s| \.\./lib64/| ${sysroot_dir}/usr/lib64/|g" \
            -e "s|( \.\./lib64/|( ${sysroot_dir}/usr/lib64/|g" \
            -e "s| \.\./\.\./lib/ld-| ${sysroot_dir}/lib/ld-|g" \
            -e "s|( \.\./\.\./lib/ld-|( ${sysroot_dir}/lib/ld-|g" \
            "${script_file}"

          dbg echo "      Before: $(cat "${script_file}.orig")"
          dbg echo "      After:  $(cat "${script_file}")"
          rm -f "${script_file}.orig"
        fi
      done
    done
  done

  dbg echo "Sysroot linker scripts fixed successfully"
  return 0
}
