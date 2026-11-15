#!/bin/bash
# Builds Vapor's steamclient bridge: steamclient64.dll (PE, Wine builtin),
# steamclient64.so (x86_64 unix lib) and vapor-steamshim.exe.
set -euo pipefail
cd "$(dirname "$0")"
LLVM=/opt/homebrew/opt/llvm/bin
LLD=/opt/homebrew/opt/lld/bin/lld-link
mkdir -p build
lib() {  # name, exports...
    local name=$1; shift
    { echo "LIBRARY $name.dll"; echo EXPORTS; printf '%s\n' "$@"; } > build/$name.def
    $LLVM/llvm-dlltool -m i386:x86-64 -d build/$name.def -l build/$name.lib
}
lib kernel32 GetModuleHandleA GetProcAddress OutputDebugStringA GetCommandLineA GetCurrentProcessId \
    CreateProcessA WaitForSingleObject GetExitCodeProcess ExitProcess GetStdHandle WriteFile
lib ntdll NtQueryVirtualMemory
lib advapi32 RegCreateKeyExA RegSetValueExA RegCloseKey
CFLAGS=(--target=x86_64-pc-windows-msvc -O2 -ffreestanding -fno-builtin -fno-stack-protector -mno-stack-arg-probe -Wall)

$LLVM/clang "${CFLAGS[@]}" -c pe/steamclient.c -o build/steamclient.obj
$LLD /nologo /dll /entry:DllMain /nodefaultlib build/steamclient.obj build/kernel32.lib build/ntdll.lib /out:build/steamclient64.dll
# Mark as a Wine builtin: "Wine builtin DLL\0" right after the 64-byte DOS header.
printf 'Wine builtin DLL\0' | dd of=build/steamclient64.dll bs=1 seek=64 conv=notrunc status=none

$LLVM/clang "${CFLAGS[@]}" -c shim/steamshim.c -o build/steamshim.obj
$LLD /nologo /subsystem:console /entry:mainCRTStartup /nodefaultlib build/steamshim.obj build/kernel32.lib build/advapi32.lib /out:build/vapor-steamshim.exe

clang -arch x86_64 -dynamiclib -O2 -Wall -install_name @rpath/steamclient64.so -lffi -o build/steamclient64.so unix/steamclient_unix.c
ls -la build/steamclient64.dll build/steamclient64.so build/vapor-steamshim.exe
xxd -s 64 -l 17 build/steamclient64.dll
