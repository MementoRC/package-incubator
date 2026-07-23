source "${RECIPE_DIR}/building/_common.sh"

function _compile_stub_object() {
  # Helper to compile a stub .c file into a .o object
  # Args: cc_compiler src_file out_file label target_flags (optional, for
  # cross builds -- e.g. "--target=${ZIG_TRIPLET}" so the stub matches the
  # cross target's ELF class instead of defaulting to the build platform)
  local cc="${1}"
  local src="${2}"
  local out="${3}"
  local label="${4}"
  local target_flags="${5:-}"

  # shellcheck disable=SC2086 # target_flags is intentionally unquoted to allow word-splitting
  "${cc}" ${target_flags} -c "${src}" -o "${out}" || {
    echo "ERROR: Failed to compile ${label} stub" >&2
    return 1
  }

  if [[ ! -f "${out}" ]]; then
    echo "ERROR: ${label}.o was not created" >&2
    return 1
  fi
}

function create_pthread_atfork_stub() {
  # Create pthread_atfork stub for glibc 2.28 on PowerPC64LE and aarch64
  # glibc 2.28 for these architectures doesn't export pthread_atfork symbol
  # (x86_64 glibc 2.28 has it, but PowerPC64LE and aarch64 don't)

  local cc_compiler="${1}"
  local output_dir="${2:-${SRC_DIR}}"

  dbg echo "=== atfork stubs ==="

  cat > "${output_dir}/pthread_atfork_stub.c" << 'EOF'
// Strong __wrap_pthread_atfork for --wrap=pthread_atfork linker redirect.
// The linker rewrites all pthread_atfork references to __wrap_pthread_atfork;
// this strong definition satisfies them without pulling in libpthread_nonshared.a
// (which emits R_PPC64_REL24 relocations that truncate on ppc64le).
// Declared strong because the cmake path's --wrap mechanism does not require weak;
// the stub is intentionally NOT injected on the zig-build path (see recipe/build.sh),
// so duplicate-symbol concerns do not apply. The --wrap flag renames references
// regardless of weak/strong, so the redirect still activates correctly on the cmake path.
// This is safe because Zig compiler doesn't actually use fork().
int __wrap_pthread_atfork(void (*prepare)(void), void (*parent)(void), void (*child)(void)) {
    // Stub implementation - returns success without doing anything
    // (void) casts suppress unused parameter warnings
    (void)prepare;
    (void)parent;
    (void)child;
    return 0;  // Success
}
EOF

  _compile_stub_object "${cc_compiler}" "${output_dir}/pthread_atfork_stub.c" "${output_dir}/pthread_atfork_stub.o" "pthread_atfork" || return 1

  return 0
}

function create_libc_single_threaded_stub() {
  # Create __libc_single_threaded stub for cross-compiler builds targeting glibc < 2.32
  # GCC 15+ libstdc++/zigcpp references __libc_single_threaded (added in glibc 2.32).
  # When targeting gnu.2.17 or similar, the symbol is missing at link time.
  #
  # Declared as 'char' in <sys/single_threaded.h> (not bool).
  # Value 0 = multi-threaded (conservative/safe default for a stub).

  local cc_compiler="${1}"
  local output_dir="${2:-${SRC_DIR}}"
  # Optional target flags (e.g. "--target=${ZIG_TRIPLET}") -- required on cross
  # builds since cc_compiler here is zig-cc-early, which has no baked-in
  # target and would otherwise compile the stub for the build platform,
  # producing an ELF class mismatch at the final self-hosted link.
  local target_flags="${3:-}"

  cat > "${output_dir}/libc_single_threaded_stub.c" << 'EOF'
// Weak stub for __libc_single_threaded when targeting glibc < 2.32
// glibc 2.32 introduced this symbol; GCC 15 libstdc++ references it.
// Value 0 = multi-threaded (safe conservative default).
__attribute__((weak))
char __libc_single_threaded = 0;
EOF

  _compile_stub_object "${cc_compiler}" "${output_dir}/libc_single_threaded_stub.c" "${output_dir}/libc_single_threaded_stub.o" "libc_single_threaded" "${target_flags}" || return 1

  return 0
}
