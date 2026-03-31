/*
 * DLL isolation shim for zig on Windows.
 * Prepends zig-llvm/bin to PATH so zig finds libLLVM-20.dll and libc++.dll
 * without polluting the global PATH. Then exec's the real zig binary.
 *
 * Compiled with: zig cc -target x86_64-windows-gnu -DREAL_EXE_NAME="\"name.real.exe\""
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <process.h>
#include <windows.h>

int main(int argc, char *argv[]) {
    char exe_dir[MAX_PATH];
    GetModuleFileNameA(NULL, exe_dir, MAX_PATH);
    /* Strip filename to get directory */
    char *last_sep = strrchr(exe_dir, '\\');
    if (last_sep) *(last_sep + 1) = '\0';

    /* Build new PATH: exe_dir\..\lib\zig-llvm\bin;%PATH% */
    char dll_dir[MAX_PATH];
    snprintf(dll_dir, MAX_PATH, "%s..\\lib\\zig-llvm\\bin", exe_dir);

    const char *old_path = getenv("PATH");
    size_t new_len = strlen(dll_dir) + 1 + (old_path ? strlen(old_path) : 0) + 1;
    char *new_path = malloc(new_len);
    if (old_path)
        snprintf(new_path, new_len, "%s;%s", dll_dir, old_path);
    else
        snprintf(new_path, new_len, "%s", dll_dir);
    SetEnvironmentVariableA("PATH", new_path);
    free(new_path);

    /* Build real exe path */
    char real_exe[MAX_PATH];
    snprintf(real_exe, MAX_PATH, "%s%s", exe_dir, REAL_EXE_NAME);

    /* Replace argv[0] and exec */
    argv[0] = real_exe;
    return (int)_spawnv(_P_WAIT, real_exe, (const char *const *)argv);
}
