function remove_unneeded() {
  # Remove static libraries - zig only needs shared libs (saves ~500MB)
  echo "=== Removing static libraries ==="
  # find "${LLVM_INSTALL}/lib" -name "*.a" -type f -delete
  find "${LLVM_INSTALL}/lib" -name "*.a" ! -name "liblld*.a" -type f -delete
  echo "  Removed .a files from ${LLVM_INSTALL}/lib"

  # Remove all tools except llvm-config (other tools come from conda-forge llvm-tools)
  # Many LLVM tools are symlinks, so delete both files and symlinks
  echo "=== Removing tools except llvm-config ==="
  find "${LLVM_INSTALL}/bin" \( -type f -o -type l \) ! \( -name "llvm-config*" -o -name "*-tblgen" \) -delete
  ls "${LLVM_INSTALL}/bin/"
  echo "  Kept only llvm-config in ${LLVM_INSTALL}/bin"

  # Remove share/ directory (clang-format helpers, cmake modules we don't need)
  echo "=== Removing share/ directory ==="
  rm -rf "${LLVM_INSTALL}/share"
  echo "  Removed ${LLVM_INSTALL}/share"

  # Remove C API headers (zig uses C++ API, not C bindings)
  # echo "=== Removing C API headers ==="
  # rm -rf "${LLVM_INSTALL}/include/llvm-c"
  # rm -rf "${LLVM_INSTALL}/include/clang-c"
  # echo "  Removed llvm-c/ and clang-c/ headers"

  # Remove Clang builtin headers (zig bundles its own libc headers)
  # echo "=== Removing Clang builtin headers ==="
  # rm -rf "${LLVM_INSTALL}/lib/clang"
  # echo "  Removed lib/clang/"

  # Create llvm-config wrapper that filters out flags unsupported by zig's linker
  # zig build calls llvm-config --ldflags and passes results directly to its linker
  # Flags like -Bsymbolic-functions are GNU ld specific and not supported by lld/zig linker
  echo "=== Creating llvm-config wrapper to filter unsupported linker flags ==="
  mv "${LLVM_INSTALL}/bin/llvm-config" "${LLVM_INSTALL}/bin/llvm-config.real"
  cat > "${LLVM_INSTALL}/bin/llvm-config" << 'WRAPPER_EOF'
#!/usr/bin/env bash
# Wrapper for llvm-config that filters out flags unsupported by zig's linker
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_CONFIG="${SCRIPT_DIR}/llvm-config.real"

# Run the real llvm-config
output=$("${REAL_CONFIG}" "$@")

# Filter output for --ldflags and --system-libs which may contain unsupported flags
for arg in "$@"; do
  case "$arg" in
    --ldflags|--system-libs|--libs|--link-static|--link-shared)
      # Filter out GNU ld specific flags that zig's linker doesn't support
      output=$(echo "$output" | sed \
        -e 's/-Wl,-Bsymbolic-functions//g' \
        -e 's/-Bsymbolic-functions//g' \
        -e 's/-Wl,-Bsymbolic//g' \
        -e 's/-Bsymbolic//g' \
        -e 's/-Wl,--disable-new-dtags//g' \
        -e 's/  */ /g' \
        -e 's/^ *//' \
        -e 's/ *$//')
      break
      ;;
  esac
done

echo "$output"
WRAPPER_EOF
  chmod +x "${LLVM_INSTALL}/bin/llvm-config"
  echo "  Created wrapper: ${LLVM_INSTALL}/bin/llvm-config"
}
