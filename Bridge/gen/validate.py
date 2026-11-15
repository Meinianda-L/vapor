#!/usr/bin/env python3
"""Cross-checks gen_bridge.py output against Proton's generated lsteamclient code.

1. Windows vtable order per interface version vs Proton's winISteam*.c vtables.
2. Structs whose Win64/Unix layouts differ vs Proton's w64_* struct definitions.
usage: validate.py <lsteamclient dir> <generator output dir>
"""
import glob
import json
import re
import sys

root, out = sys.argv[1], sys.argv[2]
interfaces = json.load(open(f"{out}/interfaces.json"))
structs = json.load(open(f"{out}/structs.json"))

# --- 1. vtable order -------------------------------------------------------------
proton = {}
for path in glob.glob(f"{root}/winISteam*.c"):
    text = open(path, encoding="latin-1").read()
    for m in re.finditer(r"__ASM_BLOCK_BEGIN\((winISteam\w+?)_vtables\)(.*?)__ASM_BLOCK_END", text, re.S):
        cls = m.group(1)
        funcs = re.findall(r"VTABLE_ADD_FUNC\(" + re.escape(cls) + r"_(\w+)\)", m.group(2))
        version = cls.split("_", 1)[1]
        proton[version] = funcs

ok = bad = missing = 0
mismatches = []
for version, info in interfaces.items():
    key = version.replace(".", "_")
    if key not in proton:
        missing += 1
        continue
    seen = {}
    ours = []
    # Proton suffixes overloads by declaration order: Foo, Foo_2, ...
    decl_index = {}
    names_in_decl = sorted(info["methods"], key=lambda e: e["native_slot"] if e["native_slot"] is not None else 1e9)
    for e in names_in_decl:
        decl_index.setdefault(e["name"], []).append(e["native_slot"])
    for e in info["methods"]:
        k = decl_index[e["name"]].index(e["native_slot"])
        name = e["name"] if k == 0 else f"{e['name']}_{k + 1}"
        if name == "~dtor":
            name = "destructor"
        ours.append(name)
    theirs = [f for f in proton[key]]
    # Proton appends non-virtual protected destructors; they are not real vtable slots.
    if theirs and theirs[-1] == "destructor" and "destructor" not in ours:
        theirs = theirs[:-1]
    if ours == theirs:
        ok += 1
    else:
        bad += 1
        mismatches.append((version, ours, theirs))

print(f"[vtable] {ok} match, {bad} differ, {missing} not in Proton (of {len(interfaces)})")
for version, ours, theirs in mismatches[:5]:
    for i, (a, b) in enumerate(zip(ours, theirs)):
        if a != b:
            print(f"   {version}: first difference at slot {i}: ours={a} proton={b}")
            break
    else:
        print(f"   {version}: length ours={len(ours)} proton={len(theirs)}")

# --- 2. struct conversion set ---------------------------------------------------------
text = open(f"{root}/steamclient_structs_generated.h", encoding="latin-1").read()
proton_conv = set()
same64 = set(re.findall(r"typedef struct w64_(\w+) u64_\1;", text))   # identical on 64-bit
for name in re.findall(r"^struct w64_(\w+)", text, re.M):
    if name not in same64:
        proton_conv.add(re.sub(r"_\d+[a-z]?$", "", name))
ours_conv = {v["name"] for v in structs.values() if v["differs"]}
ours_all = {v["name"] for v in structs.values()}
covered = proton_conv & ours_conv
not_flagged = sorted((proton_conv - ours_conv) & ours_all)
unknown = sorted(proton_conv - ours_all)
print(f"[structs] Proton converts {len(proton_conv)}: we flag {len(covered)}, "
      f"miss {len(not_flagged)}, not parsed {len(unknown)}; we flag {len(ours_conv - proton_conv)} extra")
if not_flagged:
    print("   missed:", ", ".join(not_flagged[:15]))
if unknown:
    print("   not parsed:", ", ".join(unknown[:15]))
