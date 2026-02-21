post_install() {
  set +x
  
  if [[ "${target_platform}" == linux-* ]]; then
    echo "=== Fixing NEEDED entries in shared libraries ==="
    # CMake sometimes records build-tree relative paths (e.g. lib/libLLVM.so.20.1)
    # instead of bare sonames in NEEDED entries. Fix all .so files unconditionally
    # so the package is always correct regardless of CMake/linker behaviour.
    find "${LLVM_INSTALL}/lib" -name '*.so*' -not -type l | while read -r lib; do
      readelf -d "${lib}" 2>/dev/null | grep NEEDED | grep -oP '(?<=\[).*(?=\])' | while read -r needed; do
        if [[ "${needed}" == */* ]]; then
          bare=$(basename "${needed}")
          echo "  Fixing NEEDED in $(basename ${lib}): ${needed} -> ${bare}"
          patchelf --replace-needed "${needed}" "${bare}" "${lib}"
        fi
      done || true
    done

    echo "=== Adding libc++ NEEDED entries via patchelf ==="
    for _lib in "${LLVM_INSTALL}/lib/libLLVM"*.so.* "${LLVM_INSTALL}/lib/libclang-cpp"*.so.*; do
      [[ -L "${_lib}" ]] && continue  # skip symlinks
      [[ ! -f "${_lib}" ]] && continue
      echo "  Patching $(basename ${_lib}):"
      if ! readelf -d "${_lib}" | grep NEEDED | grep -q 'libc++\.so'; then
        patchelf --add-needed libc++.so.1 "${_lib}"
        echo "    added NEEDED libc++.so.1"
      else
        echo "    already has libc++.so.1"
      fi
      if ! readelf -d "${_lib}" | grep NEEDED | grep -q 'libc++abi\.so'; then
        patchelf --add-needed libc++abi.so.1 "${_lib}"
        echo "    added NEEDED libc++abi.so.1"
      else
        echo "    already has libc++abi.so.1"
      fi
      echo "    NEEDED entries:"
      readelf -d "${_lib}" | grep NEEDED || true
    done

    echo "=== Quick check: libc++ symbol binding ==="
    _fail=0
    for _lib in "${LLVM_INSTALL}/lib/libLLVM"*.so.* "${LLVM_INSTALL}/lib/libclang-cpp"*.so.*; do
      [[ -L "${_lib}" ]] && continue
      [[ ! -f "${_lib}" ]] && continue
      _bind=$(nm -a "${_lib}" 2>/dev/null | grep 'generic_category' | head -1 || true)
      echo "  $(basename ${_lib}): ${_bind:-not found}"
      if echo "${_bind}" | grep -q '^[0-9a-f]* t '; then
        echo "  FAIL: LOCAL_DEFINED — static libc++ merged in"
        _fail=1
      fi
    done
    if [[ ${_fail} -ne 0 ]]; then
      echo "ERROR: libLLVM/libclang-cpp have private libc++ copies."
      echo "       zig will fail: 'LLVM and Clang have separate copies of libc++'"
      echo "       The -nostdlib++ wrapper or link flags are not preventing static merge."
      exit 1
    fi
    echo "  OK: no local generic_category — no static libc++ merge"
  fi

  if [[ "${target_platform}" == linux-* ]] || [[ "${target_platform}" == osx-* ]]; then
    echo "=== Stripping debug info from shared libraries ==="
    find "${LLVM_INSTALL}/lib" -name '*.so*' -not -type l | while read -r lib; do
      echo "  Stripping: $(basename "${lib}")"
      llvm-strip --strip-debug "${lib}" 2>/dev/null || strip --strip-debug "${lib}" 2>/dev/null || true
    done
  fi
  set -x
}
