#!/bin/bash
# Keeps Resources/Localizable.xcstrings in step with the code.
#
#   Tools/l10n.sh          extract every localizable string the compiler sees into the catalog
#   Tools/l10n.sh check    list strings that have no English translation yet
#
# Keys are the Chinese source text (the catalog's source language is zh-Hans). The compiler does the
# extraction, so a key is exactly what Text("…") or String(localized: "…") looks up, interpolations
# included ("下载中 %lld%%"). bundle.sh compiles the catalog into the app's .lproj folders.
set -euo pipefail
cd "$(dirname "$0")/.."
CATALOG=Resources/Localizable.xcstrings

missing() {
    python3 - "$CATALOG" <<'PY'
import json, sys
strings = json.load(open(sys.argv[1]))["strings"]
todo = [k for k, v in strings.items()
        if k.strip() and v.get("shouldTranslate", True)
        and not v.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")]
for k in sorted(todo):
    print(k)
print(f"{len(todo)} of {len(strings)} strings have no English translation", file=sys.stderr)
PY
}

if [ "${1:-}" = "check" ]; then missing; exit 0; fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swift build --scratch-path "$WORK/build" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings" >/dev/null
[ -f "$CATALOG" ] || printf '{\n  "sourceLanguage" : "zh-Hans",\n  "strings" : {},\n  "version" : "1.0"\n}\n' > "$CATALOG"
xcrun xcstringstool sync "$CATALOG" --stringsdata "$WORK"/strings/*.stringsdata
missing >/dev/null
