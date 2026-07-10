#!/usr/bin/env bash
# Build zstd with zig cc for zig toolchain
set -euxo pipefail

echo "=== Building zig-zstd with zig cc ==="

# Upstream conda-forge zig package ships the zig binary in BUILD_PREFIX.
# Configure it as the cross-compiler targeting riscv64-linux-gnu.
# Note: zig bundles lld; riscv64 lld support landed in LLVM 12 (zig >=0.10),
#       so zig's bundled lld should support riscv64 here. If link failures
#       occur, revisit with -fuse-ld=bfd as a follow-up.
#
# cmake requires CMAKE_C_COMPILER to be a single binary path, not a command
# line with arguments.  Write thin wrapper scripts that bake in the -target
# flag; the single-quoted heredoc delimiter ('WRAPPER_EOF') prevents bash
# from expanding ${BUILD_PREFIX} here — it is written literally and expanded
# at wrapper-script execution time by the shell that runs the wrapper.
_zig_wrapper_dir="${SRC_DIR}/zig-wrappers"
mkdir -p "${_zig_wrapper_dir}"

cat > "${_zig_wrapper_dir}/zig-cc" <<'WRAPPER_EOF'
#!/usr/bin/env bash
exec "${BUILD_PREFIX}/bin/zig" cc -target riscv64-linux-gnu "$@"
WRAPPER_EOF

cat > "${_zig_wrapper_dir}/zig-ar" <<'WRAPPER_EOF'
#!/usr/bin/env bash
exec "${BUILD_PREFIX}/bin/zig" ar "$@"
WRAPPER_EOF

cat > "${_zig_wrapper_dir}/zig-ranlib" <<'WRAPPER_EOF'
#!/usr/bin/env bash
exec "${BUILD_PREFIX}/bin/zig" ranlib "$@"
WRAPPER_EOF

chmod +x "${_zig_wrapper_dir}"/zig-{cc,ar,ranlib}

export ZIG_CC="${_zig_wrapper_dir}/zig-cc"
export ZIG_AR="${_zig_wrapper_dir}/zig-ar"
export ZIG_RANLIB="${_zig_wrapper_dir}/zig-ranlib"

# Clear conda compiler flags - zig handles everything
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
export CFLAGS="" CXXFLAGS="" LDFLAGS="" CPPFLAGS=""

mkdir -p build
cd build

# zstd CMake is in build/cmake subdirectory
cmake ../build/cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}/lib/zig-zstd" \
    -DCMAKE_C_COMPILER="${ZIG_CC}" \
    -DCMAKE_AR="${ZIG_AR}" \
    -DCMAKE_RANLIB="${ZIG_RANLIB}" \
    -DZSTD_BUILD_SHARED=ON \
    -DZSTD_BUILD_STATIC=OFF \
    -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_TESTS=OFF \
    -DZSTD_BUILD_CONTRIB=OFF \
    -DZSTD_MULTITHREAD_SUPPORT=ON \
    -G Ninja

cmake --build . -j"${CPU_COUNT}"
cmake --install .
