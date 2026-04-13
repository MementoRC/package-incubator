#!/usr/bin/env bash
# Build LLVM with zig cc for zig-llvmdev package
# This produces LLVM/Clang/LLD shared libraries with libc++ ABI
# compatible with zig-cc-built zigcpp
# BUILD_SCRIPT_VERSION=2026-04-27b

set -euxo pipefail
IFS=$'\n\t'

if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  echo "Attempting to re-exec with conda bash..."
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  elif [[ -x "${BUILD_PREFIX}/Library/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/Library/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi

source ${RECIPE_DIR}/building/post-install.sh
source ${RECIPE_DIR}/building/remove-unneeded.sh
source ${RECIPE_DIR}/building/strip_atexit_from_implib.sh
source ${RECIPE_DIR}/building/_lld_bundle.sh

source ${RECIPE_DIR}/building/_env.sh
source ${RECIPE_DIR}/building/_cross_compile.sh
source ${RECIPE_DIR}/building/_zig_wrappers.sh
source ${RECIPE_DIR}/building/_cmake_flags.sh
source ${RECIPE_DIR}/building/_runtimes_build.sh
source ${RECIPE_DIR}/building/_llvm_build.sh
source ${RECIPE_DIR}/building/_post_build.sh
