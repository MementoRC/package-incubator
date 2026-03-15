fix_lld_cmake_deps() {
  # The lld static archives (liblldELF.a, etc.) directly reference zlib/zstd
  # symbols for section compression (lld/ELF/OutputSections.cpp). LLVM's cmake
  # declares these only transitively through LLVMSupport, so consumers that
  # link the .a files by path (e.g. zig) miss the dependency. Fix by appending
  # -lz/-lzstd to all lld cmake targets' INTERFACE_LINK_LIBRARIES.
  local lld_config="${LLVM_INSTALL}/lib/cmake/lld/LLDConfig.cmake"
  if [[ ! -f "${lld_config}" ]]; then
    echo "  WARNING: LLDConfig.cmake not found at ${lld_config}, skipping"
    return
  fi

  echo "=== Fixing LLD cmake target dependencies (zlib/zstd) ==="
  local _extra_libs="-lz"
  if [[ "${target_platform}" == linux-* ]] || [[ "${target_platform}" == osx-* ]]; then
    _extra_libs="-lz;-lzstd"
  fi

  {
    echo ""
    echo "# zig-llvm fixup: lld static archives directly reference zlib/zstd symbols"
    echo "# (lld/ELF/OutputSections.cpp compression). Ensure consumers link them."
    echo "foreach(_lld_target lldELF lldCOFF lldMachO lldWasm lldMinGW lldCommon)"
    echo "  if(TARGET lld::\${_lld_target})"
    echo "    set_property(TARGET lld::\${_lld_target} APPEND PROPERTY"
    echo "      INTERFACE_LINK_LIBRARIES \"${_extra_libs}\")"
    echo "  endif()"
    echo "endforeach()"
  } >> "${lld_config}"

  echo "  Appended ${_extra_libs} to ${lld_config}"
}

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
