_CLANG=(
  -DCLANG_ENABLE_OBJC_REWRITER=ON
  -DCLANG_LINK_CLANG_DYLIB=ON

  -DCLANG_BUILD_TOOLS=OFF
  -DCLANG_ENABLE_ARCMT=OFF
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF
  -DCLANG_INCLUDE_DOCS=OFF
  -DCLANG_INCLUDE_TESTS=OFF
  -DCLANG_TOOL_APINOTES_TEST_BUILD=OFF
  -DCLANG_TOOL_CLANG_DIFF_BUILD=OFF
  -DCLANG_TOOL_CLANG_FUZZER_BUILD=OFF
  -DCLANG_TOOL_CLANG_IMPORT_TEST_BUILD=OFF
  -DCLANG_TOOL_CLANG_LINKER_WRAPPER_BUILD=OFF
  -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF
  -DCLANG_TOOL_LIBCLANG_BUILD=OFF
)

# LLVM_TARGETS_TO_BUILD: 10-target curated list. On aarch64-windows-gnu the
# resulting libLLVM-20.dll exceeds the PE/COFF 65535 export-ordinal limit
# because GPU backends (AMDGPU + NVPTX) have very large TableGen-generated
# instruction-selection tables. Drop them on aarch64-windows-gnu only —
# zig doesn't target GPU code generation on win-arm64.
_llvm_targets="X86;AArch64;ARM;PowerPC;RISCV;WebAssembly;SystemZ;AMDGPU;AVR;NVPTX"
if [[ "${ZIG_TRIPLET}" == aarch64-* ]] && is_not_unix; then
    # zig requires AArch64;ARM;PowerPC;RISCV;SystemZ;WebAssembly;X86 to be built
    # (see recipes/zig-zig/patches/relax-llvm-required-targets.patch's
    # ZIG_LLVM_REQUIRED_TARGETS). Only the GPU backends (AMDGPU, NVPTX) and AVR
    # are dropped -- their huge TableGen instruction-selection tables were the
    # actual cause of exceeding the PE/COFF 65535 export-ordinal limit, not
    # ARM/PowerPC/RISCV/SystemZ.
    _llvm_targets="X86;AArch64;ARM;PowerPC;RISCV;SystemZ;WebAssembly"
    echo "  win-arm64: pruned LLVM_TARGETS_TO_BUILD (dropped AVR, AMDGPU, NVPTX) to fit PE/COFF 65535 export limit"
fi

_LLVM=(
  # LLVM_BUILD_TOOLS=ON with individual disables. Both ON and OFF are "leaky":
  # ON requires explicit disables per tool (whack-a-mole on LLVM bumps).
  # OFF prevents cmake --install from installing even whitelisted tools.
  # ON + explicit list is the lesser evil — at least llvm-config gets installed.
  -DLLVM_BUILD_TOOLS=ON
  -DLLVM_TOOL_LLVM_CONFIG_BUILD=ON
  -DLLVM_BUILD_LLVM_DYLIB=ON
  -DLLVM_DYLIB_COMPONENTS="all"
  -DLLVM_ENABLE_LIBCXX=ON
  -DLLVM_ENABLE_LIBXML2=ON
  -DLLVM_ENABLE_PROJECTS="clang;lld"
  -DLLVM_ENABLE_RTTI=ON
  -DLLVM_ENABLE_ZLIB=ON
  -DLLVM_LINK_LLVM_DYLIB=ON
  -DLLVM_TARGETS_TO_BUILD="${_llvm_targets}"

  -DLLVM_DEFAULT_TARGET_TRIPLE="${LLVM_TRIPLET}"
  -DLLVM_BUILD_UTILS=OFF
  -DLLVM_ENABLE_ASSERTIONS=OFF
  -DLLVM_ENABLE_BACKTRACES=OFF
  -DLLVM_ENABLE_BINDINGS=OFF
  -DLLVM_ENABLE_CRASH_OVERRIDES=OFF
  -DLLVM_ENABLE_LIBEDIT=OFF
  -DLLVM_ENABLE_LIBPFM=OFF
  -DLLVM_ENABLE_OCAMLDOC=OFF
  -DLLVM_ENABLE_PLUGINS=OFF
  -DLLVM_ENABLE_Z3_SOLVER=OFF
  -DLLVM_HAS_LOGF128=OFF
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_DOCS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INCLUDE_UTILS=OFF
  -DLLVM_INSTALL_TOOLCHAIN_ONLY=OFF
  # Disable ALL tools except llvm-config and llvm-shlib (libLLVM.so/.dylib).
  # Generated from LLVM 20.1.8 llvm/tools/ source tree (add_llvm_implicit_projects
  # auto-discovers every subdirectory with CMakeLists.txt via file(GLOB)).
  # LLVM_BUILD_TOOLS=ON is REQUIRED — OFF prevents cmake --install from installing
  # even whitelisted tools. Individual LLVM_TOOL_*_BUILD=OFF skips add_subdirectory()
  # entirely (no configure, no build, no install).
  # On macOS: tools linking against libLLVM.dylib fail (zig cc visibility issue).
  # On Windows: saves ~60min build time.
  # KEEP: llvm-config (ON above), llvm-shlib (builds libLLVM shared library)
  -DLLVM_TOOL_BUGPOINT_BUILD=OFF
  -DLLVM_TOOL_BUGPOINT_PASSES_BUILD=OFF
  -DLLVM_TOOL_DSYMUTIL_BUILD=OFF
  -DLLVM_TOOL_DXIL_DIS_BUILD=OFF
  -DLLVM_TOOL_GOLD_BUILD=OFF
  -DLLVM_TOOL_LLC_BUILD=OFF
  -DLLVM_TOOL_LLI_BUILD=OFF
  -DLLVM_TOOL_LLVM_AR_BUILD=ON  # ON: llvm-ar creates llvm-dlltool symlink (needed for MinGW import lib generation)
  -DLLVM_TOOL_LLVM_AS_BUILD=OFF
  -DLLVM_TOOL_LLVM_AS_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_BCANALYZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_C_TEST_BUILD=OFF
  -DLLVM_TOOL_LLVM_CAT_BUILD=OFF
  -DLLVM_TOOL_LLVM_CFI_VERIFY_BUILD=OFF
  -DLLVM_TOOL_LLVM_CGDATA_BUILD=OFF
  -DLLVM_TOOL_LLVM_COV_BUILD=OFF
  -DLLVM_TOOL_LLVM_CTXPROF_UTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_CVTRES_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXFILT_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXMAP_BUILD=OFF
  -DLLVM_TOOL_LLVM_DEBUGINFO_ANALYZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_DEBUGINFOD_BUILD=OFF
  -DLLVM_TOOL_LLVM_DEBUGINFOD_FIND_BUILD=OFF
  -DLLVM_TOOL_LLVM_DIFF_BUILD=OFF
  -DLLVM_TOOL_LLVM_DIS_BUILD=OFF
  -DLLVM_TOOL_LLVM_DIS_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_DLANG_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_DRIVER_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWARFDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWARFUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWP_BUILD=OFF
  -DLLVM_TOOL_LLVM_EXEGESIS_BUILD=OFF
  -DLLVM_TOOL_LLVM_EXTRACT_BUILD=OFF
  -DLLVM_TOOL_LLVM_GSYMUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_IFS_BUILD=OFF
  -DLLVM_TOOL_LLVM_ISEL_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_ITANIUM_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_JITLINK_BUILD=OFF
  -DLLVM_TOOL_LLVM_JITLISTENER_BUILD=OFF
  -DLLVM_TOOL_LLVM_LIBTOOL_DARWIN_BUILD=OFF
  -DLLVM_TOOL_LLVM_LINK_BUILD=OFF
  -DLLVM_TOOL_LLVM_LIPO_BUILD=OFF
  -DLLVM_TOOL_LLVM_LTO_BUILD=OFF
  -DLLVM_TOOL_LLVM_LTO2_BUILD=OFF
  -DLLVM_TOOL_LLVM_MC_BUILD=OFF
  -DLLVM_TOOL_LLVM_MC_ASSEMBLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_MC_DISASSEMBLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_MCA_BUILD=OFF
  -DLLVM_TOOL_LLVM_MICROSOFT_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_ML_BUILD=OFF
  -DLLVM_TOOL_LLVM_MODEXTRACT_BUILD=OFF
  -DLLVM_TOOL_LLVM_MT_BUILD=OFF
  -DLLVM_TOOL_LLVM_NM_BUILD=OFF
  -DLLVM_TOOL_LLVM_OBJCOPY_BUILD=OFF
  -DLLVM_TOOL_LLVM_OBJDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_OPT_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_OPT_REPORT_BUILD=OFF
  -DLLVM_TOOL_LLVM_PDBUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_PROFDATA_BUILD=OFF
  -DLLVM_TOOL_LLVM_PROFGEN_BUILD=OFF
  -DLLVM_TOOL_LLVM_RC_BUILD=OFF
  -DLLVM_TOOL_LLVM_READOBJ_BUILD=OFF
  -DLLVM_TOOL_LLVM_READTAPI_BUILD=OFF
  -DLLVM_TOOL_LLVM_REDUCE_BUILD=OFF
  -DLLVM_TOOL_LLVM_REMARKUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_RTDYLD_BUILD=OFF
  -DLLVM_TOOL_LLVM_RUST_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_SIM_BUILD=OFF
  -DLLVM_TOOL_LLVM_SIZE_BUILD=OFF
  -DLLVM_TOOL_LLVM_SPECIAL_CASE_LIST_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_SPLIT_BUILD=OFF
  -DLLVM_TOOL_LLVM_STRESS_BUILD=OFF
  -DLLVM_TOOL_LLVM_STRINGS_BUILD=OFF
  -DLLVM_TOOL_LLVM_SYMBOLIZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_TLI_CHECKER_BUILD=OFF
  -DLLVM_TOOL_LLVM_UNDNAME_BUILD=OFF
  -DLLVM_TOOL_LLVM_XRAY_BUILD=OFF
  -DLLVM_TOOL_LLVM_YAML_NUMERIC_PARSER_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_YAML_PARSER_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LTO_BUILD=OFF
  -DLLVM_TOOL_OBJ2YAML_BUILD=OFF
  -DLLVM_TOOL_OPT_BUILD=OFF
  -DLLVM_TOOL_OPT_VIEWER_BUILD=OFF
  -DLLVM_TOOL_REDUCE_CHUNK_LIST_BUILD=OFF
  -DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF
  -DLLVM_TOOL_SANCOV_BUILD=OFF
  -DLLVM_TOOL_SANSTATS_BUILD=OFF
  -DLLVM_TOOL_SPIRV_TOOLS_BUILD=OFF
  -DLLVM_TOOL_VERIFY_USELISTORDER_BUILD=OFF
  -DLLVM_TOOL_VFABI_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_XCODE_TOOLCHAIN_BUILD=OFF
  -DLLVM_TOOL_YAML2OBJ_BUILD=OFF
)


echo "=== Configuring LLVM ==="
echo "  Install prefix: ${LLVM_INSTALL} (separate from conda-forge llvmdev)"
_CMAKE=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}"
  -DCMAKE_PREFIX_PATH="${LLVM_INSTALL};${PREFIX};${BUILD_PREFIX}"
  -DCMAKE_LINK_DEPENDS_USE_LINKER=OFF

  -DCMAKE_AR="${ZIG_AR}"
  -DCMAKE_C_COMPILER="${ZIG_CC}"
  -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
  -DCMAKE_ASM_COMPILER="${ZIG_ASM}"
  -DCMAKE_RANLIB="${ZIG_RANLIB}"

  # Rpath settings - build tools (llvm-min-tblgen, etc) need to find conda libs at runtime
  # LLVM_BUILD/lib is where libLLVM.so lives during the build phase - required so
  # libclang-cpp.so links against it by bare soname (not a relative lib/ path).
  -DCMAKE_BUILD_RPATH="${LLVM_INSTALL}/lib;${LLVM_BUILD}/lib;${BUILD_PREFIX}/lib;${PREFIX}/lib"
  -DCMAKE_INSTALL_RPATH="${LLVM_INSTALL}/lib"

  -DCMAKE_C_FLAGS="-fvisibility=default"
  -DCMAKE_CXX_FLAGS="-fvisibility=default"
)

# RC compiler (resource compiler for Windows .exe version info).
# On Windows, Platform/Windows-GNU.cmake auto-enables RC language during
# project(). CMake 4.2 converts ALL paths to native backslashes, then chokes
# on escape sequences (\a from D:\a\..., \p from \package-..., etc.) when
# writing CMakeRCCompiler.cmake. EVERY Windows CI path triggers this.
# Semicolon syntax ("zig;rc") also fails — get_filename_component treats
# "rc" as a component arg.
#
# Since we use zig (Clang, not MSVC), the RC resource is never compiled
# (add_windows_version_resource_file guards on MSVC).
# Use BUILD_PREFIX (forward-slash path) in the -C initial-cache
# script. Forward slashes have no escape issues in CMake string literals.
# Two cmake script files:
#
# 1. _cmake_init.cmake: initial-cache file (-C). For CACHE variables only
#    (e.g. RC compiler). Loaded before project().
#
# 2. _cmake_project_include.cmake: project include file
#    (-DCMAKE_PROJECT_INCLUDE=...). Runs as the LAST step of project(),
#    AFTER all language initialization and platform modules.
#    Sets CMAKE_CXX_CREATE_SHARED_LIBRARY as a normal variable in the
#    top-level project scope — guaranteed to override any platform default.
#
#    -D, -C with CACHE FORCE, and CMAKE_USER_MAKE_RULES_OVERRIDE were all tried
#    and failed (CI confirmed) — each gets overridden by later platform module
#    processing; only the project-include approach above survives it.
_cmake_init="${SRC_DIR}/_cmake_init.cmake"
_cmake_project_include="${SRC_DIR}/_cmake_project_include.cmake"
: > "${_cmake_init}"
: > "${_cmake_project_include}"

CMAKE_RC_FLAGS=()
if is_not_unix; then
  _rc_path="${BUILD_PREFIX}/Library/bin/${CONDA_BUILD_ZIG}-rc.exe"
  cat >> "${_cmake_init}" << CMINIT
# RC compiler with forward-slash path — avoids CMake 4.2 backslash escape bug.
set(CMAKE_RC_COMPILER "${_rc_path}" CACHE FILEPATH "RC compiler")
set(CMAKE_RC_COMPILER_WORKS TRUE CACHE BOOL "RC compiler works")
CMINIT
elif [[ -n "${ZIG_RC:-}" ]]; then
  CMAKE_RC_FLAGS=(-DCMAKE_RC_COMPILER="${ZIG_RC}")
fi

ulimit -n 4096 2>/dev/null || true

# CMake's compiler check runs the zig wrapper -> build-arch host zig, which is
# dynamically linked to libc++.so.1 from the zig-libcxx build dep. Put that dir
# on the loader path BEFORE configure (the existing export later only covers build).
if is_linux; then
  export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib/zig-llvm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

cmake "-C${_cmake_init}" \
  -S "${LLVM_SRC}" -B "${LLVM_BUILD}" \
  -DCMAKE_PROJECT_INCLUDE="${_cmake_project_include}" \
  "${CMAKE_CROSS_FLAGS[@]}" \
  "${CMAKE_PLATFORM_FLAGS[@]}" \
  "${CMAKE_RC_FLAGS[@]}" \
  -DHAS_LOGF128=OFF \
  -DLLD_BUILD_TOOLS=OFF \
  "${_CMAKE[@]}" \
  "${_CLANG[@]}" \
  "${_LLVM[@]}" \
  -G Ninja

# === Quick-fail: verify --export-all-symbols in ALL shared library link rules ===
# libLLVM and libclang-cpp each get their own CXX_SHARED_LIBRARY_LINKER rule in
# rules.ninja.  If --export-all-symbols is missing from either, the import lib
# will be 8 KiB instead of 100+ KiB — but we'd only discover that AFTER 2+ hours.
#
# win-arm64: skip this assertion — patch 0004 routes to --def (not --export-all-symbols)
# for aarch64 to avoid the PE/COFF 65535 export-ordinal cap. The .def file is generated
# in Phase 0 below; its presence (not --export-all-symbols) is what matters there.
if is_not_unix && ! { [[ "${ZIG_TRIPLET}" == aarch64-* ]]; }; then
  { set +x; } 2>/dev/null
  echo "=== Quick-fail: verifying --export-all-symbols in ALL shared library rules ==="
  _export_fail=0
  while IFS= read -r _rule_name; do
    # Extract the command line for this rule (next 8 lines after the rule declaration)
    _rule_cmd=$(grep -A8 "^rule ${_rule_name}$" "${_rules_ninja}" 2>/dev/null | grep 'command =' || true)
    echo "  ${_rule_name}:"
    if echo "${_rule_cmd}" | grep -q 'export-all-symbols'; then
      echo "    OK: --export-all-symbols present"
    else
      echo "    FAIL: --export-all-symbols NOT in command line!"
      echo "    command = ${_rule_cmd}"
      _export_fail=1
    fi
  done < <(grep '^rule CXX_SHARED_LIBRARY_LINKER' "${_rules_ninja}" 2>/dev/null | sed 's/^rule //')
  if [[ ${_export_fail} -ne 0 ]]; then
    echo "  FATAL: --export-all-symbols missing from one or more shared library link rules."
    echo "  libclang-cpp.dll.a will be ~8 KiB instead of 100+ KiB."
    echo "  Aborting to avoid wasting 2+ hours on a build that will fail."
    set -x
    exit 1
  fi
  echo "  All shared library rules have --export-all-symbols"
  set -x
elif is_not_unix && [[ "${ZIG_TRIPLET}" == aarch64-* ]]; then
  dbg "win-arm64: skipping --export-all-symbols ninja-rule assertion (using .def file instead)"
fi


echo "=== Building LLVM ==="
# Verify a Windows import lib (.dll.a) actually exports the expected symbols
# after strip_atexit_from_implib() surgery. Without this, a broken import lib
# wastes the remainder of the build before failing with undefined-symbol
# errors much later (e.g. in the zig-zig_impl build).
#
# Args: $1 = implib path, $2 = human-readable lib name (for messages),
#       $3 = minimum total symbol count threshold, $4.. = expected symbol names.
_verify_implib_exports() {
  local _implib="$1"
  local _lib_name="$2"
  local _min_nsyms="$3"
  shift 3
  local _expected_syms=("$@")

  # Use direct pipe (strings | grep -q) to avoid storing large symbol sets in
  # bash variables — MSYS2 echo truncates large variables, causing false failures.
  { set +x; } 2>/dev/null
  local _fail=0
  local _check_sym
  for _check_sym in "${_expected_syms[@]}"; do
    if strings -a "${_implib}" 2>/dev/null | grep -q "${_check_sym}"; then
      echo "    OK: ${_check_sym} found"
    else
      echo "    FAIL: ${_check_sym} NOT found in ${_lib_name}"
      _fail=1
    fi
  done

  # Count total symbol-like strings (approximate, for logging).
  # Exposed as _verify_implib_nsyms (not local) so callers can reference the
  # count in their own diagnostic/success messages, matching prior behavior.
  _verify_implib_nsyms=$(strings -a "${_implib}" 2>/dev/null \
    | grep -cxE '[_A-Za-z?@][_A-Za-z0-9?@$]*' || echo 0)
  local _nsyms="${_verify_implib_nsyms}"
  echo "    Total symbols in ${_lib_name}: ${_nsyms}"
  if [[ "${_nsyms}" -lt "${_min_nsyms}" ]]; then
    echo "    FAIL: expected ${_min_nsyms}+ symbols, got ${_nsyms}"
    _fail=1
  fi
  set -x

  if [[ "${_fail}" -ne 0 ]]; then
    return 1
  fi
  return 0
}

if is_not_unix; then
  # Two-phase build on Windows:
  # Phase 1: Build libLLVM.dll (patch 0004 adds --export-all-symbols for data symbols)
  # Phase 1.5: atexit from dllcrt2.obj leaks into the import lib via --export-all-symbols.
  #   Zig's driver rejects --exclude-symbols. We use ar d to surgically remove the atexit
  #   import entry, preserving the short-import format. This prevents duplicate symbol
  #   errors in Phase 2 when libclang-cpp links against the cleaned import lib.
  # Phase 2: Build everything else (libclang-cpp links against cleaned import lib)

  # Add libc++ DLL location to PATH so build-time executables (llvm-min-tblgen etc.)
  # can find libc++.dll at runtime.  With zig _14's libc++ probe, zig links
  # executables against shared libc++ — but the DLL must be discoverable via PATH.
  #
  # win-arm64 cross-build: the runtimes build (Phase 0) installs an ARM64 libc++.dll
  # to ${LLVM_INSTALL}/bin/ = ${PREFIX}/Library/lib/zig-llvm/bin/. Adding that path
  # first causes NATIVE x86_64 tools (llvm-min-tblgen.exe, llvm-config.exe) to find
  # the ARM64 DLL and fail with STATUS_INVALID_IMAGE_FORMAT (0xc000007b) at launch.
  # Fix: for cross-builds, prepend the BUILD-arch (x86_64) libc++ path first so
  # NATIVE tools load the correct x86_64 libc++.dll from the zig-libcxx build dep.
  if is_cross; then
    _build_libcxx_dir="${BUILD_PREFIX}/Library/lib/zig-llvm"
    export PATH="${_build_libcxx_dir}/lib:${_build_libcxx_dir}/bin:${LLVM_INSTALL}/bin:${LLVM_INSTALL}/lib:${PATH}"
    echo "  Cross: build-arch libc++ (${_build_libcxx_dir}/lib) prepended before target-arch libc++ (${LLVM_INSTALL}/bin)"
    unset _build_libcxx_dir
  else
    export PATH="${LLVM_INSTALL}/bin:${LLVM_INSTALL}/lib:${PATH}"
    echo "  Added ${LLVM_INSTALL}/bin and lib to PATH for runtime DLL discovery"
  fi

  # Phase 1: Build libLLVM DLL only.
  # win-arm64: two-stage pre-link approach to generate libLLVM.def before the dll
  # link runs (PE/COFF 65535 export-ordinal cap workaround via patch 0004 --def flag).
  # Stage 1 builds LLVM static archives; Stage 2 generates libLLVM.def from them;
  # Stage 3 then links libLLVM-20.dll using the .def file.
  # Other Windows targets: single cmake --build --target LLVM as before.
  echo "  Phase 1: Building LLVM shared library..."
  if [[ "${ZIG_TRIPLET}" == aarch64-* ]]; then
    dbg "win-arm64: two-stage build to generate libLLVM.def before dll link"

    # Stage 1: build LLVM static archives WITHOUT the libLLVM dll.
    # Strategy: build a representative set of LLVM* static lib targets that pull in
    # all transitive LLVM* static archives via ninja dependency resolution.
    # These are always present regardless of LLVM_TARGETS_TO_BUILD pruning.
    # Backends are included because our pruned target list is exactly
    # X86;AArch64;ARM;PowerPC;RISCV;SystemZ;WebAssembly for win-arm64 (see
    # _llvm_targets above). Only each backend's top-level CodeGen target is
    # listed explicitly -- ninja transitively builds its AsmParser/Desc/Info/
    # Disassembler/Utils dependencies as real .a files regardless of whether
    # they're separately named here.
    cmake --build "${LLVM_BUILD}" --config Release -- \
      LLVMSupport LLVMCore LLVMMC LLVMAnalysis LLVMTransformUtils LLVMCodeGen \
      LLVMTarget LLVMMCParser LLVMBinaryFormat LLVMBitWriter LLVMBitReader \
      LLVMAArch64CodeGen LLVMAArch64AsmParser LLVMAArch64Desc LLVMAArch64Info LLVMAArch64Utils \
      LLVMX86CodeGen LLVMX86AsmParser LLVMX86Desc LLVMX86Info \
      LLVMWebAssemblyCodeGen LLVMWebAssemblyAsmParser LLVMWebAssemblyDesc LLVMWebAssemblyInfo \
      LLVMARMCodeGen LLVMPowerPCCodeGen LLVMRISCVCodeGen LLVMSystemZCodeGen
    # ninja resolves transitive deps; this populates ${LLVM_BUILD}/lib/*.lib with all
    # LLVM core + 7-target backend statics.

    # Stage 2: generate libLLVM.def from the static archives.
    # === win-arm64: libLLVM.def diagnostics + multi-attempt extraction ===
    _def_out="${LLVM_BUILD}/libLLVM.def"
    _zig_bin="${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe"

    if _debug; then
      echo "=== win-arm64 extract_symbols diagnostics ==="

      echo "--- nm tools available ---"
      if [[ -x "${BUILD_PREFIX}/Library/bin/llvm-nm" ]]; then
        echo "  Library/bin/llvm-nm (Windows path): FOUND"
        "${BUILD_PREFIX}/Library/bin/llvm-nm" --version 2>&1 | head -5
      elif [[ -x "${BUILD_PREFIX}/Library/bin/llvm-nm.exe" ]]; then
        echo "  Library/bin/llvm-nm.exe: FOUND"
        "${BUILD_PREFIX}/Library/bin/llvm-nm.exe" --version 2>&1 | head -5
      elif [[ -x "${BUILD_PREFIX}/bin/llvm-nm" ]]; then
        echo "  bin/llvm-nm (fallback): FOUND"
        "${BUILD_PREFIX}/bin/llvm-nm" --version 2>&1 | head -5
      else
        echo "  host llvm-nm: NOT FOUND in Library/bin or bin"
      fi
      "${_zig_bin}" version 2>&1 | head -3 \
        || echo "  zig: NOT FOUND or errored"

      echo "--- extract_symbols.py --help ---"
      python3 "${LLVM_SRC}/utils/extract_symbols.py" --help 2>&1 | head -40 || true

      echo "--- archive listing (LLVM*.lib + libLLVM*.a) ---"
      shopt -s nullglob
      _archives=( "${LLVM_BUILD}"/lib/LLVM*.lib "${LLVM_BUILD}"/lib/libLLVM*.a )
      echo "  archive count: ${#_archives[@]}"
      ls -la "${_archives[@]}" 2>/dev/null | head -10 || true
      shopt -u nullglob
    fi

    _sample=""
    for _cand in "${LLVM_BUILD}/lib/libLLVMAArch64Info.a" \
                 "${LLVM_BUILD}/lib/libLLVMSupport.a"; do
      if [[ -f "${_cand}" ]]; then _sample="${_cand}"; break; fi
    done

    # Resolve host llvm-nm: Windows installs under Library/bin, not bin.
    if [[ -x "${BUILD_PREFIX}/Library/bin/llvm-nm" ]]; then
      _host_nm="${BUILD_PREFIX}/Library/bin/llvm-nm"
    elif [[ -x "${BUILD_PREFIX}/Library/bin/llvm-nm.exe" ]]; then
      _host_nm="${BUILD_PREFIX}/Library/bin/llvm-nm.exe"
    elif [[ -x "${BUILD_PREFIX}/bin/llvm-nm" ]]; then
      _host_nm="${BUILD_PREFIX}/bin/llvm-nm"
    else
      _host_nm=""
      if _debug; then echo "  WARNING: no llvm-nm found in BUILD_PREFIX"; fi
    fi
    if _debug; then echo "  selected host nm: ${_host_nm}"; fi

    # Resolve host llvm-readobj: same search order as llvm-nm above.
    if [[ -x "${BUILD_PREFIX}/Library/bin/llvm-readobj" ]]; then
      _host_readobj="${BUILD_PREFIX}/Library/bin/llvm-readobj"
    elif [[ -x "${BUILD_PREFIX}/Library/bin/llvm-readobj.exe" ]]; then
      _host_readobj="${BUILD_PREFIX}/Library/bin/llvm-readobj.exe"
    elif [[ -x "${BUILD_PREFIX}/bin/llvm-readobj" ]]; then
      _host_readobj="${BUILD_PREFIX}/bin/llvm-readobj"
    else
      _host_readobj=""
      if _debug; then echo "  WARNING: no llvm-readobj found in BUILD_PREFIX"; fi
    fi
    if _debug; then echo "  selected host readobj: ${_host_readobj}"; fi

    if _debug; then
      echo "--- sample archive symbol probe ---"
      if [[ -n "${_sample}" ]]; then
        echo "  sample: ${_sample}"
        echo "  size: $(stat -c %s "${_sample}" 2>/dev/null || stat -f %z "${_sample}")"
        if [[ -n "${_host_nm}" ]]; then
          echo "  host llvm-nm output (first 10 lines):"
          "${_host_nm}" "${_sample}" 2>&1 | head -10 | sed 's/^/    /' || true
        fi
        echo "  zig nm output (first 10 lines):"
        "${_zig_bin}" nm "${_sample}" 2>&1 | head -10 | sed 's/^/    /' || true
      else
        echo "  no sample archive found"
      fi
    fi

    # Windows-invocable wrapper for `zig nm`. extract_symbols.py calls subprocess
    # with the path directly; on Windows it must be a .bat or .exe.
    _nm_wrapper="${LLVM_BUILD}/zig-nm-wrapper.bat"
    cat > "${_nm_wrapper}" <<EOF
@echo off
"${_zig_bin}" nm %*
EOF

    # Try multiple --nm x --mangling combinations. zig MinGW uses Itanium mangling
    # (not Microsoft); Linux ELF also uses Itanium mangling.
    declare -a _attempts=()
    if [[ -n "${_host_nm}" ]]; then
      _attempts+=( "host-itanium|${_host_nm}|itanium" )
    fi
    if [[ -f "${_nm_wrapper}" ]]; then
      _attempts+=( "zignm-itanium|${_nm_wrapper}|itanium" )
    fi

    # Restrict archive set to libLLVM's actual link inputs (match win-64's
    # --export-all-symbols linker pruning behavior). Falls back to a wide glob
    # if ninja-inputs fails (e.g., target name differs across LLVM versions).
    _real_archives=()
    if command -v ninja >/dev/null 2>&1; then
      while IFS= read -r _arch; do
        [[ -n "${_arch}" && -f "${_arch}" ]] && _real_archives+=( "${_arch}" )
      done < <(ninja -C "${LLVM_BUILD}" -t inputs LLVM 2>/dev/null \
        | grep -E '/(lib)?LLVM[^/]*\.(lib|a)$' \
        | sort -u)
    fi
    if (( ${#_real_archives[@]} == 0 )); then
      echo "[Stage 2] ninja-inputs returned no LLVM archives; falling back to glob" >&2
      shopt -s nullglob
      _real_archives=( "${LLVM_BUILD}"/lib/LLVM*.lib "${LLVM_BUILD}"/lib/libLLVM*.a )
      shopt -u nullglob
    fi
    echo "[Stage 2] Archive count fed to extract_symbols.py: ${#_real_archives[@]}"

    _winner_def=""
    _winner_lines=0
    _winner_label=""
    for _entry in "${_attempts[@]}"; do
      IFS="|" read -r _label _nm _os <<< "${_entry}"
      _cand="${LLVM_BUILD}/libLLVM.def.${_label}"
      _errf="${LLVM_BUILD}/libLLVM.def.${_label}.err"
      echo "--- attempt: ${_label} (--nm=${_nm##*/} --mangling=${_os}) ---"
      _extra_args=()
      if [[ -n "${_host_readobj}" ]]; then
        _extra_args+=(--readobj "${_host_readobj}")
      fi
      python3 "${LLVM_SRC}/utils/extract_symbols.py" \
        --nm "${_nm}" --mangling "${_os}" \
        "${_extra_args[@]}" \
        "${_real_archives[@]}" \
        > "${_cand}" 2> "${_errf}" && _rc=0 || _rc=$?
      _lines=$(wc -l < "${_cand}" 2>/dev/null || echo 0)
      echo "  exit: ${_rc}, def lines: ${_lines}"
      echo "[Stage 2] Attempt '${_label}': .def line count = ${_lines}"
      if [[ -s "${_errf}" ]]; then
        echo "  stderr (first 200 lines):"
        head -200 "${_errf}" | sed 's/^/    /'
      fi
      if (( _lines > _winner_lines )); then
        _winner_def="${_cand}"
        _winner_lines=${_lines}
        _winner_label="${_label}"
      fi
    done

    if [[ -n "${_winner_def}" ]]; then
      if _debug; then echo "=== WINNER: ${_winner_label} with ${_winner_lines} lines ==="; fi
      cp "${_winner_def}" "${_def_out}"
      if _debug; then
        echo "[Stage 2] === .def file head (first 20 lines) ==="
        head -20 "${LLVM_BUILD}/libLLVM.def" 2>/dev/null | sed 's/^/[Stage 2] DEF: /' || echo "[Stage 2] DEF: <empty or unreadable>"
        echo "[Stage 2] === .def file md5 / size ==="
        wc -l "${LLVM_BUILD}/libLLVM.def" 2>/dev/null
        md5sum "${LLVM_BUILD}/libLLVM.def" 2>/dev/null || true
      fi
    else
      if _debug; then echo "=== ALL ATTEMPTS PRODUCED EMPTY .def ==="; fi
    fi

    if [[ ! -s "${_def_out}" ]]; then
      echo "  ERROR: win-arm64: libLLVM.def generation failed across all attempts" >&2
      ls -la "${LLVM_BUILD}/lib/" 2>/dev/null | head -20 >&2
      exit 1
    fi
    dbg "win-arm64: libLLVM.def has $(wc -l < "${_def_out}") lines"

    # Stage 2 post-filter: strip libc++ symbols (Itanium-mangled std::__1).
    # libc++ symbols should not be exported from libLLVM — they are an internal
    # implementation detail. Removing them reduces the export count by ~10-15k
    # symbols to fit the PE/COFF 65535-symbol limit on win-arm64.
    if [[ -s "${_def_out}" ]]; then
      _pre_count=$(wc -l < "${_def_out}")
      sed -i \
        -e '/_ZNSt3__1/d' \
        -e '/_ZNKSt3__1/d' \
        -e '/_ZTVNSt3__1/d' \
        -e '/_ZTINSt3__1/d' \
        -e '/_ZTSNSt3__1/d' \
        "${_def_out}"
      _post_count=$(wc -l < "${_def_out}")
      _delta=$(( _pre_count - _post_count ))
      echo "[Stage 2 filter] libc++ stripped: ${_pre_count} → ${_post_count} (-${_delta})"
      if [[ ${_post_count} -gt 65000 ]]; then
        echo "ERROR: .def still has ${_post_count} symbols (limit ~65535). Need more aggressive filtering." >&2
        echo "  Next options: --exclude '_ZN.*templates' or whitelist only _ZN4llvm/_ZN5clang/_ZN3lld namespaces" >&2
        exit 1
      fi
    else
      echo "WARNING: ${_def_out} empty or missing — Stage 2 extract_symbols.py may have failed" >&2
    fi

    # Stage 3: build the libLLVM dll (patch 0004 uses --def libLLVM.def via the
    # patched cmake conditional; the .def file now exists so the link succeeds).
    cmake --build "${LLVM_BUILD}" --config Release --target LLVM
  else
    cmake --build "${LLVM_BUILD}" --target LLVM -j"${CPU_COUNT}"
  fi

  # Phase 1.5: Remove atexit from import lib via strip_atexit_from_implib().
  # atexit from dllcrt2.obj leaks into import libs via --export-all-symbols.
  # Zig's driver rejects --exclude-symbols, so we surgically remove it here.
  _implib=$(find "${LLVM_BUILD}" \( -name 'libLLVM*.dll.a' -o -name 'LLVM*.dll.a' \) 2>/dev/null | awk 'NR==1')
  _zig_bin="${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe"

  if [[ -n "${_implib}" ]]; then
    echo "  Phase 1.5: Stripping atexit from import lib: ${_implib}"
    if ! strip_atexit_from_implib "${_implib}"; then
      echo "  ERROR: strip_atexit_from_implib failed — aborting build."
      exit 1
    fi
    # Quick-fail: verify libLLVM.dll.a has critical symbols after strip_atexit.
    # Without this, a broken import lib wastes the entire Phase 2 build.
    # Use direct pipe (strings | grep -q) to avoid storing ~8 MB of symbols in a
    # bash variable — MSYS2 echo truncates large variables, causing false failures.
    echo "  Phase 1.5b: Quick-fail verification of libLLVM.dll.a exports..."
    if ! _verify_implib_exports "${_implib}" "libLLVM.dll.a" 5000 ErrorInfoBase LLVMInitialize; then
      echo "  ERROR: libLLVM.dll.a is missing critical symbols!"
      echo "  strip_atexit_from_implib may have discarded members, or --export-all-symbols is missing."
      exit 1
    fi
    echo "  OK: libLLVM.dll.a verified (${_verify_implib_nsyms} symbols, all critical present)"
  else
    echo "  WARNING: import lib not found — skipping Phase 1.5"
  fi

  # Phase 2: Build all remaining targets.
  # --export-all-symbols is in the CMAKE_CXX_CREATE_SHARED_LIBRARY template,
  # so all DLLs (libclang-cpp etc.) export their symbols.
  echo "  Phase 2: Building remaining targets..."
  cmake --build "${LLVM_BUILD}" -j"${CPU_COUNT}"


  # Phase 2.5: Strip atexit from libclang-cpp import lib + verify exports.
  # --export-all-symbols is baked into CMAKE_CXX_CREATE_SHARED_LIBRARY template,
  # which also leaks atexit from dllcrt2.obj — same issue as libLLVM.
  _clang_implib=$(find "${LLVM_BUILD}" \( -name 'libclang-cpp*.dll.a' -o -name 'clang-cpp*.dll.a' \) 2>/dev/null | awk 'NR==1')
  if [[ -n "${_clang_implib}" ]]; then
    echo "  Phase 2.5: Stripping atexit from clang-cpp import lib: ${_clang_implib}"
    if ! strip_atexit_from_implib "${_clang_implib}"; then
      echo "  ERROR: strip_atexit_from_implib failed for clang-cpp — aborting build."
      exit 1
    fi
    # Quick-fail: verify libclang-cpp.dll.a actually exports the symbols zig needs.
    # Without this, a broken import lib wastes 25+ min on zig-zig_impl before failing
    # with "104 undefined symbol" errors (clang::SourceManager::*, etc.).
    #
    # Critical symbols that zig's zig_clang.cpp references directly:
    #   SourceManager  — getSpellingLocSlowCase, getFilename, getSpellingLineNumber
    #   CompilerInstance — zig uses clang as a library
    #   ASTContext       — AST manipulation
    echo "  Phase 2.5b: Quick-fail verification of libclang-cpp.dll.a exports..."
    # Instant size check: a proper import lib is 100s of KiB to MiB.
    # 7.9 KiB means --export-all-symbols didn't work (only a handful of symbols).
    _clang_implib_size=$(stat -c%s "${_clang_implib}" 2>/dev/null || stat -f%z "${_clang_implib}" 2>/dev/null || echo 0)
    echo "    Import lib size: ${_clang_implib_size} bytes ($(( _clang_implib_size / 1024 )) KiB)"
    if [[ "${_clang_implib_size}" -lt 100000 ]]; then
      echo "    FAIL: libclang-cpp.dll.a is only ${_clang_implib_size} bytes!"
      echo "    Expected 100+ KiB — --export-all-symbols not effective for libclang-cpp."
      # Print DLL size for quick diagnosis (large DLL + tiny implib = --out-implib problem)
      _clang_dll_fail=$(find "${LLVM_BUILD}" -name 'libclang-cpp*.dll' -o -name 'clang-cpp*.dll' 2>/dev/null | head -1)
      if [[ -n "${_clang_dll_fail}" ]]; then
        _clang_dll_fail_sz=$(stat -c%s "${_clang_dll_fail}" 2>/dev/null || stat -f%z "${_clang_dll_fail}" 2>/dev/null || echo 0)
        echo "    libclang-cpp.dll size: ${_clang_dll_fail_sz} bytes ($(( _clang_dll_fail_sz / 1048576 )) MiB)"
      else
        echo "    libclang-cpp.dll: NOT FOUND"
      fi
      exit 1
    fi
    # Minimum symbol count — libclang-cpp exports thousands of C++ symbols.
    # If we have < 1000, something went very wrong (visibility, ar d, etc.)
    if ! _verify_implib_exports "${_clang_implib}" "libclang-cpp.dll.a" 1000 SourceManager CompilerInstance ASTContext; then
      echo "  ERROR: libclang-cpp.dll.a is missing critical symbols!"
      echo "  This would cause 104+ undefined symbol errors in zig-zig_impl build."
      # Show DLL size for diagnosis
      _clang_dll_sym=$(find "${LLVM_BUILD}" -name 'libclang-cpp*.dll' -o -name 'clang-cpp*.dll' 2>/dev/null | head -1)
      if [[ -n "${_clang_dll_sym}" ]]; then
        _clang_dll_sym_sz=$(stat -c%s "${_clang_dll_sym}" 2>/dev/null || stat -f%z "${_clang_dll_sym}" 2>/dev/null || echo 0)
        echo "  libclang-cpp.dll size: ${_clang_dll_sym_sz} bytes ($(( _clang_dll_sym_sz / 1048576 )) MiB)"
        _clang_dll_sym_nsyms=$( ("${_zig_bin}" nm "${_clang_dll_sym}" 2>/dev/null || nm "${_clang_dll_sym}" 2>/dev/null) \
          | grep -c ' [TDBCV] ' || echo 0)
        echo "  libclang-cpp.dll exported symbols (nm): ${_clang_dll_sym_nsyms}"
      fi
      echo "  libclang-cpp.dll.a size: ${_clang_implib_size} bytes, symbols: ${_verify_implib_nsyms}"
      echo "  Likely causes:"
      echo "    - -fvisibility=default not reaching clang compilation"
      echo "    - --export-all-symbols not in libclang-cpp link command"
      echo "    - strip_atexit_from_implib discarded members (ar d removed too much)"
      exit 1
    fi
    echo "  OK: libclang-cpp.dll.a verified (${_verify_implib_nsyms} symbols, all critical present)"
  fi
elif is_osx; then
  # Two-phase build on macOS: build libLLVM.dylib first, check symbol exports,
  # then build the rest. Without this, a visibility bug wastes the full 2-hour build
  # only to fail at the very end when libclang-cpp.dylib links against libLLVM.dylib.
  # Same rpath issue as Linux: llvm-min-tblgen needs to find libunwind from LLVM_INSTALL.
  export DYLD_LIBRARY_PATH="${LLVM_INSTALL}/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  echo "  Phase 1: Building LLVM shared library..."
  set +e
  cmake --build "${LLVM_BUILD}" --target LLVM -j"${CPU_COUNT}"
  _phase1_rc=$?
  set -e

  if [[ ${_phase1_rc} -ne 0 ]]; then
    echo "  ERROR: Phase 1 (libLLVM.dylib) build FAILED (rc=${_phase1_rc})."
    echo "  See _cmake_flags.sh for -isysroot/CMAKE_OSX_SYSROOT handling (LDFLAGS is intentionally blank)."
    exit ${_phase1_rc}
  fi

  # Quick-fail: verify key symbols are exported from libLLVM.dylib.
  # If zig cc's visibility handling is broken, we find out here (~50% through build)
  # instead of at the end when libclang-cpp.dylib tries to link.
  _llvm_dylib=$(find "${LLVM_BUILD}" -name 'libLLVM*.dylib' -not -name '*.dSYM' 2>/dev/null | awk 'NR==1')
  if [[ -n "${_llvm_dylib}" ]]; then
    # Check for a known externally-consumed symbol (LLVMInitialize* functions).
    # IMPORTANT: use "grep ... >/dev/null" NOT "grep -q" here.
    # grep -q exits on first match, closing the pipe while nm is still writing
    # 55K+ symbols. Under set -o pipefail, nm's SIGPIPE (exit 141) makes the
    # pipeline fail even though the symbol was found.
    _test_sym="LLVMInitializeAArch64AsmParser"
    if nm -g "${_llvm_dylib}" 2>/dev/null | grep "${_test_sym}" >/dev/null 2>&1; then
      echo "  OK: ${_test_sym} exported from libLLVM.dylib"
    else
      echo "  FAIL: ${_test_sym} NOT exported from libLLVM.dylib"
      echo "  EARLY ABORT: libLLVM.dylib is missing key symbols."
      exit 1
    fi
  else
    echo "  WARNING: libLLVM.dylib not found after Phase 1 — proceeding anyway"
  fi

  echo "  Phase 2: Building remaining targets..."
  cmake --build "${LLVM_BUILD}" -j"${CPU_COUNT}"
else
  # Linux: single-phase build (no known symbol visibility issues with ELF)
  # llvm-min-tblgen links against libunwind.so.1 (from zig-llvm's shared runtimes).
  # LLVM's llvm_setup_rpath() sets BUILD_WITH_INSTALL_RPATH=ON which bypasses
  # CMAKE_BUILD_RPATH. The binary's $ORIGIN/../lib resolves to LLVM_BUILD/lib/
  # but libunwind.so.1 is in LLVM_INSTALL/lib/. LD_LIBRARY_PATH bridges the gap.
  # Cross-compile: build_env's zig-libcxx installs libc++.so.1 at
  # ${BUILD_PREFIX}/lib/zig-llvm/lib/ — needed by host llvm-tblgen.
  # Native build: same path resolves harmlessly to the build_env copy too.
  export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib/zig-llvm/lib:${LLVM_INSTALL}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  set +e
  cmake --build "${LLVM_BUILD}" -j"${CPU_COUNT}"
  _linux_build_rc=$?
  set -e

  if [[ ${_linux_build_rc} -ne 0 ]]; then
    exit ${_linux_build_rc}
  fi
fi

