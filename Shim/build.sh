#!/bin/bash
# Builds what Vapor runs alongside Windows Steam: libvapor-steamhide.dylib (DYLD-injected into Steam's
# Wine processes) and vapor-winwatch.exe (PE, runs in Steam's prefix). Output: $1, default build/lib,
# where dev builds of Vapor look (WindowsSteam.vaporLibrary); bundle.sh passes the app's Resources.
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:-../build/lib}
mkdir -p "$OUT"
LLVM=/opt/homebrew/opt/llvm/bin
LLD=/opt/homebrew/opt/lld/bin/lld-link
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# x86_64 for Wine under Rosetta, arm64 for completeness; no frameworks linked (see steamhide.m).
clang -arch x86_64 -arch arm64 -dynamiclib -O2 -Wall -lobjc -o "$OUT/libvapor-steamhide.dylib" steamhide.m

lib() {  # name, exports...
    local name=$1; shift
    { echo "LIBRARY $name.dll"; echo EXPORTS; printf '%s\n' "$@"; } > "$TMP/$name.def"
    $LLVM/llvm-dlltool -m i386:x86-64 -d "$TMP/$name.def" -l "$TMP/$name.lib"
}
lib kernel32 GetStdHandle WriteFile ReadFile CreateThread ExitProcess OpenProcess CloseHandle \
    QueryFullProcessImageNameW WideCharToMultiByte GetCommandLineW Sleep GetTickCount
lib user32 EnumWindows EnumChildWindows GetWindowThreadProcessId IsWindow IsWindowVisible IsWindowEnabled \
    GetClassNameW GetWindowTextW GetWindowLongW GetDlgCtrlID GetParent GetAncestor SendMessageTimeoutW PostMessageW
$LLVM/clang --target=x86_64-pc-windows-msvc -O2 -ffreestanding -fno-builtin -fno-stack-protector -mno-stack-arg-probe -Wall \
    -c winwatch.c -o "$TMP/winwatch.obj"
$LLD /nologo /subsystem:console /entry:mainCRTStartup /nodefaultlib "$TMP/winwatch.obj" "$TMP/kernel32.lib" "$TMP/user32.lib" \
    /out:"$OUT/vapor-winwatch.exe"
