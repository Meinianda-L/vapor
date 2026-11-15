#!/usr/bin/env python3
"""Vapor steamclient bridge generator.

Reads every Steamworks SDK version's headers (from a Proton lsteamclient checkout,
used as input data only — the headers are under the Steamworks SDK license and are
not redistributed) and produces, for each interface version string:

  * the Windows (MSVC) vtable order and the native macOS (Itanium) order,
  * a calling-convention shape per method (ints, floats, CSteamID/CGameID, struct returns),

and, for each callback struct, the Win64 (pack 8) and macOS (pack 4) layouts.

usage: gen_bridge.py <lsteamclient dir> <output dir>
"""
import json
import os
import re
import sys

# ---------------------------------------------------------------------------
# Preprocessing

PLATFORMS = {
    "win64": {"_WIN32": "1", "_WIN64": "1", "_MSC_VER": "1900", "X64BITS": "1", "WIN32": "1"},
    "mac64": {"__APPLE__": "1", "POSIX": "1", "OSX": "1", "__x86_64__": "1", "X64BITS": "1",
              "__GNUC__": "4", "__clang__": "1"},
}

COMMENT_RE = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)


def strip_comments(text):
    return COMMENT_RE.sub(lambda m: " " if m.group(0).startswith("/*") and "\n" not in m.group(0)
                          else "\n" * m.group(0).count("\n"), text)


def eval_condition(expr, defines):
    expr = re.sub(r"defined\s*\(\s*(\w+)\s*\)", lambda m: "1" if m.group(1) in defines else "0", expr)
    expr = re.sub(r"defined\s+(\w+)", lambda m: "1" if m.group(1) in defines else "0", expr)

    def ident(m):
        v = defines.get(m.group(0), "0")
        return v if re.fullmatch(r"-?\d+", v or "") else ("1" if v == "" and m.group(0) in defines else "0")
    expr = re.sub(r"\b[A-Za-z_]\w*\b", ident, expr)
    expr = expr.replace("&&", " and ").replace("||", " or ")
    expr = re.sub(r"!(?!=)", " not ", expr)
    try:
        return bool(eval(expr, {"__builtins__": {}}))
    except Exception:
        return False


def preprocess(text, defines):
    """Evaluates #if/#ifdef/... and collects #define; keeps #pragma pack lines."""
    out = []
    stack = []          # (active, taken)
    active = True
    lines = strip_comments(text).replace("\\\n", " ").split("\n")
    for line in lines:
        s = line.strip()
        if s.startswith("#"):
            d = s[1:].strip()
            word = d.split(None, 1)[0] if d else ""
            rest = d[len(word):].strip()
            if word in ("if", "ifdef", "ifndef"):
                if word == "if":
                    cond = eval_condition(rest, defines)
                elif word == "ifdef":
                    cond = rest.split()[0] in defines
                else:
                    cond = rest.split()[0] not in defines
                stack.append((active, cond))
                active = active and cond
            elif word == "elif":
                parent, taken = stack[-1]
                cond = not taken and eval_condition(rest, defines)
                stack[-1] = (parent, taken or cond)
                active = parent and cond
            elif word == "else":
                parent, taken = stack[-1]
                stack[-1] = (parent, True)
                active = parent and not taken
            elif word == "endif":
                active = stack.pop()[0] if stack else True
            elif active and word == "define":
                m = re.match(r"(\w+)(?!\()\s*(.*)", rest)
                if m and "(" not in rest.split()[0]:
                    defines[m.group(1)] = m.group(2).strip()
            elif active and word == "undef":
                defines.pop(rest.split()[0], None)
            elif active and word == "pragma" and rest.startswith("pack"):
                out.append("#pragma " + rest)
            continue
        if active:
            out.append(line)
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Parsing

ANNOTATION_RE = re.compile(r"\bSTEAM_(?!CALLBACK_|PRIVATE_API)[A-Z0-9_]+\s*\((?:[^()]|\([^()]*\))*\)")
TOKEN_RE = re.compile(r"#pragma[^\n]*|::|[A-Za-z_]\w*|\d+[xXa-fA-F\d]*[uUlL]*|\"(?:\\.|[^\"])*\"|'(?:\\.|[^'])*'|\S")


def unwrap_private_api(text):
    # STEAM_PRIVATE_API( virtual void Foo() = 0; ) -> virtual void Foo() = 0;
    out, i = [], 0
    while True:
        j = text.find("STEAM_PRIVATE_API", i)
        if j < 0:
            out.append(text[i:])
            return "".join(out)
        k = text.find("(", j)
        depth, p = 1, k + 1
        while depth and p < len(text):
            depth += {"(": 1, ")": -1}.get(text[p], 0)
            p += 1
        out.append(text[i:j])
        out.append(text[k + 1:p - 1])
        i = p


def expand_callback_macros(text):
    # STEAM_CALLBACK_BEGIN( Name, expr ) / STEAM_CALLBACK_MEMBER( i, type, name ) /
    # STEAM_CALLBACK_MEMBER_ARRAY( i, type, name, n ) / STEAM_CALLBACK_END( n )
    text = re.sub(r"STEAM_CALLBACK_BEGIN\s*\(\s*(\w+)\s*,\s*([^)]*)\)",
                  r"struct \1 { enum { k_iCallback = \2 };", text)
    text = re.sub(r"STEAM_CALLBACK_MEMBER_ARRAY\s*\(\s*\d+\s*,\s*([^,]+),\s*(\w+)\s*,\s*(\w+)\s*\)", r"\1 \2[\3];", text)
    text = re.sub(r"STEAM_CALLBACK_MEMBER\s*\(\s*\d+\s*,\s*([^,]+),\s*(\w+)\s*\)", r"\1 \2;", text)
    text = re.sub(r"STEAM_CALLBACK_END\s*\(\s*\d+\s*\)", "};", text)
    # Older SDKs: DEFINE_CALLBACK( Name, expr ) / CALLBACK_MEMBER( i, type, name ) / END_DEFINE_CALLBACK_n()
    text = re.sub(r"\bDEFINE_CALLBACK\s*\(\s*(\w+)\s*,\s*([^)]*)\)", r"struct \1 { enum { k_iCallback = \2 };", text)
    text = re.sub(r"\bCALLBACK_MEMBER\s*\(\s*\d+\s*,\s*([^,]+),\s*(\w+)\s*\)", r"\1 \2;", text)
    text = re.sub(r"\bCALLBACK_ARRAY\s*\(\s*\d+\s*,\s*([^,]+),\s*(\w+)\s*,\s*(\w+)\s*\)", r"\1 \2[\3];", text)
    text = re.sub(r"\bEND_DEFINE_CALLBACK_\d+\s*\(\s*\)", "};", text)
    return text


class Method:
    def __init__(self, name, ret, params):
        self.name, self.ret, self.params = name, ret, params    # params: [(type, name)]

    def to_json(self):
        return {"name": self.name, "ret": self.ret, "params": [t for t, _ in self.params]}


class Struct:
    def __init__(self, name, pack, fields, callback_expr):
        self.name, self.pack, self.fields, self.callback_expr = name, pack, fields, callback_expr


def normalize_type(tokens):
    t = " ".join(tokens)
    t = re.sub(r"\s*\*\s*", " *", t)
    t = re.sub(r"\s*&\s*", " &", t)
    t = re.sub(r"\b(struct|class|enum)\s+", "", t)
    return re.sub(r"\s+", " ", t).strip()


def split_params(tokens):
    params, depth, cur = [], 0, []
    for t in tokens:
        if t in "(<[":
            depth += 1
        elif t in ")>]":
            depth -= 1
        if t == "," and depth == 0:
            params.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        params.append(cur)
    out = []
    for p in params:
        if "=" in p:
            p = p[:p.index("=")]                        # default argument
        if p == ["void"] or not p:
            continue
        if len(p) > 1 and re.fullmatch(r"[A-Za-z_]\w*", p[-1]) and p[-2] not in ("::",) \
                and p[-1] not in ("int", "char", "bool", "float", "double", "long", "short", "unsigned", "signed"):
            out.append((normalize_type(p[:-1]), p[-1]))
        else:
            out.append((normalize_type(p), ""))
    return out


class Header:
    """Everything declared in one SDK version for one platform."""

    def __init__(self):
        self.classes = {}     # name -> [Method]
        self.structs = {}     # name -> Struct
        self.typedefs = {}    # name -> type string
        self.enums = set()
        self.constants = {}   # enum constants (callback bases)
        self.defines = {}

    def parse(self, text):
        text = expand_callback_macros(unwrap_private_api(text))
        text = ANNOTATION_RE.sub(" ", text)
        toks = TOKEN_RE.findall(text)
        self._parse_scope(toks, 0, len(toks), pack_stack=[None])

    def _skip_braces(self, toks, i):
        depth = 0
        while i < len(toks):
            if toks[i] == "{":
                depth += 1
            elif toks[i] == "}":
                depth -= 1
                if depth == 0:
                    return i
            i += 1
        return i

    def _pragma(self, tok, pack_stack):
        m = re.match(r"#pragma\s+pack\s*\(\s*(push)?\s*,?\s*(\d+)?\s*\)|#pragma\s+pack\s*\(\s*pop\s*\)", tok)
        if "pop" in tok:
            if len(pack_stack) > 1:
                pack_stack.pop()
        elif m and m.group(2):
            if m.group(1):
                pack_stack.append(int(m.group(2)))
            else:
                pack_stack[-1] = int(m.group(2))

    def _parse_scope(self, toks, i, end, pack_stack):
        while i < end:
            t = toks[i]
            if t.startswith("#pragma"):
                self._pragma(t, pack_stack)
                i += 1
            elif t == "typedef":
                j = i
                while j < end and toks[j] != ";":
                    if toks[j] == "{":
                        j = self._skip_braces(toks, j)
                    j += 1
                body = toks[i + 1:j]
                if body and body[0] in ("struct", "enum", "union") and "{" in toks[i:j]:
                    kind = body[0]
                    name = body[-1]
                    if kind == "enum":
                        self.enums.add(name)
                        self._enum_constants(toks, i, j)
                    else:
                        k = toks.index("{", i)
                        close = self._skip_braces(toks, k)
                        tag = toks[i + 2] if toks[i + 2] != "{" else name
                        self._struct(tag if tag != "{" else name, toks, k, close, pack_stack[-1], kind == "union")
                        if tag != name:
                            self.typedefs[name] = tag
                elif len(body) >= 2 and "(" not in body:
                    self.typedefs[body[-1]] = normalize_type(body[:-1])
                elif "(" in body and "*" in body:            # typedef ret (*Name)(args)
                    k = body.index("*")
                    if k + 1 < len(body) and re.fullmatch(r"\w+", body[k + 1]):
                        self.typedefs[body[k + 1]] = "void (*)()"
                i = j + 1
            elif t == "enum":
                j = i + 1
                name = toks[j] if toks[j] not in ("{", ":") else None
                while j < end and toks[j] not in ("{", ";"):
                    j += 1
                if j < end and toks[j] == "{":
                    close = self._skip_braces(toks, j)
                    self._enum_constants(toks, j, close)
                    if name:
                        self.enums.add(name)
                    i = close + 1
                else:
                    i = j + 1
            elif t in ("struct", "class", "union") and i + 1 < end:
                name = toks[i + 1]
                j = i + 2
                while j < end and toks[j] not in ("{", ";"):
                    j += 1
                if j < end and toks[j] == "{":
                    close = self._skip_braces(toks, j)
                    if any(toks[k] == "virtual" for k in range(j, close)):
                        self.classes[name] = self._methods(toks, j + 1, close)
                    else:
                        self._struct(name, toks, j, close, pack_stack[-1], t == "union")
                    i = close + 1
                else:
                    i = j + 1
            else:
                i += 1

    def _enum_constants(self, toks, i, close):
        body = toks[i:close]
        text = " ".join(body)
        for m in re.finditer(r"(\w+)\s*=\s*(-?\w+)\s*(?:,|}|$)", text):
            v = m.group(2)
            if re.fullmatch(r"-?\d+", v):
                self.constants[m.group(1)] = int(v)
            elif re.fullmatch(r"0[xX][0-9a-fA-F]+", v):
                self.constants[m.group(1)] = int(v, 16)

    def _methods(self, toks, i, end):
        methods = []
        while i < end:
            if toks[i] == "virtual":
                j = i
                while j < end and toks[j] not in (";", "{"):
                    j += 1
                decl = toks[i + 1:j]
                if j < end and toks[j] == "{":               # inline body, e.g. virtual ~X() {}
                    j = self._skip_braces(toks, j)
                if "(" in decl and "~" not in decl:
                    p = decl.index("(")
                    name = decl[p - 1]
                    depth, q = 0, p
                    while q < len(decl):
                        depth += {"(": 1, ")": -1}.get(decl[q], 0)
                        if depth == 0:
                            break
                        q += 1
                    ret = normalize_type(decl[:p - 1])
                    methods.append(Method(name, ret, split_params(decl[p + 1:q])))
                elif "~" in decl:
                    methods.append(Method("~dtor", "void", []))
                i = j + 1
            else:
                i += 1
        return methods

    def _struct(self, name, toks, open_i, close, pack, is_union):
        fields, callback, has_fnptr = [], None, False
        i = open_i + 1
        while i < close:
            t = toks[i]
            if t.startswith("#pragma"):
                i += 1
                continue
            if t == "enum":
                j = i
                while j < close and toks[j] not in ("{", ";"):
                    j += 1
                if toks[j] == "{":
                    c = self._skip_braces(toks, j)
                    if toks[i + 1] != "{":
                        self.enums.add(toks[i + 1])          # nested named enum
                    self._enum_constants(toks, j, c)
                    body = " ".join(toks[j + 1:c])
                    m = re.search(r"k_iCallback\s*=\s*([^,}]+)", body)
                    if m:
                        callback = m.group(1).strip()
                    i = c + 1
                    while i < close and toks[i] != ";":
                        i += 1
                    i += 1
                    continue
            if t in ("struct", "union", "class") and i + 2 < close and "{" in toks[i:i + 3]:
                j = toks.index("{", i)
                c = self._skip_braces(toks, j)
                named = toks[i + 1] != "{"
                tname = toks[i + 1] if named else f"{name}__anon{len(fields)}"
                self._struct(tname, toks, j, c, pack, t == "union")
                i = c + 1
                # "struct T {...} member;" / "union {...} data;" also declares a field
                k = i
                while k < close and toks[k] != ";":
                    k += 1
                names = [x for x in toks[i:k] if x not in (",", "*")]
                for n in names:
                    fields.append((tname, n, []))
                i = k + 1
                continue
            j = i
            depth = 0
            while j < close and not (toks[j] == ";" and depth == 0):
                if toks[j] in "({":
                    depth += 1
                elif toks[j] in ")}":
                    depth -= 1
                j += 1
            decl = toks[i:j]
            i = j + 1
            # Function-pointer member: "ret (*name)(args)" -> pointer-sized field.
            fp = next((k for k in range(len(decl) - 2) if decl[k] == "(" and decl[k + 1] == "*"), None)
            if fp is not None and decl and decl[0] not in ("typedef", "virtual", "static"):
                fields.append(("void *", decl[fp + 2], []))
                has_fnptr = True
                continue
            if not decl or "(" in decl or decl[0] in ("public", "private", "protected", "static", "friend",
                                                    "typedef", "using", "inline", "virtual", "explicit", "operator"):
                continue
            decl = [d for d in decl if d not in (":",) or True]
            if ":" in decl and decl[0] in ("public", "private", "protected"):
                continue
            # "float x, y;" declares several fields: split on top-level commas.
            parts, cur, depth = [], [], 0
            for d in decl:
                if d in "([":
                    depth += 1
                elif d in ")]":
                    depth -= 1
                if d == "," and depth == 0:
                    parts.append(cur)
                    cur = []
                else:
                    cur.append(d)
            parts.append(cur)
            base = None
            for n, part in enumerate(parts):
                if ":" in part:                             # bit-field
                    part = part[:part.index(":")]
                dims = []
                while part and part[-1] == "]":
                    k = len(part) - 1 - part[::-1].index("[")
                    dims.insert(0, " ".join(part[k + 1:-1]))
                    part = part[:k]
                if n == 0:
                    if len(part) < 2:
                        break
                    base = [x for x in part[:-1] if x != "*"]
                    ftype = normalize_type(part[:-1])
                else:
                    stars = [x for x in part[:-1] if x == "*"]
                    ftype = normalize_type(base + stars)
                if part:
                    fields.append((ftype, part[-1], dims))
        self.structs[name] = Struct(name, pack, fields, callback)
        self.structs[name].is_union = is_union
        self.structs[name].has_fnptr = has_fnptr


# ---------------------------------------------------------------------------
# Type layout

PRIMS = {
    "char": 1, "signed char": 1, "unsigned char": 1, "bool": 1, "int8": 1, "uint8": 1, "int8_t": 1, "uint8_t": 1,
    "short": 2, "unsigned short": 2, "int16": 2, "uint16": 2, "int16_t": 2, "uint16_t": 2, "wchar_t": 2,
    "int": 4, "unsigned int": 4, "unsigned": 4, "signed int": 4, "int32": 4, "uint32": 4, "int32_t": 4,
    "uint32_t": 4, "float": 4, "long long": 8, "unsigned long long": 8, "int64": 8, "uint64": 8,
    "int64_t": 8, "uint64_t": 8, "double": 8, "intptr_t": 8, "uintptr_t": 8, "intp": 8, "uintp": 8, "size_t": 8, "lint64": 8, "ulint64": 8,
    # MSVC built-in sized integers used by the Windows steamtypes.h
    "__int8": 1, "unsigned __int8": 1, "__int16": 2, "unsigned __int16": 2,
    "__int32": 4, "unsigned __int32": 4, "__int64": 8, "unsigned __int64": 8,
}
# Classes with fixed layout: (size, natural alignment, trivially copyable)
SPECIAL = {"CSteamID": (8, 8, True), "CGameID": (8, 8, False)}


class Layout:
    def __init__(self, header, platform):
        self.h, self.platform, self.cache = header, platform, {}

    def resolve(self, t):
        t = t.replace("const ", "").replace(" const", "").strip()
        seen = 0
        while t in self.h.typedefs and seen < 20:
            t = self.h.typedefs[t].replace("const ", "").strip()
            seen += 1
        return t

    def size_align(self, t, pack=None):
        t = self.resolve(t)
        if t.endswith("*") or t.endswith("&"):
            return 8, 8
        if t in ("long", "unsigned long"):
            n = 4 if self.platform == "win64" else 8
            return n, n
        if t in PRIMS:
            return PRIMS[t], PRIMS[t]
        if t in SPECIAL:
            return SPECIAL[t][0], SPECIAL[t][1]
        if t in self.h.enums or t.startswith("E") and t[1:2].isupper() and t not in self.h.structs:
            return 4, 4
        if t in self.h.structs:
            lay = self.struct_layout(t)
            return lay["size"], lay["align"]
        raise KeyError(t)

    def struct_layout(self, name):
        if name in self.cache:
            return self.cache[name]
        s = self.h.structs[name]
        pack = s.pack
        offset, align_max, fields = 0, 1, []
        for ftype, fname, dims in s.fields:
            size, align = self.size_align(ftype)
            count = 1
            for d in dims:
                count *= self.eval_dim(d)
            if pack:
                align = min(align, pack)
            if s.is_union:
                fields.append({"name": fname, "type": ftype, "offset": 0, "size": size * count})
                offset = max(offset, size * count)
            else:
                offset = (offset + align - 1) // align * align
                fields.append({"name": fname, "type": ftype, "offset": offset, "size": size * count})
                offset += size * count
            align_max = max(align_max, align)
        size = (offset + align_max - 1) // align_max * align_max if fields else 1
        lay = {"size": size, "align": align_max, "fields": fields}
        self.cache[name] = lay
        return lay

    def eval_dim(self, d):
        d = d.strip()
        expr = re.sub(r"\b[A-Za-z_]\w*\b", lambda m: str(self.h.constants.get(m.group(0),
                      self.h.defines.get(m.group(0), "0"))), d)
        try:
            return int(eval(expr, {"__builtins__": {}}))
        except Exception:
            return 0


# ---------------------------------------------------------------------------
# ABI classification

def msvc_order(methods):
    """MSVC groups all overloads of a name at the first one's position, in reverse
    declaration order."""
    order, done = [], set()
    for i, m in enumerate(methods):
        if m.name in done:
            continue
        group = [j for j, n in enumerate(methods) if n.name == m.name]
        order.extend(reversed(group))
        done.add(m.name)
    return order


def classify(t, lay):
    """Argument/return class for one type under one platform layout."""
    r = lay.resolve(t)
    if "(" in r:                                     # function pointer (callback hook)
        return "fnptr"
    if r == "void":
        return "v"
    if r.endswith("*") or r.endswith("&"):
        return "i"
    if r in ("float",):
        return "f"
    if r in ("double",):
        return "d"
    if r == "CGameID":
        return "gameid"
    if r == "CSteamID":
        return "steamid"
    try:
        size, _ = lay.size_align(r)
    except KeyError:
        return "?" + r
    if r in lay.h.structs:
        return f"struct{size}:{r}"
    return "i"


def method_shape(m, lay):
    ret = classify(m.ret, lay)
    params = [classify(t, lay) for t, _ in m.params]
    return ret, params


# ---------------------------------------------------------------------------
# Driver

def sdk_dirs(root):
    names = [d for d in os.listdir(root) if d.startswith("steamworks_sdk_")]
    key = lambda d: (int(re.match(r"\d+", d[15:]).group()), d[15:])
    return [os.path.join(root, d) for d in sorted(names, key=key, reverse=True)]


FIRST = ["steamtypes.h", "steamclientpublic.h", "steam_api_common.h", "steamhttpenums.h",
         "steamnetworkingtypes.h", "matchmakingtypes.h", "steamuniverse.h"]


def load_sdk(path, platform):
    h = Header()
    defines = dict(PLATFORMS[platform])
    files = sorted(f for f in os.listdir(path) if f.endswith(".h"))
    files = [f for f in FIRST if f in files] + [f for f in files if f not in FIRST]
    texts = []
    for f in files:
        with open(os.path.join(path, f), encoding="latin-1") as fh:
            texts.append(preprocess(fh.read(), defines))
    h.defines = defines
    h.parse("\n".join(texts))
    versions = {}
    for k, v in defines.items():
        m = re.fullmatch(r"(\w+?)_?INTERFACE_VERSION", k)
        if m and v.startswith('"'):
            versions[m.group(1).replace("_", "").upper()] = v.strip('"')
    return h, versions


def callback_id(expr, h):
    expr = re.sub(r"\b[A-Za-z_]\w*\b", lambda m: str(h.constants.get(m.group(0), "0")), expr)
    try:
        return int(eval(expr, {"__builtins__": {}}))
    except Exception:
        return None


def main(root, outdir):
    interfaces, structs, problems = {}, {}, []
    for path in sdk_dirs(root):
        sdk = os.path.basename(path)[15:]
        hw, vers = load_sdk(path, "win64")
        hm, _ = load_sdk(path, "mac64")
        lw, lm = Layout(hw, "win64"), Layout(hm, "mac64")
        for cname, methods_w in hw.classes.items():
            if not cname.startswith("ISteam"):
                continue
            version = vers.get(cname[1:].upper())
            if not version or version in interfaces:
                continue
            methods_m = hm.classes.get(cname, methods_w)
            # Itanium emits two vtable entries for a virtual destructor (complete +
            # deleting); MSVC emits one (scalar deleting destructor).
            native_pos, pos = [], 0
            for n in methods_m:
                native_pos.append(pos)
                pos += 2 if n.name == "~dtor" else 1
            entries = []
            for idx in msvc_order(methods_w):
                m = methods_w[idx]
                native = next((native_pos[k] for k, n in enumerate(methods_m)
                               if n.name == m.name and [t for t, _ in n.params] == [t for t, _ in m.params]), None)
                win_ret, win_params = method_shape(m, lw)
                mac_ret, mac_params = method_shape(m, lm)
                entries.append({"name": m.name, "native_slot": native, "ret": m.ret,
                                "params": [t for t, _ in m.params],
                                "win": [win_ret, win_params], "mac": [mac_ret, mac_params]})
                if native is None:
                    problems.append(f"{version}.{m.name}: no native slot")
            interfaces[version] = {"class": cname, "sdk": sdk, "methods": entries}
        for sname, s in hw.structs.items():
            if sname.split("__")[0] in SPECIAL or sname not in hm.structs:
                continue                                    # fixed-layout classes are not decomposed
            try:
                a, b = lw.struct_layout(sname), lm.struct_layout(sname)
            except (KeyError, RecursionError) as e:
                problems.append(f"struct {sname}@{sdk}: {e}")
                continue
            cb = callback_id(s.callback_expr, hw) if s.callback_expr else None
            differs = a["size"] != b["size"] or [f["offset"] for f in a["fields"]] != [f["offset"] for f in b["fields"]]
            # Function pointers cross the ABI boundary and always need wrapping.
            fnptr = getattr(s, "has_fnptr", False)
            structs[f"{sname}@{sdk}"] = {"name": sname, "sdk": sdk, "callback": cb, "differs": differs or fnptr,
                                          "layout_differs": differs, "fnptr": fnptr, "win": a, "mac": b}
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "interfaces.json"), "w") as f:
        json.dump(interfaces, f, indent=1)
    with open(os.path.join(outdir, "structs.json"), "w") as f:
        json.dump(structs, f, indent=1)
    print(f"{len(interfaces)} interface versions, {len(structs)} struct versions, {len(problems)} problems")
    for p in problems[:20]:
        print("  ", p)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
