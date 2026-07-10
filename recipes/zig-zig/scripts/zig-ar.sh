#!/usr/bin/env bash
# Strip 'T' (thin archive) modifier — zig's linker frontend can't parse thin archives,
# even though zig ar (llvm-ar) can create them. Meson unconditionally passes csrDT on Linux.
_args=()
for _a in "$@"; do
    if [[ ${#_args[@]} -eq 0 && "${_a}" =~ ^[a-zA-Z]+$ && "${_a}" == *T* ]]; then
        _args+=("${_a//T/}")
    else
        _args+=("${_a}")
    fi
done
# Strip foreign -target X / --target=X args (defensive: cmake/build aliases may inject
# clang-style -target which the underlying zig subcommand doesn't accept).
_filtered_args=()
set -- "${_args[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -target)
            shift
            [[ $# -gt 0 ]] && shift
            ;;
        --target=*)
            shift
            ;;
        *)
            _filtered_args+=("$1")
            shift
            ;;
    esac
done
exec "@ZIG_BIN@" ar "${_filtered_args[@]}"
