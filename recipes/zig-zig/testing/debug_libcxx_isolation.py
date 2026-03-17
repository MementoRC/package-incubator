#!/usr/bin/env python3
"""Diagnostic script: macOS "LLVM and Clang have separate copies of libc++" error.

Context
-------
zig-llvm installs its own LLVM/libc++ dylibs in $PREFIX/lib/zig-llvm/lib/.
conda-forge's llvm-tools and libcxx packages install competing copies in $PREFIX/lib/.
zig checks at startup that libLLVM and libclang-cpp both resolve
std::generic_category() to the SAME address.  If two libc++ copies are loaded
the addresses differ and zig refuses to start.

The zig-llvm post-install rewrites all inter-library @rpath references to
@loader_path so dylibs find siblings in $PREFIX/lib/zig-llvm/lib/ instead of
drifting to conda-forge copies.

This script walks every layer of that mechanism and makes any failure obvious.

Usage
-----
    python debug_libcxx_isolation.py            # uses CONDA_PREFIX or PREFIX
    PREFIX=/path/to/conda/env python debug_libcxx_isolation.py
"""

from __future__ import annotations

import ctypes
import glob
import os
import re
import subprocess
import sys
from typing import Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Terminal colour helpers
# ---------------------------------------------------------------------------

_IS_TTY = sys.stdout.isatty()


def _colour(code: str, text: str) -> str:
    if not _IS_TTY:
        return text
    return f"\033[{code}m{text}\033[0m"


def green(t: str) -> str:
    return _colour("32", t)


def red(t: str) -> str:
    return _colour("31", t)


def yellow(t: str) -> str:
    return _colour("33", t)


def bold(t: str) -> str:
    return _colour("1", t)


def PASS(msg: str) -> str:
    return green(f"PASS") + f"  {msg}"


def FAIL(msg: str) -> str:
    return red(f"FAIL") + f"  {msg}"


def WARN(msg: str) -> str:
    return yellow(f"WARN") + f"  {msg}"


def INFO(msg: str) -> str:
    return f"INFO  {msg}"


def section(title: str) -> None:
    width = 72
    bar = "=" * width
    print(f"\n{bold(bar)}")
    print(bold(f"=== {title}"))
    print(bold(bar))


def subsection(title: str) -> None:
    print(f"\n--- {title} ---")


# ---------------------------------------------------------------------------
# Low-level otool / nm helpers
# ---------------------------------------------------------------------------

def run(cmd: List[str], timeout: int = 30) -> str:
    """Run a command, return stdout; never raises."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout
    except (FileNotFoundError, subprocess.TimeoutExpired, PermissionError):
        return ""


def otool_L(path: str) -> List[str]:
    """Return list of LC_LOAD_DYLIB entries (raw strings, not basename)."""
    out = run(["otool", "-L", path])
    lines = out.splitlines()
    if len(lines) < 2:
        return []
    result = []
    for line in lines[1:]:
        m = re.match(r"\s+(\S+)", line)
        if m:
            result.append(m.group(1))
    return result


def otool_D(path: str) -> str:
    """Return install name (LC_ID_DYLIB) or empty string."""
    out = run(["otool", "-D", path])
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    # Lines: first is the file header, second (if present) is the install name
    # When the file IS the dylib the first line ends in ":" and second is the id.
    for line in lines:
        if line.endswith(":"):
            continue
        return line
    return ""


def otool_rpaths(path: str) -> List[str]:
    """Parse LC_RPATH entries from otool -l output."""
    out = run(["otool", "-l", path])
    rpaths: List[str] = []
    in_rpath = False
    for line in out.splitlines():
        line = line.strip()
        if line == "cmd LC_RPATH":
            in_rpath = True
        elif in_rpath and line.startswith("path "):
            # "path @loader_path/../lib (offset 12)"
            m = re.match(r"path\s+(\S+)", line)
            if m:
                rpaths.append(m.group(1))
            in_rpath = False
    return rpaths


def nm_symbol_type(lib: str, symbol_fragment: str) -> Optional[str]:
    """Return nm symbol type letter for first match of symbol_fragment, or None."""
    out = run(["nm", "-a", lib])
    for line in out.splitlines():
        if symbol_fragment in line:
            parts = line.split()
            if len(parts) >= 2:
                return parts[-2]  # type letter
    return None


# ---------------------------------------------------------------------------
# Library discovery helpers
# ---------------------------------------------------------------------------

def find_dylibs(directory: str, pattern: str) -> List[str]:
    """Glob for dylibs; return real files only (no broken symlinks)."""
    matches = sorted(glob.glob(os.path.join(directory, pattern)))
    return [p for p in matches if os.path.isfile(p)]


def find_zig_binary(prefix: str) -> Optional[str]:
    """Find the zig binary: $PREFIX/bin/<triplet>-zig."""
    candidates = glob.glob(os.path.join(prefix, "bin", "*-zig"))
    # Prefer non-symlink real files, else any file
    for p in candidates:
        if os.path.isfile(p) and not os.path.islink(p):
            return p
    for p in candidates:
        if os.path.isfile(p):
            return p
    return None


def is_llvm_or_cxx_ref(dep: str) -> bool:
    """Return True if dep looks like an LLVM/clang/libc++ library reference."""
    base = os.path.basename(dep)
    return bool(
        re.match(r"libLLVM", base)
        or re.match(r"libclang", base)
        or re.match(r"libc\+\+", base)
        or re.match(r"libunwind", base)
        or re.match(r"libc\+\+abi", base)
    )


# ---------------------------------------------------------------------------
# dyld @rpath resolution simulation
# ---------------------------------------------------------------------------

def resolve_rpath_dep(
    dep: str,
    rpaths: List[str],
    loader_path: str,
    executable_path: Optional[str] = None,
) -> Optional[str]:
    """Simulate dyld @rpath resolution: try each rpath in order.

    Returns the first existing file path, or None if nothing resolves.
    """
    if not dep.startswith("@rpath/"):
        return None
    dep_name = dep[len("@rpath/"):]
    for rp in rpaths:
        # Expand @loader_path
        if rp.startswith("@loader_path"):
            expanded = rp.replace("@loader_path", loader_path, 1)
        elif rp.startswith("@executable_path") and executable_path:
            expanded = rp.replace("@executable_path", os.path.dirname(executable_path), 1)
        else:
            expanded = rp
        candidate = os.path.normpath(os.path.join(expanded, dep_name))
        if os.path.isfile(candidate):
            return candidate
    return None


# ---------------------------------------------------------------------------
# Section implementations
# ---------------------------------------------------------------------------

def section_environment(prefix: str) -> None:
    section("1. Environment")
    env_vars = [
        "CONDA_PREFIX",
        "PREFIX",
        "DYLD_LIBRARY_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_INSERT_LIBRARIES",
        "PATH",
    ]
    for var in env_vars:
        val = os.environ.get(var, "")
        if var == "PATH":
            # Show each entry on its own line for readability
            print(f"  {var}:")
            for entry in val.split(":"):
                print(f"    {entry}")
        else:
            print(f"  {var}: {val or '(not set)'}")
    print(f"\n  PREFIX used: {prefix}")


def section_library_inventory(
    prefix: str,
    zigllvm_libdir: str,
    cf_libdir: str,
) -> Dict[str, List[str]]:
    """Find all relevant dylibs; return dict of category -> [paths]."""
    section("2. Library Inventory")

    categories = {
        "zig-llvm/libLLVM": find_dylibs(zigllvm_libdir, "libLLVM*.dylib"),
        "zig-llvm/libclang-cpp": find_dylibs(zigllvm_libdir, "libclang-cpp*.dylib"),
        "zig-llvm/libclang (other)": find_dylibs(zigllvm_libdir, "libclang[^-]*.dylib"),
        "zig-llvm/libc++": find_dylibs(zigllvm_libdir, "libc++*.dylib"),
        "zig-llvm/libunwind": find_dylibs(zigllvm_libdir, "libunwind*.dylib"),
        "conda-forge/libLLVM": find_dylibs(cf_libdir, "libLLVM*.dylib"),
        "conda-forge/libclang-cpp": find_dylibs(cf_libdir, "libclang-cpp*.dylib"),
        "conda-forge/libc++": find_dylibs(cf_libdir, "libc++*.dylib"),
        "conda-forge/libunwind": find_dylibs(cf_libdir, "libunwind*.dylib"),
    }

    for cat, libs in categories.items():
        subsection(cat)
        if not libs:
            print(f"  (none found)")
        for lib in libs:
            sym_marker = " [symlink]" if os.path.islink(lib) else ""
            print(f"  {lib}{sym_marker}")

    # Flag competing copies
    subsection("Competing copy summary")
    cf_libllvm = categories["conda-forge/libLLVM"]
    cf_libclang = categories["conda-forge/libclang-cpp"]
    cf_libcxx = categories["conda-forge/libc++"]
    zl_libllvm = categories["zig-llvm/libLLVM"]
    zl_libclang = categories["zig-llvm/libclang-cpp"]
    zl_libcxx = categories["zig-llvm/libc++"]

    for label, zl, cf in [
        ("libLLVM", zl_libllvm, cf_libllvm),
        ("libclang-cpp", zl_libclang, cf_libclang),
        ("libc++", zl_libcxx, cf_libcxx),
    ]:
        if zl and cf:
            print(FAIL(f"COMPETING {label}: zig-llvm AND conda-forge both present"))
        elif zl and not cf:
            print(PASS(f"{label}: only in zig-llvm/lib/ (no conda-forge copy)"))
        elif cf and not zl:
            print(WARN(f"{label}: only in conda-forge $PREFIX/lib/ (no zig-llvm copy)"))
        else:
            print(INFO(f"{label}: not found in either location"))

    return categories


def section_install_names(zigllvm_libdir: str, categories: Dict[str, List[str]]) -> None:
    section("3. Install Names (LC_ID_DYLIB)")
    print("  Expected: @loader_path/<basename.dylib>")
    print("  Bad:      @rpath/..., absolute path, or bare name\n")

    all_zl_libs = (
        categories["zig-llvm/libLLVM"]
        + categories["zig-llvm/libclang-cpp"]
        + categories["zig-llvm/libclang (other)"]
        + categories["zig-llvm/libc++"]
        + categories["zig-llvm/libunwind"]
    )

    for lib in all_zl_libs:
        name = os.path.basename(lib)
        install_name = otool_D(lib)
        expected = f"@loader_path/{name}"
        if install_name == expected:
            print(PASS(f"{name}: {install_name}"))
        elif install_name.startswith("@loader_path/"):
            print(WARN(f"{name}: {install_name}  (loader_path but different basename?)"))
        elif install_name.startswith("@rpath/"):
            print(FAIL(f"{name}: {install_name}  (@rpath not rewritten — post-install may not have run)"))
        elif install_name.startswith("/"):
            print(FAIL(f"{name}: {install_name}  (absolute path — dyld won't find on other machines)"))
        elif not install_name:
            print(WARN(f"{name}: (no install name — not a dylib?)"))
        else:
            print(WARN(f"{name}: {install_name}  (unexpected format)"))


def section_load_dependencies(
    zigllvm_libdir: str,
    categories: Dict[str, List[str]],
) -> Dict[str, List[str]]:
    """Show LC_LOAD_DYLIB for each zig-llvm dylib; return dict of lib -> deps."""
    section("4. Load Dependencies (LC_LOAD_DYLIB)")
    print("  Good: @loader_path/<name> for LLVM/clang/libc++ siblings")
    print("  Bad:  @rpath/<name> for LLVM/clang/libc++ (could resolve to conda-forge)")
    print("  Bad:  absolute path outside zig-llvm/lib/\n")

    all_zl_libs = (
        categories["zig-llvm/libLLVM"]
        + categories["zig-llvm/libclang-cpp"]
        + categories["zig-llvm/libclang (other)"]
        + categories["zig-llvm/libc++"]
        + categories["zig-llvm/libunwind"]
    )

    lib_deps: Dict[str, List[str]] = {}

    for lib in all_zl_libs:
        name = os.path.basename(lib)
        deps = otool_L(lib)
        lib_deps[lib] = deps
        subsection(name)
        for dep in deps:
            base = os.path.basename(dep)
            if dep.startswith("@loader_path/"):
                if is_llvm_or_cxx_ref(dep):
                    print(PASS(f"  {dep}"))
                else:
                    print(INFO(f"  {dep}"))
            elif dep.startswith("@rpath/"):
                if is_llvm_or_cxx_ref(dep):
                    print(FAIL(f"  {dep}  <- @rpath for LLVM/libc++ is DANGEROUS"))
                else:
                    print(WARN(f"  {dep}  (non-critical @rpath)"))
            elif dep.startswith("@executable_path/"):
                print(WARN(f"  {dep}  (@executable_path in a dylib?)"))
            elif dep.startswith("/"):
                if dep.startswith(zigllvm_libdir):
                    print(WARN(f"  {dep}  (absolute path inside zig-llvm — fragile but OK)"))
                elif is_llvm_or_cxx_ref(dep):
                    print(FAIL(f"  {dep}  (absolute path to external LLVM/libc++ — DANGEROUS)"))
                else:
                    # System frameworks / libSystem are fine
                    print(INFO(f"  {dep}"))
            else:
                print(INFO(f"  {dep}"))

    return lib_deps


def section_rpaths(
    prefix: str,
    zigllvm_libdir: str,
    cf_libdir: str,
    zig_binary: Optional[str],
    categories: Dict[str, List[str]],
) -> Dict[str, List[str]]:
    """Show LC_RPATH entries; return dict of path -> rpaths."""
    section("5. RPATH Entries (LC_RPATH)")
    print("  Zig binary should have: @loader_path/../lib/zig-llvm/lib  AND  @loader_path/../lib")
    print("  zig-llvm dylibs: ideally no rpaths (they use @loader_path directly)")
    print("  Dangerous rpath: one that resolves to $PREFIX/lib/ for LLVM/libc++ names\n")

    targets: List[Tuple[str, str]] = []
    if zig_binary:
        targets.append(("zig binary", zig_binary))

    all_zl_libs = (
        categories["zig-llvm/libLLVM"]
        + categories["zig-llvm/libclang-cpp"]
        + categories["zig-llvm/libclang (other)"]
        + categories["zig-llvm/libc++"]
        + categories["zig-llvm/libunwind"]
    )
    for lib in all_zl_libs:
        targets.append((os.path.basename(lib), lib))

    path_rpaths: Dict[str, List[str]] = {}

    for label, path in targets:
        rpaths = otool_rpaths(path)
        path_rpaths[path] = rpaths
        subsection(label)
        if not rpaths:
            print(f"  (no LC_RPATH entries)")
            continue
        for rp in rpaths:
            # Expand @loader_path relative to the binary/dylib location
            loader_path = os.path.dirname(path)
            if rp.startswith("@loader_path"):
                expanded = rp.replace("@loader_path", loader_path, 1)
            else:
                expanded = rp
            expanded_norm = os.path.normpath(expanded)

            # Is this rpath the zig-llvm libdir? Good for zig binary.
            if expanded_norm == os.path.normpath(zigllvm_libdir):
                print(PASS(f"  {rp}  -> {expanded_norm}  (zig-llvm lib dir)"))
            # Is it $PREFIX/lib? Warn if dylibs from zig-llvm also have this
            elif expanded_norm == os.path.normpath(cf_libdir):
                if label == "zig binary":
                    print(WARN(f"  {rp}  -> {expanded_norm}  (conda-forge lib dir — zig binary needs this for non-LLVM libs)"))
                else:
                    print(FAIL(f"  {rp}  -> {expanded_norm}  (zig-llvm dylib rpath reaches conda-forge $PREFIX/lib/ — DANGEROUS)"))
            elif expanded_norm.startswith(os.path.normpath(cf_libdir)):
                print(WARN(f"  {rp}  -> {expanded_norm}  (inside conda-forge lib tree)"))
            elif expanded_norm.startswith(os.path.normpath(zigllvm_libdir)):
                print(PASS(f"  {rp}  -> {expanded_norm}  (inside zig-llvm lib tree)"))
            else:
                print(INFO(f"  {rp}  -> {expanded_norm}"))

    return path_rpaths


def section_rpath_resolution(
    prefix: str,
    zigllvm_libdir: str,
    cf_libdir: str,
    zig_binary: Optional[str],
    categories: Dict[str, List[str]],
    lib_deps: Dict[str, List[str]],
    path_rpaths: Dict[str, List[str]],
) -> None:
    """Simulate dyld @rpath resolution for all @rpath deps in zig-llvm dylibs."""
    section("6. dyld @rpath Resolution Simulation")
    print("  For each @rpath dependency, show which file dyld would actually load.")
    print("  KEY: a resolved path inside conda-forge $PREFIX/lib/ is the ROOT CAUSE.\n")

    all_zl_libs = (
        categories["zig-llvm/libLLVM"]
        + categories["zig-llvm/libclang-cpp"]
        + categories["zig-llvm/libclang (other)"]
        + categories["zig-llvm/libc++"]
        + categories["zig-llvm/libunwind"]
    )

    targets = []
    if zig_binary:
        targets.append(("zig binary", zig_binary))
    for lib in all_zl_libs:
        targets.append((os.path.basename(lib), lib))

    any_bad = False

    for label, path in targets:
        deps = lib_deps.get(path, otool_L(path))
        rpaths = path_rpaths.get(path, otool_rpaths(path))
        rpath_deps = [d for d in deps if d.startswith("@rpath/")]
        if not rpath_deps:
            continue

        subsection(label)
        loader_path = os.path.dirname(path)

        for dep in rpath_deps:
            resolved = resolve_rpath_dep(dep, rpaths, loader_path,
                                         executable_path=zig_binary)
            if resolved is None:
                print(WARN(f"  {dep}  -> UNRESOLVED (not found via any rpath)"))
            else:
                resolved_norm = os.path.normpath(resolved)
                zigllvm_norm = os.path.normpath(zigllvm_libdir)
                cf_norm = os.path.normpath(cf_libdir)
                if resolved_norm.startswith(zigllvm_norm):
                    if is_llvm_or_cxx_ref(dep):
                        print(PASS(f"  {dep}  -> {resolved}"))
                    else:
                        print(INFO(f"  {dep}  -> {resolved}"))
                elif resolved_norm.startswith(cf_norm):
                    if is_llvm_or_cxx_ref(dep):
                        print(FAIL(f"  {dep}  -> {resolved}  *** RESOLVES TO CONDA-FORGE ***"))
                        any_bad = True
                    else:
                        print(WARN(f"  {dep}  -> {resolved}  (conda-forge, non-LLVM)"))
                else:
                    print(INFO(f"  {dep}  -> {resolved}"))

    if not any_bad:
        print(f"\n{PASS('No @rpath LLVM/libc++ deps resolve to conda-forge copies.')}")
    else:
        print(f"\n{FAIL('One or more @rpath deps resolve to conda-forge copies — this IS the libc++ isolation bug.')}")


def section_competing_library_check(
    zigllvm_libdir: str,
    cf_libdir: str,
    categories: Dict[str, List[str]],
    lib_deps: Dict[str, List[str]],
    path_rpaths: Dict[str, List[str]],
) -> None:
    """Check if any rpath combination would pull in conda-forge libc++."""
    section("7. Competing libc++ Reachability Check")
    print("  Would ANY rpath in ANY zig-llvm dylib resolve @rpath/libc++.1.dylib")
    print("  to the conda-forge copy in $PREFIX/lib/?  (That triggers the zig error.)\n")

    cf_libcxx_paths = categories["conda-forge/libc++"]
    if not cf_libcxx_paths:
        print(PASS("No conda-forge libc++ in $PREFIX/lib/ — no competing copy to worry about."))
        return

    print(f"  conda-forge libc++ found: {cf_libcxx_paths}\n")

    # Build set of conda-forge libc++ basenames
    cf_libcxx_names = {os.path.basename(p) for p in cf_libcxx_paths}

    all_zl_libs = (
        categories["zig-llvm/libLLVM"]
        + categories["zig-llvm/libclang-cpp"]
        + categories["zig-llvm/libclang (other)"]
        + categories["zig-llvm/libc++"]
        + categories["zig-llvm/libunwind"]
    )

    for lib in all_zl_libs:
        name = os.path.basename(lib)
        rpaths = path_rpaths.get(lib, otool_rpaths(lib))
        loader_path = os.path.dirname(lib)

        for cf_name in cf_libcxx_names:
            dep_ref = f"@rpath/{cf_name}"
            resolved = resolve_rpath_dep(dep_ref, rpaths, loader_path)
            if resolved:
                resolved_norm = os.path.normpath(resolved)
                if any(os.path.normpath(cf) == resolved_norm for cf in cf_libcxx_paths):
                    print(FAIL(
                        f"  {name}: rpath + '{dep_ref}' -> {resolved}"
                        f"  *** would load conda-forge libc++ ***"
                    ))
                else:
                    print(PASS(f"  {name}: '{dep_ref}' resolves to {resolved} (not conda-forge)"))
            # If unresolved it means the @rpath/libc++.1.dylib dep doesn't exist
            # in any of this dylib's rpaths, so it won't be pulled in that way.

    print()
    print("  Note: the above only checks explicit @rpath deps.  If a zig-llvm dylib")
    print("  already has its libc++ dep rewritten to @loader_path the @rpath check is")
    print("  moot.  See section 4 (load dependencies) for the definitive list.")


def section_symbol_check(zigllvm_libdir: str, categories: Dict[str, List[str]]) -> None:
    """Check generic_category symbol binding in libLLVM and libclang-cpp."""
    section("8. Symbol Binding: generic_category")
    print("  libLLVM and libclang-cpp should NOT have a local (lowercase 't') copy.")
    print("  'U' (undefined) or 'T' (global) means they delegate to a shared libc++.\n")

    SYMBOL = "generic_category"
    MANGLINGS = [
        "_ZNSt3__116generic_categoryEv",
        "_ZNSt3__120__generic_categoryEv",
        "_ZSt16generic_categoryv",
    ]

    libs_of_interest = (
        [("libLLVM", p) for p in categories["zig-llvm/libLLVM"]]
        + [("libclang-cpp", p) for p in categories["zig-llvm/libclang-cpp"]]
        + [("libc++ (zig-llvm)", p) for p in categories["zig-llvm/libc++"]]
    )

    for label, lib in libs_of_interest:
        name = os.path.basename(lib)
        subsection(f"{name}")
        found_any = False
        for mangled in MANGLINGS:
            sym_type = nm_symbol_type(lib, mangled)
            if sym_type is None:
                continue
            found_any = True
            if sym_type == "t":
                print(FAIL(
                    f"  {mangled}: LOCAL 't' — static libc++ merged in."
                    f"  Zig will see different addresses for libLLVM vs libclang-cpp!"
                ))
            elif sym_type == "T":
                print(WARN(
                    f"  {mangled}: GLOBAL DEFINED 'T' — libc++ code present but exported."
                    f"  May still cause address mismatch if two T-exports exist."
                ))
            elif sym_type == "U":
                print(PASS(f"  {mangled}: UNDEFINED 'U' — delegates to shared libc++ (good)"))
            elif sym_type == "u":
                print(PASS(f"  {mangled}: weak undefined 'u' — delegates to shared libc++ (good)"))
            elif sym_type in ("W", "w"):
                print(WARN(f"  {mangled}: weak defined '{sym_type}' — may be interposed"))
            else:
                print(INFO(f"  {mangled}: type '{sym_type}'"))

        if not found_any:
            # Try a simple substring search without demangling
            sym_type = nm_symbol_type(lib, SYMBOL)
            if sym_type:
                print(INFO(f"  generic_category (substring): type '{sym_type}'"))
            else:
                print(WARN(f"  generic_category: not found in symbol table"))


def section_runtime_check(
    zigllvm_libdir: str,
    categories: Dict[str, List[str]],
) -> bool:
    """dlopen libLLVM and libclang-cpp, compare generic_category addresses.

    Returns True if the runtime check passes (same address or libraries load OK).
    """
    section("9. Runtime Symbol Address Check (ctypes dlopen)")
    print("  This reproduces exactly what zig does at startup.")
    print("  Both libLLVM and libclang-cpp must export generic_category at the SAME address.")
    print("  Different addresses = separate libc++ copies = zig refuses to start.\n")

    libllvm_candidates = categories["zig-llvm/libLLVM"]
    libclang_candidates = categories["zig-llvm/libclang-cpp"]

    # Prefer non-symlink real files
    def pick(candidates: List[str]) -> Optional[str]:
        for c in candidates:
            if not os.path.islink(c):
                return c
        return candidates[0] if candidates else None

    libllvm = pick(libllvm_candidates)
    libclang = pick(libclang_candidates)

    if not libllvm or not libclang:
        print(WARN("  Cannot run: libLLVM or libclang-cpp not found in zig-llvm/lib/"))
        return False

    print(f"  libLLVM:  {libllvm}")
    print(f"  libclang: {libclang}")
    print()

    MANGLINGS = [
        "_ZNSt3__116generic_categoryEv",
        "_ZNSt3__120__generic_categoryEv",
        "_ZSt16generic_categoryv",
    ]

    dlopen_script = f"""\
import ctypes
import sys

libdir = {zigllvm_libdir!r}
libllvm_path = {libllvm!r}
libclang_path = {libclang!r}

try:
    llvm = ctypes.CDLL(libllvm_path, mode=ctypes.RTLD_GLOBAL)
    clang = ctypes.CDLL(libclang_path, mode=ctypes.RTLD_GLOBAL)
except OSError as e:
    print(f"  dlopen FAILED: {{e}}")
    sys.exit(2)

MANGLINGS = {MANGLINGS!r}
for mangled in MANGLINGS:
    try:
        a = ctypes.cast(ctypes.c_void_p.in_dll(llvm,  mangled), ctypes.c_void_p).value
        b = ctypes.cast(ctypes.c_void_p.in_dll(clang, mangled), ctypes.c_void_p).value
    except (ValueError, AttributeError):
        continue
    print(f"  Symbol  : {{mangled}}")
    print(f"  libLLVM : {{hex(a) if a else 'NULL'}}")
    print(f"  libclang: {{hex(b) if b else 'NULL'}}")
    if a and b and a == b:
        print("  RESULT  : SAME address -> single shared libc++ copy -> zig will pass")
        sys.exit(0)
    else:
        print("  RESULT  : DIFFERENT addresses -> separate libc++ copies -> zig WILL FAIL")
        sys.exit(1)

print("  WARNING: generic_category not found via any mangling; falling back to LLVMGetVersion")
try:
    llvm.LLVMGetVersion.restype = None
    ma, mi, pa = ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint()
    llvm.LLVMGetVersion(ctypes.byref(ma), ctypes.byref(mi), ctypes.byref(pa))
    print(f"  LLVMGetVersion: {{ma.value}}.{{mi.value}}.{{pa.value}} (libraries load OK)")
    sys.exit(0)
except Exception as e:
    print(f"  LLVMGetVersion failed: {{e}}")
    sys.exit(2)
"""
    env = os.environ.copy()
    old_dyld = env.get("DYLD_LIBRARY_PATH", "")
    env["DYLD_LIBRARY_PATH"] = zigllvm_libdir + (":" + old_dyld if old_dyld else "")

    try:
        r = subprocess.run(
            [sys.executable, "-c", dlopen_script],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if r.stdout.strip():
            print(r.stdout.rstrip())
        if r.stderr.strip():
            print("  stderr:", r.stderr.strip())

        if r.returncode == 0:
            print(f"\n{PASS('Runtime check passed: shared libc++ confirmed.')}")
            return True
        elif r.returncode == 1:
            print(f"\n{FAIL('Runtime check FAILED: separate libc++ copies detected.')}")
            return False
        else:
            print(f"\n{WARN('Runtime check inconclusive (dlopen/dlsym failed).')}")
            return False
    except Exception as e:
        print(WARN(f"  subprocess failed: {e}"))
        return False


def section_dyld_print_libraries(
    zigllvm_libdir: str,
    categories: Dict[str, List[str]],
) -> None:
    """dlopen with DYLD_PRINT_LIBRARIES=1 to show what dyld actually loads."""
    section("10. DYLD_PRINT_LIBRARIES Simulation")
    print("  Runs dlopen(libLLVM) + dlopen(libclang-cpp) with DYLD_PRINT_LIBRARIES=1.")
    print("  stderr will show every dylib dyld loads and from where.")
    print("  Look for any libc++ or LLVM dylib loaded from $PREFIX/lib/ (bad).\n")

    libllvm_candidates = categories["zig-llvm/libLLVM"]
    libclang_candidates = categories["zig-llvm/libclang-cpp"]

    def pick(candidates: List[str]) -> Optional[str]:
        for c in candidates:
            if not os.path.islink(c):
                return c
        return candidates[0] if candidates else None

    libllvm = pick(libllvm_candidates)
    libclang = pick(libclang_candidates)

    if not libllvm or not libclang:
        print(WARN("  Cannot run: missing libLLVM or libclang-cpp"))
        return

    dlopen_script = f"""\
import ctypes, sys
try:
    ctypes.CDLL({libllvm!r}, mode=ctypes.RTLD_GLOBAL)
    ctypes.CDLL({libclang!r}, mode=ctypes.RTLD_GLOBAL)
    print("dlopen OK")
except OSError as e:
    print(f"dlopen FAILED: {{e}}")
    sys.exit(1)
"""
    env = os.environ.copy()
    old_dyld = env.get("DYLD_LIBRARY_PATH", "")
    env["DYLD_LIBRARY_PATH"] = zigllvm_libdir + (":" + old_dyld if old_dyld else "")
    env["DYLD_PRINT_LIBRARIES"] = "1"

    try:
        r = subprocess.run(
            [sys.executable, "-c", dlopen_script],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except Exception as e:
        print(WARN(f"  subprocess failed: {e}"))
        return

    print("  stdout:", r.stdout.strip() or "(empty)")
    print()
    print("  DYLD_PRINT_LIBRARIES output (stderr):")

    # Parse the library load lines.  Format:
    #   dyld[PID]: <action>: <path>
    # or on older dyld:
    #   dyld: loaded: <path>
    prefix_lib_norm = None
    zigllvm_norm = None

    prefix = os.environ.get("CONDA_PREFIX", os.environ.get("PREFIX", ""))
    if prefix:
        prefix_lib_norm = os.path.normpath(os.path.join(prefix, "lib"))
        zigllvm_norm = os.path.normpath(zigllvm_libdir)

    for line in r.stderr.splitlines():
        if not line.strip():
            continue
        # Highlight lines that load from $PREFIX/lib (not zig-llvm sub-dir)
        # Extract path from various dyld message formats
        m = re.search(r"(?:loaded|loading|)<([^>]+)>|dyld\[\d+\]:.*?:\s+(\S+\.dylib)", line)
        lib_path = None
        if m:
            lib_path = m.group(1) or m.group(2)
        else:
            # Try plain path at end of line
            parts = line.split()
            if parts and parts[-1].endswith(".dylib"):
                lib_path = parts[-1]

        if lib_path and prefix_lib_norm and zigllvm_norm:
            norm = os.path.normpath(lib_path)
            if norm.startswith(zigllvm_norm):
                print(PASS(f"    {line}"))
            elif norm.startswith(prefix_lib_norm) and is_llvm_or_cxx_ref(lib_path):
                print(FAIL(f"    {line}  *** LOADED FROM CONDA-FORGE PREFIX/lib/ ***"))
            else:
                print(f"    {line}")
        else:
            print(f"    {line}")


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def section_summary(
    prefix: str,
    zigllvm_libdir: str,
    cf_libdir: str,
    zig_binary: Optional[str],
    categories: Dict[str, List[str]],
    lib_deps: Dict[str, List[str]],
    path_rpaths: Dict[str, List[str]],
    runtime_passed: bool,
) -> int:
    """Print final PASS/FAIL summary.  Returns exit code."""
    section("11. Summary")

    issues: List[str] = []
    warnings: List[str] = []
    hints: List[str] = []

    # Check for competing conda-forge copies.
    # When runtime_passed, competing copies are expected (c-compiler/lld deps
    # install conda-forge LLVM into $PREFIX/lib/) but harmless because
    # @loader_path isolation ensures zig loads from zig-llvm.
    for label, zl_key, cf_key in [
        ("libLLVM", "zig-llvm/libLLVM", "conda-forge/libLLVM"),
        ("libclang-cpp", "zig-llvm/libclang-cpp", "conda-forge/libclang-cpp"),
        ("libc++", "zig-llvm/libc++", "conda-forge/libc++"),
    ]:
        if categories[zl_key] and categories[cf_key]:
            msg = f"Competing {label}: zig-llvm copy AND conda-forge copy in $PREFIX/lib/"
            hint = (
                f"  -> If llvm-tools or libcxx is listed as a run dependency of zig-zig, "
                f"that installs {label} into $PREFIX/lib/. Remove it or ensure the "
                f"post-install rpath rewrite ran correctly."
            )
            if runtime_passed:
                warnings.append(msg)
            else:
                issues.append(msg)
                hints.append(hint)

    # Check install names
    all_zl = (
        categories["zig-llvm/libLLVM"]
        + categories["zig-llvm/libclang-cpp"]
        + categories["zig-llvm/libclang (other)"]
        + categories["zig-llvm/libc++"]
        + categories["zig-llvm/libunwind"]
    )
    bad_install_names = []
    for lib in all_zl:
        iname = otool_D(lib)
        if iname and not iname.startswith("@loader_path/"):
            bad_install_names.append(f"{os.path.basename(lib)}: {iname}")
    if bad_install_names:
        issues.append("Some zig-llvm dylibs have non-@loader_path install names:")
        for b in bad_install_names:
            issues.append(f"  {b}")
        hints.append(
            "  -> The zig-llvm post-install.sh (Step 1: install_name_tool -id) did not run "
            "or did not process all dylibs.  Re-run the post-install script."
        )

    # Check for @rpath LLVM/libc++ load commands
    bad_rpath_deps = []
    for lib, deps in lib_deps.items():
        for dep in deps:
            if dep.startswith("@rpath/") and is_llvm_or_cxx_ref(dep):
                bad_rpath_deps.append(f"{os.path.basename(lib)}: {dep}")
    if bad_rpath_deps:
        issues.append("Some zig-llvm dylibs still have @rpath LLVM/libc++ dependencies:")
        for b in bad_rpath_deps:
            issues.append(f"  {b}")
        hints.append(
            "  -> The zig-llvm post-install.sh (Step 2: install_name_tool -change) did not "
            "run or did not process all @rpath entries.  Re-run the post-install script."
        )

    # Check zig binary rpaths — but only if LLVM deps use @rpath/.
    # If all LLVM deps use @loader_path/ directly, rpaths are unnecessary
    # (and rattler-build strips them anyway).
    if zig_binary:
        zig_deps = lib_deps.get(zig_binary, otool_L(zig_binary))
        llvm_deps_use_rpath = any(
            d.startswith("@rpath/") and is_llvm_or_cxx_ref(d) for d in zig_deps
        )
        llvm_deps_use_loader_path = any(
            d.startswith("@loader_path/") and is_llvm_or_cxx_ref(d) for d in zig_deps
        )

        if llvm_deps_use_rpath:
            # @rpath refs need rpaths to resolve
            zig_rpaths = path_rpaths.get(zig_binary, otool_rpaths(zig_binary))
            expected_zigllvm_rp = "@loader_path/../lib/zig-llvm/lib"
            expected_lib_rp = "@loader_path/../lib"
            has_zigllvm_rp = any(rp == expected_zigllvm_rp for rp in zig_rpaths)
            has_lib_rp = any(rp == expected_lib_rp for rp in zig_rpaths)
            if not has_zigllvm_rp:
                issues.append(f"zig binary missing rpath: {expected_zigllvm_rp}")
                hints.append(
                    "  -> The zig-zig post-install did not add the zig-llvm rpath to the binary. "
                    "Run: install_name_tool -add_rpath '@loader_path/../lib/zig-llvm/lib' <zig>"
                )
            if not has_lib_rp:
                issues.append(f"zig binary missing rpath: {expected_lib_rp}")
        elif llvm_deps_use_loader_path:
            # @loader_path refs resolve directly — no rpaths needed
            pass
        else:
            # Bare names — neither @rpath nor @loader_path
            bare_llvm = [d for d in zig_deps if is_llvm_or_cxx_ref(d)
                         and not d.startswith("@")]
            if bare_llvm:
                issues.append("zig binary has bare-name LLVM/libc++ refs (no @rpath or @loader_path):")
                for b in bare_llvm:
                    issues.append(f"  {b}")
                hints.append(
                    "  -> Bare names bypass @rpath resolution. Rewrite to "
                    "@loader_path/../lib/zig-llvm/lib/<name> with install_name_tool -change."
                )

    # Runtime result
    if not runtime_passed:
        issues.append(
            "RUNTIME: generic_category addresses differ — zig will print "
            "'LLVM and Clang have separate copies of libc++' and exit"
        )
        hints.append(
            "  -> Root cause is most likely one of the above structural issues. "
            "Fix @rpath rewrites and confirm no conda-forge LLVM dylibs shadow zig-llvm ones."
        )

    print()
    if warnings:
        print(yellow("Warnings (non-blocking, runtime isolation confirmed):"))
        for w in warnings:
            print(f"  {yellow('~')} {w}")
        print()
    if not issues:
        print(green("=" * 60))
        print(green("  OVERALL RESULT: PASS"))
        if warnings:
            print(green("  Runtime isolation confirmed despite competing copies."))
        else:
            print(green("  All isolation checks passed. Zig should start correctly."))
        print(green("=" * 60))
        return 0
    else:
        print(red("=" * 60))
        print(red("  OVERALL RESULT: FAIL"))
        print(red("=" * 60))
        print("\nIssues found:")
        for issue in issues:
            print(f"  {red('x')} {issue}")
        if hints:
            print("\nDiagnostic hints:")
            for hint in hints:
                print(hint)
        return 1


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    if sys.platform != "darwin":
        print(WARN(f"This script is macOS-only (darwin). Detected: {sys.platform}"))
        print(WARN("The @loader_path isolation mechanism only applies to Mach-O dylibs."))
        return 0

    prefix = os.environ.get("CONDA_PREFIX", os.environ.get("PREFIX", ""))
    if not prefix:
        print(red("ERROR: Set CONDA_PREFIX or PREFIX to your conda environment path."))
        print(red("  Example: CONDA_PREFIX=/opt/conda/envs/myenv python debug_libcxx_isolation.py"))
        return 1

    zigllvm_libdir = os.path.join(prefix, "lib", "zig-llvm", "lib")
    cf_libdir = os.path.join(prefix, "lib")

    if not os.path.isdir(zigllvm_libdir):
        print(red(f"ERROR: zig-llvm libdir not found: {zigllvm_libdir}"))
        print(red("  Is zig-llvm installed in this environment?"))
        return 1

    zig_binary = find_zig_binary(prefix)

    print(bold("\ndebug_libcxx_isolation.py — macOS libc++ isolation diagnostic"))
    print(bold(f"PREFIX      : {prefix}"))
    print(bold(f"zig-llvm lib: {zigllvm_libdir}"))
    print(bold(f"zig binary  : {zig_binary or '(not found)'}"))

    # Run all sections
    section_environment(prefix)

    categories = section_library_inventory(prefix, zigllvm_libdir, cf_libdir)

    section_install_names(zigllvm_libdir, categories)

    lib_deps = section_load_dependencies(zigllvm_libdir, categories)

    path_rpaths = section_rpaths(
        prefix, zigllvm_libdir, cf_libdir, zig_binary, categories
    )

    section_rpath_resolution(
        prefix, zigllvm_libdir, cf_libdir, zig_binary,
        categories, lib_deps, path_rpaths,
    )

    section_competing_library_check(
        zigllvm_libdir, cf_libdir, categories, lib_deps, path_rpaths
    )

    section_symbol_check(zigllvm_libdir, categories)

    runtime_passed = section_runtime_check(zigllvm_libdir, categories)

    section_dyld_print_libraries(zigllvm_libdir, categories)

    return section_summary(
        prefix, zigllvm_libdir, cf_libdir, zig_binary,
        categories, lib_deps, path_rpaths, runtime_passed,
    )


if __name__ == "__main__":
    sys.exit(main())
