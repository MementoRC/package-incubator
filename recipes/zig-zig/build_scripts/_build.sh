# ZIG BUILD FUNCTIONS

function build_zig_with_zig() {
  local build_dir=$1
  local zig=$2
  local install_dir=$3

  local current_dir
  current_dir=$(pwd)

  if [[ -d "${build_dir}" ]]; then
    cd "${build_dir}" || return 1
      echo "zig build command: ${zig} build --prefix ${install_dir} ${EXTRA_ZIG_ARGS[@]+"${EXTRA_ZIG_ARGS[@]}"} -Dversion-string=${PKG_VERSION}"
      local rc=0
      "${zig}" build \
        --prefix "${install_dir}" \
        ${EXTRA_ZIG_ARGS[@]+"${EXTRA_ZIG_ARGS[@]}"} \
        -Dversion-string="${PKG_VERSION}" || rc=$?
        # --search-prefix "${install_dir}" \
      if [[ $rc -ne 0 ]]; then
        echo "ERROR: zig build failed with exit code ${rc}" >&2
        cd "${current_dir}" || true
        return $rc
      fi
    cd "${current_dir}" || return 1
  else
    echo "No build directory found" >&2
    return 1
  fi
}

function configure_cmake() {
  local build_dir=$1
  local install_dir=$2
  local zig=${3:-}

  # Build local cmake args array
  local cmake_args=()

  # Add zig compiler configuration if provided
  # Prefer ZIG_CC/ZIG_CXX from setup_zig_cc, fallback to legacy zig parameter
  if [[ -n "${ZIG_CC:-}" ]] && [[ -n "${ZIG_CXX:-}" ]]; then
    # Use wrappers created by setup_zig_cc (preferred)
    cmake_args+=("-DCMAKE_C_COMPILER=${ZIG_CC}")
    cmake_args+=("-DCMAKE_CXX_COMPILER=${ZIG_CXX}")
    cmake_args+=("-DCMAKE_AR=${ZIG_AR:-${zig:-ar}}")
    cmake_args+=("-DCMAKE_RANLIB=${ZIG_RANLIB:-ranlib}")
  elif [[ -n "${zig}" ]]; then
    # Legacy path: construct zig compiler args (requires ZIG_TARGET)
    local _target="${ZIG_TARGET:-x86_64-linux-gnu}"
    local _c="${zig};cc;-target;${_target};-mcpu=${MCPU:-baseline}"
    local _cxx="${zig};c++;-target;${_target};-mcpu=${MCPU:-baseline}"

    # Add QEMU flag for native (non-cross) compilation
    if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "0" ]]; then
      _c="${_c};-fqemu"
      _cxx="${_cxx};-fqemu"
    fi

    cmake_args+=("-DCMAKE_C_COMPILER=${_c}")
    cmake_args+=("-DCMAKE_CXX_COMPILER=${_cxx}")
    cmake_args+=("-DCMAKE_AR=${zig}")
    cmake_args+=("-DZIG_AR_WORKAROUND=ON")
  fi

  # Merge with global EXTRA_CMAKE_ARGS if it exists
  # Use ${var+x} syntax for bash 3.2 compatibility (macOS default bash)
  if [[ -n "${EXTRA_CMAKE_ARGS+x}" ]]; then
    cmake_args+=("${EXTRA_CMAKE_ARGS[@]}")
  fi

  # Add CMAKE_ARGS from environment if requested
  if [[ ${USE_CMAKE_ARGS:-0} == 1 ]]; then
    IFS=' ' read -r -a cmake_args_from_env <<< "${CMAKE_ARGS:-}"
    cmake_args+=("${cmake_args_from_env[@]}")
  fi

  # Create build directory and run cmake
  mkdir -p "${build_dir}" || return 1

  (
    cd "${build_dir}" &&
    cmake "${cmake_source_dir}" \
      -D CMAKE_INSTALL_PREFIX="${install_dir}" \
      "${cmake_args[@]}" \
      -G Ninja
  ) || return 1
}

# Disable langref/doctest build for cross-compilation targets where running
# the compiled doctests is unreliable (sysroot-free libc, limited qemu fidelity).
# Matches zig-gcc's -Dno-langref flag used when qemu is absent or unreliable.
# Takes build_dir as argument (unused here; kept for call-site compatibility).
function remove_failing_langref() {
  local _build_dir="${1:-}"
  echo "Disabling langref doctests for cross-build (-Dno-langref)"
  EXTRA_ZIG_ARGS+=(-Dno-langref)
}

function configure_cmake_zigcpp() {
  local build_dir=$1
  local install_dir=$2
  local zig=${3:-}

  # Cross-build (Linux/macOS): ZIG_CC/ZIG_CXX are BUILD-host wrappers (e.g. x86_64-...-zig-cxx).
  # Without -target, cmake compiles zigcpp objects for BUILD arch, not TARGET arch,
  # causing an "incompatible" error at final link (e.g. x86_64 .o linked into aarch64 zig).
  # macOS cross also needs -target: cmake's compiler-ABI TryCompile probe invokes the compiler
  # directly (bypassing force-load shims), so the wrapper deduces target from its own filename
  # (arm64) instead of the intended target — fails with "unknown target CPU 'apple-m1'" on x86_64.
  # Windows is excluded: the cmake cache seed sets CMAKE_C/CXX_FLAGS with -target.
  if is_linux && is_cross; then
    # The cmake compiler check otherwise links a test executable, making zig-cc
    # invoke the cross-GCC linker driver (e.g. powerpc64le-conda-linux-gnu-gcc),
    # absent on the build host ("Failed to spawn GCC: FileNotFound"), so config.h
    # is never generated. STATIC_LIBRARY makes the check compile-only.
    EXTRA_CMAKE_ARGS+=(-DCMAKE_C_FLAGS="-target ${ZIG_TRIPLET}" -DCMAKE_CXX_FLAGS="-target ${ZIG_TRIPLET}" -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY)
  elif is_osx && is_cross; then
    EXTRA_CMAKE_ARGS+=(-DCMAKE_C_FLAGS="-target ${ZIG_TRIPLET}" -DCMAKE_CXX_FLAGS="-target ${ZIG_TRIPLET}")
  fi

  configure_cmake "${build_dir}" "${install_dir}" "${zig}" || return 1
  pushd "${build_dir}"
    cmake --build . --target zigcpp -- -j"${CPU_COUNT}"
  popd
}
