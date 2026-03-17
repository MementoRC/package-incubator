# Build musl shared libraries for cross-compilation targets

build_musl_shared_libs() {
  local zig_exe="$1"
  local install_prefix="$2"

  if [[ -z "${zig_exe}" ]] || [[ ! -x "${zig_exe}" ]]; then
    echo "ERROR: build_musl_shared_libs requires valid zig executable" >&2
    return 1
  fi

  if [[ -z "${install_prefix}" ]]; then
    echo "ERROR: build_musl_shared_libs requires install_prefix" >&2
    return 1
  fi

  echo "=== Building musl shared libraries for cross-compilation targets ==="

  # Set LD_LIBRARY_PATH to find libLLVM from zig-llvm package
  export LD_LIBRARY_PATH="${install_prefix}/lib/zig-llvm/lib:${LD_LIBRARY_PATH:-}"

  # Define cross-compilation targets (architecture-os-abi)
  local targets=(
    "riscv64-linux-musl"
  )

  local musl_src="${SRC_DIR}/musl-src"
  mkdir -p "${musl_src}"

  # Create minimal musl wrapper source that exposes libc functions
  cat > "${musl_src}/libzig-musl.c" << 'EOF'
// Minimal wrapper to build musl as shared library
// Zig's bundled musl will provide all the actual implementations

// Force export of common libc symbols
__attribute__((visibility("default"))) void* malloc(unsigned long size);
__attribute__((visibility("default"))) void free(void* ptr);
__attribute__((visibility("default"))) int printf(const char* fmt, ...);
__attribute__((visibility("default"))) void* memcpy(void* dst, const void* src, unsigned long n);
__attribute__((visibility("default"))) void* memset(void* s, int c, unsigned long n);

// Mark as used to prevent optimization
__attribute__((used)) static const char zig_musl_marker[] = "zig-musl-shared";
EOF

  for target in "${targets[@]}"; do
    local arch="${target%%-*}"
    local target_dir="${install_prefix}/lib/zig/musl/${arch}"

    echo "  Building musl for ${target}..."
    mkdir -p "${target_dir}"

    # Build musl as a shared library using zig's bundled musl
    # Use -target with musl to get zig's bundled musl implementation
    if "${zig_exe}" build-lib "${musl_src}/libzig-musl.c" \
        -target "${target}" \
        -dynamic \
        -fPIC \
        -lc \
        -O ReleaseSafe \
        --name zig-musl-${arch} \
        -femit-bin="${target_dir}/libzig-musl.so.1" \
        2>&1; then

      echo "    ✓ Built libzig-musl.so.1 for ${arch}"

      # Create symlink without version
      ln -sf libzig-musl.so.1 "${target_dir}/libzig-musl.so"

      # Create ld-musl symlink (musl dynamic linker)
      case "${arch}" in
        x86_64)
          ln -sf libzig-musl.so.1 "${target_dir}/ld-musl-x86_64.so.1"
          ;;
        aarch64)
          ln -sf libzig-musl.so.1 "${target_dir}/ld-musl-aarch64.so.1"
          ;;
        riscv64)
          ln -sf libzig-musl.so.1 "${target_dir}/ld-musl-riscv64.so.1"
          ;;
        powerpc64le)
          ln -sf libzig-musl.so.1 "${target_dir}/ld-musl-powerpc64le.so.1"
          ;;
      esac

    else
      echo "    ⚠ Failed to build musl for ${target} (non-fatal, continuing)"
    fi
  done

  # Create a helper script for users to cross-compile with zig musl
  cat > "${install_prefix}/bin/${CONDA_TRIPLET}-zig-cc-musl" << 'EOFSCRIPT'
#!/usr/bin/env bash
# Helper script to cross-compile with zig's bundled musl

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: ${CONDA_TRIPLET}-zig-cc-musl <target-arch> <source-files...> [additional-flags]"
  echo ""
  echo "Example: ${CONDA_TRIPLET}-zig-cc-musl riscv64 app.c -o app"
  echo ""
  echo "Available architectures: riscv64"
  exit 1
fi

TARGET_ARCH="$1"
shift

ZIG_INSTALL_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
MUSL_LIB_DIR="${ZIG_INSTALL_DIR}/lib/zig/musl/${TARGET_ARCH}"

if [[ ! -d "${MUSL_LIB_DIR}" ]]; then
  echo "ERROR: Musl libraries not found for ${TARGET_ARCH}" >&2
  echo "Available: $(ls -1 "${ZIG_INSTALL_DIR}/lib/zig/musl" 2>/dev/null | tr '\n' ' ')" >&2
  exit 1
fi

# Execute zig with musl target and our bundled musl libraries
exec "${zig_exe}" cc \
  -target "${TARGET_ARCH}-linux-musl" \
  -L"${MUSL_LIB_DIR}" \
  -Wl,-rpath,"${MUSL_LIB_DIR}" \
  -Wl,--dynamic-linker="${MUSL_LIB_DIR}/ld-musl-${TARGET_ARCH}.so.1" \
  "$@"
EOFSCRIPT

  chmod +x "${install_prefix}/bin/${CONDA_TRIPLET}-zig-cc-musl"

  echo "=== Musl shared libraries built successfully ==="
  echo "    Location: ${install_prefix}/lib/zig/musl/"
  echo "    Helper script: ${install_prefix}/bin/${CONDA_TRIPLET}-zig-cc-musl"
  echo ""
  echo "Usage example:"
  echo "  ${CONDA_TRIPLET}-zig-cc-musl riscv64 app.c -o app"
  echo "  qemu-riscv64 -L ${install_prefix}/lib/zig/musl/riscv64 ./app"

  return 0
}

post_install() {
  # Set RPATH so zig can find libLLVM from zig-llvm package at runtime
  if is_linux; then
    echo "Setting RPATH for zig executable to find zig-llvm libraries..."

    # Replace any absolute DT_NEEDED path with just its basename.
    # The build environment leaves placehold-prefix absolute paths for libc++,
    # libc++abi, libclang-cpp, libLLVM, etc. — all must be reduced to sonames
    # so the RPATH ($ORIGIN/../lib/zig-llvm/lib) can resolve them at runtime.
    while IFS= read -r needed; do
      if [[ "${needed}" == *"/"* ]]; then
        basename_lib="${needed##*/}"
        echo "  Replacing absolute DT_NEEDED path: ${needed} -> ${basename_lib}"
        patchelf --replace-needed "${needed}" "${basename_lib}" "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig
      fi
    done < <(patchelf --print-needed "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig 2>/dev/null)

    patchelf --set-rpath "\$ORIGIN/../lib/zig-llvm/lib:\$ORIGIN/../lib:\$ORIGIN/../" "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig
    echo "RPATH set: $(patchelf --print-rpath ${PREFIX}/bin/"${CONDA_TRIPLET}"-zig)"
  elif is_osx; then
    # NOTE: Do NOT rewrite zig binary load commands here.
    # build.sh L545-575 already sets them to @loader_path/../lib/zig-llvm/lib/<name>
    # which survives rattler-build packaging (rattler-build leaves @loader_path untouched).
    # Using @rpath/ instead would BREAK because rattler-build strips rpaths not in
    # its prefix allowlist, leaving @rpath/ refs with no rpaths to resolve them.
    echo "macOS: zig binary load commands already set to @loader_path by build.sh"
  fi

  # Build musl shared libraries for cross-compilation targets
  # This enables sysroot-free cross-compilation with dynamic linking
  # Only on Linux — musl ELF shared objects are not useful on macOS
  if is_linux; then
    # Use the installed zig binary to build musl libraries
    installed_zig="${PREFIX}/bin/${CONDA_TRIPLET}-zig"
    if [[ -x "${installed_zig}" ]]; then
      build_musl_shared_libs "${installed_zig}" "${PREFIX}" || echo "⚠ Musl shared library build failed (non-fatal)"
    else
      echo "⚠ Skipping musl shared library build - zig not found at ${installed_zig}"
    fi
  fi

  # Cache successful build (saves before rattler-build cleanup)
  if [[ "${ZIG_USE_CACHE:-}" == "0" ]] || [[ "${ZIG_USE_CACHE:-}" == "1" ]]; then
    # stub_cache.sh already sourced at the top if ZIG_USE_CACHE=1
    [[ "$(type -t stub_cache_save)" != "function" ]] && source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
    stub_cache_save
    echo "=== Build cached for future restoration ==="
  fi
}
