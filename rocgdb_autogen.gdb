# ROCgdb: auto-generate & auto-source kernel-specific convenience vars on stop
#
# Goal:
#   When you stop inside a Tensile asm `.s` file, ROCgdb already knows the
#   current asm path + line. We use that to parse `.set` symbols, then
#   dynamically (re)define `roc_update` so `$sgprFoo` / `$vgprBar_*` convenience
#   variables exist and refresh on every stop.
#
# Usage:
#   (gdb) source rocgdb_utilities/rocgdb_autogen.gdb
#   (gdb) roc_autogen_enable            # default: inline parser (no external script needed)
#
# Commands:
#   - roc_autogen [--force]
#   - roc_autogen_enable [--force]
#
# Notes:
#   - This caches per-asm file: it only regenerates when you stop at a *later*
#     line than previously seen (or when the asm file changed).
#

python
import gdb
import os
import re


_SET_RE = re.compile(r"^\s*\.set\s+([A-Za-z_][A-Za-z0-9_]*)\s*,\s*(.+?)\s*$")
_V_USE_RE = re.compile(r"v\[\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\+\s*([0-9]+))?\s*\]")
_S_USE_RE = re.compile(r"s\[\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\+\s*([0-9]+))?\s*\]")
_V_RANGE_RE = re.compile(r"v\[\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\1\s*\+\s*([0-9]+)\s*\]")
_S_RANGE_RE = re.compile(r"s\[\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\1\s*\+\s*([0-9]+)\s*\]")


def _strip_comment(line: str) -> str:
    # Tensile asm uses // and sometimes ;. Keep it simple and stop at '//' first.
    if "//" in line:
        line = line.split("//", 1)[0]
    return line.strip()


def _parse_defs_uses_ranges(asm_path: str, upto_line: int):
    defs = {}          # name -> expr string
    v_uses = set()     # (name, off)
    s_uses = set()     # (name, off)
    ranges = set()     # (kind, name, start_off, end_off)

    with open(asm_path, "r", encoding="utf-8", errors="replace") as f:
        for ln, raw in enumerate(f, start=1):
            if upto_line is not None and ln > upto_line:
                break
            line = _strip_comment(raw)
            if not line:
                continue

            m = _SET_RE.match(line)
            if m:
                name, expr = m.group(1), m.group(2).strip()
                defs[name] = expr
                continue

            # Uses: v[...] / s[...]
            for mm in _V_USE_RE.finditer(line):
                n = mm.group(1)
                off = int(mm.group(2)) if mm.group(2) else 0
                v_uses.add((n, off))
            for mm in _S_USE_RE.finditer(line):
                n = mm.group(1)
                off = int(mm.group(2)) if mm.group(2) else 0
                s_uses.add((n, off))

            # Ranges: v[name:name+K] / s[name:name+K]
            for mm in _V_RANGE_RE.finditer(line):
                n = mm.group(1)
                k = int(mm.group(2))
                ranges.add(("v", n, 0, k))
            for mm in _S_RANGE_RE.finditer(line):
                n = mm.group(1)
                k = int(mm.group(2))
                ranges.add(("s", n, 0, k))

    return defs, v_uses, s_uses, ranges


def _try_int(expr: str):
    try:
        return int(expr, 0)
    except Exception:
        return None


def _eval_set_expr(expr: str, resolved: dict):
    """
    Evaluate Tensile `.set` expressions consisting of:
      - integers (dec/hex)
      - symbol names
      - + and - operators
    """
    expr = expr.strip()
    v = _try_int(expr)
    if v is not None:
        return v

    # Tokenize: NAME / INT / + / -
    toks = re.findall(r"[A-Za-z_][A-Za-z0-9_]*|0x[0-9a-fA-F]+|[0-9]+|[+-]", expr)
    if not toks:
        return None

    total = None
    op = "+"
    for t in toks:
        if t in ("+", "-"):
            op = t
            continue
        if re.match(r"^(0x[0-9a-fA-F]+|[0-9]+)$", t):
            val = int(t, 0)
        else:
            if t not in resolved or resolved[t] is None:
                return None
            val = int(resolved[t])

        if total is None:
            total = val
        else:
            total = total + val if op == "+" else total - val
    return total


def _resolve_all(defs: dict):
    """
    Resolve all `.set` symbols to ints when possible.
    """
    resolved = {k: None for k in defs.keys()}

    # Iterate to a fixed point
    progress = True
    for _ in range(1000):
        if not progress:
            break
        progress = False
        for name, expr in defs.items():
            if resolved.get(name) is not None:
                continue
            v = _eval_set_expr(expr, resolved)
            if v is not None:
                resolved[name] = int(v)
                progress = True
    return resolved


def _gdb_define_roc_update(resolved: dict, v_uses: set, s_uses: set, ranges: set):
    """
    (Re)define a gdb user command `roc_update` that refreshes all $sgpr*/$vgpr* vars.
    """
    base_names = sorted([n for n, v in resolved.items() if v is not None and (n.startswith("vgpr") or n.startswith("sgpr"))])
    if not base_names:
        raise gdb.GdbError("roc_autogen: no resolved vgpr/sgpr symbols found at this location.")

    range_base_names = {name for _kind, name, start_off, end_off in ranges if end_off != start_off}
    indexed_base_names = set(range_base_names)
    indexed_base_names.update({n for (n, off) in v_uses if off != 0})
    indexed_base_names.update({n for (n, off) in s_uses if off != 0})

    # Expand all concrete offsets we care about
    def expand(uses, kind):
        out = set()
        for name, off in uses:
            base = resolved.get(name)
            if base is None:
                continue
            out.add((name, off, int(base) + int(off)))
        for _k, name, start_off, end_off in ranges:
            if _k != kind:
                continue
            base = resolved.get(name)
            if base is None:
                continue
            for off in range(int(start_off), int(end_off) + 1):
                out.add((name, off, int(base) + int(off)))
        return sorted(out, key=lambda x: (x[0], x[1], x[2]))

    v_list = expand(v_uses, "v")
    s_list = expand(s_uses, "s")

    # Export a symbol->(kind,idx) map for other scripts (e.g. `reg`) so they can
    # evaluate $sgprFoo/$vgprBar dynamically by rewriting to $sN/$vN per-thread,
    # without relying on the snapshot convenience vars.
    #
    # Key format: without leading '$' (e.g. "sgprWorkGroup0", "vgprValuA_3")
    sym2reg = {}
    for name in base_names:
        idx = resolved[name]
        sym2reg[name] = ("v", int(idx)) if name.startswith("vgpr") else ("s", int(idx))
    for name, off, ridx in v_list:
        sym2reg[f"{name}_{off}"] = ("v", int(ridx))
    for name, off, ridx in s_list:
        sym2reg[f"{name}_{off}"] = ("s", int(ridx))
    setattr(gdb, "_roc_autogen_sym2reg", sym2reg)

    # Build the gdb `define roc_update` body as one multi-line string.
    lines = []
    lines.append("define roc_update")

    for name in base_names:
        idx = resolved[name]
        reg = f"$v{idx}" if name.startswith("vgpr") else f"$s{idx}"
        lines.append(f"  set ${name} = {reg}")
        if name in indexed_base_names:
            lines.append(f"  set ${name}_0 = {reg}")

    for name, off, ridx in v_list:
        if off == 0:
            continue
        lines.append(f"  set ${name}_{off} = $v{ridx}")
    for name, off, ridx in s_list:
        if off == 0:
            continue
        lines.append(f"  set ${name}_{off} = $s{ridx}")

    # Also snapshot numeric `.set` constants (non sgpr/vgpr)
    consts = sorted([n for n, v in resolved.items() if v is not None and not (n.startswith("vgpr") or n.startswith("sgpr"))])
    for name in consts:
        lines.append(f"  set ${name} = {int(resolved[name])}")

    lines.append("end")

    gdb.execute("\n".join(lines), to_string=True)


def _roc_autogen_inline(asm_path: str, upto_line: int):
    defs, v_uses, s_uses, ranges = _parse_defs_uses_ranges(asm_path, upto_line)
    resolved = _resolve_all(defs)
    _gdb_define_roc_update(resolved, v_uses, s_uses, ranges)
    # refresh immediately
    gdb.execute("roc_update", to_string=True)


def _roc_current_asm_and_line():
    """
    Return (asm_path, line) if current location is an asm `.s` file, else (None, None).
    """
    try:
        fr = gdb.selected_frame()
        sal = fr.find_sal()
        if sal is None or sal.symtab is None:
            return None, None
        line = getattr(sal, "line", None)
        try:
            # fullname() is absolute; filename is often relative
            asm = sal.symtab.fullname()
        except Exception:
            asm = sal.symtab.filename
        if not asm or not str(asm).endswith(".s"):
            return None, None
        asm = str(asm)
        if line is None:
            return asm, None
        return asm, int(line)
    except Exception:
        return None, None


_roc_autogen_state = {
    "in_progress": False,
    # asm_path -> {"mtime": float, "max_line": int}
    "cache": {},
}


class RocAutogenCommand(gdb.Command):
    """Auto-generate and source per-kernel convenience variables based on current asm stop location."""

    def __init__(self):
        super().__init__("roc_autogen", gdb.COMMAND_USER)

    def invoke(self, arg, from_tty):
        if _roc_autogen_state["in_progress"]:
            return

        argv = gdb.string_to_argv(arg)
        force = False

        i = 0
        while i < len(argv):
            a = argv[i]
            if a == "--force":
                force = True
                i += 1
            else:
                raise gdb.GdbError("roc_autogen: unknown/invalid args. Use: roc_autogen [--force]")

        asm, line = _roc_current_asm_and_line()
        if asm is None:
            gdb.write("roc_autogen: not stopped in a `.s` file (Tensile asm).\n")
            return
        if line is None:
            gdb.write(f"roc_autogen: could not determine line for {asm}\n")
            return

        try:
            mtime = os.path.getmtime(asm)
        except Exception:
            mtime = None

        cache = _roc_autogen_state["cache"].get(asm)
        need = force
        if cache is None:
            need = True
        else:
            # Regenerate if asm changed or we advanced to a later line.
            if cache.get("mtime") != mtime:
                need = True
            if int(line) > int(cache.get("max_line", -1)):
                need = True

        if not need:
            # Already generated enough; just refresh convenience vars for this stop.
            try:
                gdb.execute("roc_update", to_string=True)
            except gdb.error:
                pass
            return

        _roc_autogen_state["in_progress"] = True
        try:
            _roc_autogen_inline(asm_path=asm, upto_line=int(line))
            _roc_autogen_state["cache"][asm] = {
                "mtime": mtime,
                "max_line": int(line),
            }
        finally:
            _roc_autogen_state["in_progress"] = False


class RocAutogenEnableCommand(gdb.Command):
    """Enable auto-generation by running roc_autogen on every stop (via gdb.events.stop)."""

    def __init__(self):
        super().__init__("roc_autogen_enable", gdb.COMMAND_USER)

    def invoke(self, arg, from_tty):
        argv = gdb.string_to_argv(arg)
        force = False

        i = 0
        while i < len(argv):
            a = argv[i]
            if a == "--force":
                force = True
                i += 1
            else:
                raise gdb.GdbError("roc_autogen_enable: unknown/invalid args. Use: roc_autogen_enable [--force]")

        if _roc_autogen_event["connected"] and not force:
            gdb.write("roc_autogen_enable: already enabled.\n")
            return

        # (Re)connect stop-event handler (does not conflict with user hook-stop / VSCode).
        try:
            if _roc_autogen_event["connected"]:
                try:
                    gdb.events.stop.disconnect(_roc_autogen_on_stop)
                except Exception:
                    pass
            gdb.events.stop.connect(_roc_autogen_on_stop)
            _roc_autogen_event["connected"] = True
            gdb.write("roc_autogen_enable: enabled (stop-event handler installed).\n")
        except Exception:
            _roc_autogen_event["connected"] = False
            raise gdb.GdbError("roc_autogen_enable: failed to connect gdb.events.stop (events not supported in this ROCgdb build?)")


RocAutogenCommand()
RocAutogenEnableCommand()


# -----------------------------------------------------------------------------
# Auto-install (one-shot): enable stop-event autogen on the first stop after
# this file is sourced, then disconnect the one-shot installer.
# -----------------------------------------------------------------------------

_roc_autogen_autoinstall = {"connected": False}
_roc_autogen_event = {"connected": False}


def _roc_autogen_on_stop(event):
    # Run quietly; only does real work if we're stopped in a Tensile `.s` frame.
    try:
        gdb.execute("roc_autogen", to_string=True)
    except Exception:
        pass


def _roc_autogen_on_first_stop(event):
    # Disconnect first to ensure we only run once even if something errors.
    try:
        gdb.events.stop.disconnect(_roc_autogen_on_first_stop)
    except Exception:
        pass
    _roc_autogen_autoinstall["connected"] = False

    # Enable the stop-event handler (no hook-stop conflicts).
    try:
        gdb.execute("roc_autogen_enable", to_string=True)
        # Try once immediately on this stop (quiet). If we're not in asm yet, it just no-ops.
        gdb.execute("roc_autogen", to_string=True)
    except Exception:
        # Never throw from an event handler.
        pass


def _roc_autogen_install_on_first_stop():
    if _roc_autogen_autoinstall["connected"]:
        return
    try:
        gdb.events.stop.connect(_roc_autogen_on_first_stop)
        _roc_autogen_autoinstall["connected"] = True
    except Exception:
        # If this gdb build doesn't support events, silently ignore.
        _roc_autogen_autoinstall["connected"] = False


_roc_autogen_install_on_first_stop()
end


