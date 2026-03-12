#!/bin/bash
# Zig compiler deactivation script
# Installed to: $PREFIX/etc/conda/deactivate.d/zig_deactivate.sh

# === Unset all zig-cc variables ===
unset ZIG_CC ZIG_CXX ZIG_AR ZIG_RANLIB ZIG_ASM ZIG_RC
unset ZIG_CXX_SHARED ZIG_FORCE_LOAD_CC ZIG_FORCE_LOAD_CXX

# === Unset toolchain identification ===
unset CONDA_ZIG_BUILD CONDA_ZIG_HOST

# === Unset cross-compiler variables ===
unset ZIG_TARGET_TRIPLET
