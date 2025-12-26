# Common ROCgdb/GDB helpers (source this file once per debug session)
#
# Usage:
#   (gdb) source rocgdb_utilities/rocgdb_utilities.gdb
#
# Commands provided:
#   - reg <expr> [--max-cu N] [--cu ID]... [--hex|--dec] [--fp16|--bf16|--fp32] [--lane N] [--show-err]
#           [--debug] [--escape] [--out PATH]
#       Dump register values in a CU/wave table. For VGPRs, default prints all lanes (16 per line).
#       You can omit the leading '$' for register-like tokens (e.g. `reg sgprWorkGroup0`, `reg v192`).
#       For SGPR/VGPR ($sgpr*/$vgpr*/$sN/$vN), default is decimal integer output (use --hex to override).
#
#   - lds <offset> [count] [hex|fp16|bf16|fp32] [--out PATH]
#       Dump LDS (local address space) with optional decoding.
#
#   - global <addr-expr> [count] [hex|fp16|bf16|fp32] [--out PATH]
#   - global <addr-lo-expr> <addr-hi-expr> [count] [hex|fp16|bf16|fp32] [--out PATH]
#       Dump global/generic memory with optional decoding.

python
import collections
import gdb
import re
import os


def _rewrite_expr_via_autogen_map(expr: str) -> str:
    """
    If rocgdb_autogen.gdb is loaded, it exports `gdb._roc_autogen_sym2reg`
    mapping symbol names (without leading '$') to ('s'/'v', index).
    Use that to rewrite $sgprFoo/$vgprBar[_K] to $sN/$vN so evaluation is
    per-thread (not a snapshot convenience var).
    """
    try:
        if not expr or not expr.startswith("$"):
            return expr
        sym2reg = getattr(gdb, "_roc_autogen_sym2reg", None)
        if not isinstance(sym2reg, dict):
            return expr

        # Support register-index expressions like:
        #   $sgprSrdA+1  -> $s{base+1}  (maps to sgprSrdA_1)
        #   $vgprFoo+12  -> $v{base+12}
        m = re.match(r"^\$(?P<name>(?:sgpr|vgpr)[A-Za-z_][A-Za-z0-9_]*)\s*\+\s*(?P<off>0x[0-9a-fA-F]+|\d+)\s*$", expr)
        if m:
            base_name = m.group("name")
            off = int(m.group("off"), 0)
            kv0 = sym2reg.get(base_name)
            if kv0 and len(kv0) == 2:
                kind0, idx0 = kv0[0], int(kv0[1])
                if kind0 == "s":
                    return f"$s{idx0 + off}"
                if kind0 == "v":
                    return f"$v{idx0 + off}"

        key = expr[1:]
        kv = sym2reg.get(key)
        if not kv or len(kv) != 2:
            return expr
        kind, idx = kv[0], int(kv[1])
        if kind == "s":
            return f"$s{idx}"
        if kind == "v":
            return f"$v{idx}"
        return expr
    except Exception:
        return expr


def _normalize_reg_expr(expr: str) -> str:
    """
    Allow users to omit the leading '$' when passing a register-like token:
      - sgprFoo / vgprBar / sgprFoo_3 / vgprBar_12
      - sN / vN
    Also, if rocgdb_autogen.gdb is loaded, accept any autogen symbol name in
    gdb._roc_autogen_sym2reg without '$'.
    """
    try:
        if not expr:
            return expr
        if expr.startswith("$"):
            return expr

        # If autogen map is present, accept bare symbol names.
        sym2reg = getattr(gdb, "_roc_autogen_sym2reg", None)
        if isinstance(sym2reg, dict) and expr in sym2reg:
            return "$" + expr

        if re.match(r"^(sgpr|vgpr)[A-Za-z_][A-Za-z0-9_]*(?:_[0-9]+)?(?:\s*\+\s*(?:0x[0-9a-fA-F]+|\d+))?$", expr):
            return "$" + expr
        if re.match(r"^[sv][0-9]+$", expr):
            return "$" + expr
        return expr
    except Exception:
        return expr


def _intish_value(v, lane_idx=None):
    """
    Convert a gdb.Value to an int when possible (integral/pointer/enums).
    Returns None if conversion is not meaningful.
    """
    try:
        t = v.type.strip_typedefs()
    except Exception:
        t = v.type

    # gdb.TYPE_CODE_* constants vary by build; use attribute access defensively.
    try:
        code = t.code
    except Exception:
        code = None

    # 1: TYPE_CODE_PTR, 8: TYPE_CODE_INT, 10: TYPE_CODE_ENUM (common values, but don't rely on numbers)
    if code in (getattr(gdb, "TYPE_CODE_PTR", None), getattr(gdb, "TYPE_CODE_INT", None), getattr(gdb, "TYPE_CODE_ENUM", None)):
        ull = gdb.lookup_type("unsigned long long")
        try:
            return int(v.cast(ull)) & ((1 << 64) - 1)
        except Exception:
            return int(v)

    # AMDGPU VGPRs may appear as an array/vector (one element per lane).
    # If lane_idx is provided, pick that lane; otherwise return None (caller may choose to print all lanes).
    if code == getattr(gdb, "TYPE_CODE_ARRAY", None):
        if lane_idx is None:
            return None
        idx = int(lane_idx)
        try:
            # v[idx] should yield the selected lane's scalar value
            return _intish_value(v[idx], lane_idx=None)
        except Exception:
            return None

    # Fallback: try int() anyway
    try:
        return int(v)
    except Exception:
        return None


def _pad(s: str, w: int) -> str:
    return s + (" " * max(0, w - len(s)))


def _parse_out_arg(argv):
    """
    Parse a shared optional output flag: --out <path>

    Returns (out_path_or_None, argv_without_out)
    """
    out_path = None
    out_argv = []
    i = 0
    while i < len(argv):
        if argv[i] == "--out" and i + 1 < len(argv):
            out_path = argv[i + 1]
            i += 2
            continue
        out_argv.append(argv[i])
        i += 1
    return out_path, out_argv


class _TeeWriter:
    def __init__(self, out_path):
        self._f = None
        self._out_path = out_path
        if out_path:
            # Append so multiple dumps can be collected in one file.
            self._f = open(out_path, "a", encoding="utf-8", errors="replace")

    def write(self, s: str):
        gdb.write(s)
        if self._f is not None:
            self._f.write(s)
            self._f.flush()

    def close(self):
        try:
            if self._f is not None:
                self._f.close()
        except Exception:
            pass


def _u32_to_str(iv, out_hex, float_mode):
    """
    Format a 32-bit register value.

    float_mode:
      - None: integer formatting (hex/dec)
      - 'fp32': interpret as 1x float32
      - 'fp16': interpret as 2x fp16 (lo16, hi16)
      - 'bf16': interpret as 2x bf16 (lo16, hi16)
    """
    if iv is None:
        return "ERR"
    iv = int(iv) & 0xFFFFFFFF
    if float_mode is None:
        return (f"0x{iv:08x}" if out_hex else str(iv))

    # Float formatting uses fixed decimals + reserved sign column via _fmt_float_cell (defined later).
    if float_mode == "fp32":
        f0 = struct.unpack("<f", struct.pack("<I", iv & 0xFFFFFFFF))[0]
        return _fmt_float_cell(f0, decimals=6)

    if float_mode in ("fp16", "bf16"):
        conv = _half_to_float if float_mode == "fp16" else _bf16_to_float
        lo16 = iv & 0xFFFF
        hi16 = (iv >> 16) & 0xFFFF
        f0 = conv(lo16)
        f1 = conv(hi16)
        a = _fmt_float_cell(f0, decimals=3)
        b = _fmt_float_cell(f1, decimals=3)
        return f"({a},{b})"

    return "ERR"


def _format_lanes_chunks_u32(v, out_hex=True, per_line=16, float_mode=None):
    """Format a VGPR vector (array) as multiple lines, `per_line` lanes per line."""
    try:
        lo, hi = v.type.range()
        lo, hi = int(lo), int(hi)
    except Exception:
        return ["ERR"]

    parts = []
    for i in range(lo, hi + 1):
        try:
            parts.append(_u32_to_str(_intish_value(v[i], lane_idx=None), out_hex=out_hex, float_mode=float_mode))
        except Exception:
            parts.append("ERR")

    chunks = []
    for base in range(0, len(parts), per_line):
        chunks.append(" ".join(parts[base:base + per_line]))
    return chunks


def _format_lanes_range_u32(v, lane_lo, lane_hi, out_hex=True, per_line=16, float_mode=None):
    """Format lanes [lane_lo..lane_hi] (inclusive) as multiple lines, `per_line` lanes per line."""
    try:
        lo, hi = v.type.range()
        lo, hi = int(lo), int(hi)
    except Exception:
        return ["ERR"], 0, -1

    lo = max(lo, int(lane_lo))
    hi = min(hi, int(lane_hi))
    if hi < lo:
        return [], lo, hi

    parts = []
    for i in range(lo, hi + 1):
        try:
            parts.append(_u32_to_str(_intish_value(v[i], lane_idx=None), out_hex=out_hex, float_mode=float_mode))
        except Exception:
            parts.append("ERR")

    chunks = []
    for base in range(0, len(parts), per_line):
        chunks.append(" ".join(parts[base:base + per_line]))
    return chunks, lo, hi


def _value_to_cell(v, out_hex=True, lane_idx=None):
    """
    Convert a gdb.Value to a printable cell string.

    - Scalars/pointers/enums: print as hex/dec.
    - VGPR vectors (arrays): if lane_idx is None, print all lanes as a list; else print one lane.
    """
    try:
        t = v.type.strip_typedefs()
    except Exception:
        t = v.type

    try:
        code = t.code
    except Exception:
        code = None

    def fmt_int(iv):
        if iv is None:
            return "ERR"
        return (f"0x{(int(iv) & 0xFFFFFFFF):08x}" if out_hex else str(int(iv) & 0xFFFFFFFF))

    if code == getattr(gdb, "TYPE_CODE_ARRAY", None):
        # Lane selection
        if lane_idx is not None:
            try:
                return fmt_int(_intish_value(v, lane_idx=lane_idx))
            except Exception:
                return "ERR"

        # Default: print all lanes (compact list in one cell)
        try:
            lo, hi = v.type.range()
            lo, hi = int(lo), int(hi)
        except Exception:
            return "ERR"
        parts = []
        for i in range(lo, hi + 1):
            try:
                parts.append(fmt_int(_intish_value(v[i], lane_idx=None)))
            except Exception:
                parts.append("ERR")
        return "[" + " ".join(parts) + "]"

    return fmt_int(_intish_value(v, lane_idx=None))


def _is_array_value(v) -> bool:
    try:
        t = v.type.strip_typedefs()
    except Exception:
        t = v.type
    try:
        return t.code == getattr(gdb, "TYPE_CODE_ARRAY", None)
    except Exception:
        return False


def _format_lanes_chunks(v, out_hex=True, per_line=16):
    """Format a VGPR vector (array) as multiple lines, `per_line` lanes per line.

    Returns list[str], each containing a space-separated list of lane values.
    """
    def fmt_int(iv):
        if iv is None:
            return "ERR"
        return (f"0x{(int(iv) & 0xFFFFFFFF):08x}" if out_hex else str(int(iv) & 0xFFFFFFFF))

    try:
        lo, hi = v.type.range()
        lo, hi = int(lo), int(hi)
    except Exception:
        return "ERR"

    parts = []
    for i in range(lo, hi + 1):
        try:
            parts.append(fmt_int(_intish_value(v[i], lane_idx=None)))
        except Exception:
            parts.append("ERR")

    chunks = []
    for base in range(0, len(parts), per_line):
        chunks.append(" ".join(parts[base:base + per_line]))
    return chunks


class RegCommand(gdb.Command):
    """reg <expr> [--max-cu N] [--cu ID]... [--wave W|W0-W1|W0,W1,...] [--hex|--dec] [--fp16|--bf16|--fp32] [--lane N] [--show-err]
       reg --map

Print a 4-column grid. Each row corresponds to one CU, and each column is one wave.
This uses thread ordering as a proxy for CU assignment:
  CU k := threads[4*k + 0 .. 4*k + 3]
    """

    def __init__(self):
        super().__init__("reg", gdb.COMMAND_DATA)

    def invoke(self, arg, from_tty):
        argv = gdb.string_to_argv(arg)
        out_path, argv = _parse_out_arg(argv)
        wout = _TeeWriter(out_path)
        if not argv:
            wout.write("Usage: reg <expr> [--max-cu N] [--cu ID]... [--wave W|W0-W1|W0,W1,...] [--hex|--dec] [--fp16|--bf16|--fp32] [--lane N] [--show-err] [--debug] [--escape] [--out PATH]\n")
            wout.write("       reg --map [--out PATH]\n")
            wout.close()
            return

        # Print the autogen symbol->register table, if available.
        if len(argv) == 1 and argv[0] == "--map":
            sym2reg = getattr(gdb, "_roc_autogen_sym2reg", None)
            if not isinstance(sym2reg, dict) or not sym2reg:
                wout.write("reg --map: no autogen table found.\n")
                wout.write("Hint: source `rocgdb_utilities/rocgdb_autogen.gdb` and run `roc_autogen`/`roc_update` once.\n")
                wout.close()
                return

            rows = []
            for name, kv in sym2reg.items():
                try:
                    kind, idx = kv[0], int(kv[1])
                    reg = f"$s{idx}" if kind == "s" else (f"$v{idx}" if kind == "v" else "?")
                    rows.append((str(name), str(kind), str(idx), reg))
                except Exception:
                    rows.append((str(name), "?", "?", "?"))

            rows.sort(key=lambda x: x[0])
            w_name = max(len("name"), max(len(r[0]) for r in rows))
            w_kind = max(len("k"), 1)
            w_idx = max(len("idx"), max(len(r[2]) for r in rows))
            w_reg = max(len("reg"), max(len(r[3]) for r in rows))

            wout.write("reg: autogen symbol table (gdb._roc_autogen_sym2reg)\n")
            wout.write(_pad("name", w_name) + "  " + _pad("k", w_kind) + "  " + _pad("idx", w_idx) + "  " + _pad("reg", w_reg) + "\n")
            wout.write(_pad("-" * w_name, w_name) + "  " + _pad("-" * w_kind, w_kind) + "  " + _pad("-" * w_idx, w_idx) + "  " + _pad("-" * w_reg, w_reg) + "\n")
            for n, k, i, r in rows:
                wout.write(_pad(n, w_name) + "  " + _pad(k, w_kind) + "  " + _pad(i, w_idx) + "  " + _pad(r, w_reg) + "\n")
            wout.close()
            return

        expr = _normalize_reg_expr(argv[0])
        eval_expr = _rewrite_expr_via_autogen_map(expr)
        max_cu = None
        cu_filter = []  # list[int], if non-empty only show these CUs (in given order)
        # Default formatting:
        # - For register-like expressions ($sgpr*/$vgpr*/$sN/$vN), default to decimal integers.
        # - For other expressions, default to hex (useful for pointers/addresses).
        is_reg_like = (
            re.match(r"^\$(?:[sv]\d+)$", eval_expr) is not None
            or re.match(r"^\$(?:sgpr|vgpr)[A-Za-z_][A-Za-z0-9_]*(?:_[0-9]+)?$", expr) is not None
        )
        out_hex = (not is_reg_like)
        # If expr is a VGPR (vector register), default is to print ALL lanes.
        # Use --lane N to select a single lane.
        lane_idx = None
        lane_lo = None
        lane_hi = None
        show_err = False
        debug = False
        escape = False
        float_mode = None
        wave_cols = [0, 1, 2, 3]  # which wave columns to print (W0..W3)

        i = 1
        while i < len(argv):
            a = argv[i]
            if a == "--max-cu" and i + 1 < len(argv):
                try:
                    max_cu = int(argv[i + 1], 0)
                except Exception:
                    raise gdb.GdbError(f"reg: invalid --max-cu value: {argv[i+1]}")
                i += 2
                continue
            if a == "--cu" and i + 1 < len(argv):
                try:
                    cu_filter.append(int(argv[i + 1], 0))
                except Exception:
                    raise gdb.GdbError(f"reg: invalid --cu value: {argv[i+1]}")
                i += 2
                continue
            if a == "--hex":
                out_hex = True
                i += 1
                continue
            if a == "--dec":
                out_hex = False
                i += 1
                continue
            if a == "--fp16":
                float_mode = "fp16"
                i += 1
                continue
            if a == "--bf16":
                float_mode = "bf16"
                i += 1
                continue
            if a == "--fp32":
                float_mode = "fp32"
                i += 1
                continue
            if a == "--lane" and i + 1 < len(argv):
                s = argv[i + 1]
                try:
                    if "-" in s:
                        lo_s, hi_s = s.split("-", 1)
                        lane_lo = int(lo_s, 0)
                        lane_hi = int(hi_s, 0)
                        if lane_hi < lane_lo:
                            raise ValueError("lane range hi < lo")
                        lane_idx = None
                    else:
                        lane_idx = int(s, 0)
                        lane_lo = None
                        lane_hi = None
                except Exception:
                    raise gdb.GdbError(f"reg: invalid --lane value: {s} (use N or LO-HI)")
                i += 2
                continue
            if a == "--wave" and i + 1 < len(argv):
                s = argv[i + 1]
                picked = []

                def _add_w(v: int):
                    if v < 0 or v > 3:
                        raise ValueError("wave out of range")
                    if v not in picked:
                        picked.append(v)

                try:
                    # Accept:
                    #   --wave 2
                    #   --wave 0-3
                    #   --wave 0,2,3
                    for part in s.split(","):
                        part = part.strip()
                        if not part:
                            continue
                        if "-" in part:
                            lo_s, hi_s = part.split("-", 1)
                            lo = int(lo_s, 0)
                            hi = int(hi_s, 0)
                            if hi < lo:
                                raise ValueError("wave range hi < lo")
                            for v in range(lo, hi + 1):
                                _add_w(v)
                        else:
                            _add_w(int(part, 0))
                except Exception:
                    raise gdb.GdbError(f"reg: invalid --wave value: {s} (use W, LO-HI, or comma list; W in 0..3)")

                if not picked:
                    raise gdb.GdbError("reg: --wave requires at least one wave index (0..3)")
                wave_cols = picked
                i += 2
                continue
            if a == "--show-err":
                show_err = True
                i += 1
                continue
            if a == "--debug":
                debug = True
                i += 1
                continue
            if a == "--escape":
                # If set, do a one-time switch to a different CU before evaluating requested CUs.
                # This is a workaround for some ROCgdb sessions where switching within the same CU
                # from the current stop can yield stale/ERR register reads.
                escape = True
                i += 1
                continue
            raise gdb.GdbError(f"reg: unknown option: {a}")

        def _capture_in_current_thread(v):
            """
            Capture a thread-dependent gdb.Value into a thread-independent representation.

            Returns:
              - ("LANES", [str, ...]) for VGPR vectors when lane_idx is None
              - ("CELL", str) for scalars / lane-selected vectors
            """
            try:
                if lane_idx is None and _is_array_value(v):
                    if lane_lo is not None and lane_hi is not None:
                        lines, lo, hi = _format_lanes_range_u32(v, lane_lo, lane_hi, out_hex=out_hex, per_line=16, float_mode=float_mode)
                        return ("LANES", (lines, lo, hi))
                    # full lanes
                    try:
                        lo0, hi0 = v.type.range()
                        lo0, hi0 = int(lo0), int(hi0)
                    except Exception:
                        lo0, hi0 = 0, -1
                    return ("LANES", (_format_lanes_chunks_u32(v, out_hex=out_hex, per_line=16, float_mode=float_mode), lo0, hi0))
            except Exception:
                # Fall through to scalar formatting
                pass
            iv = _intish_value(v, lane_idx=lane_idx)
            return ("CELL", _u32_to_str(iv, out_hex=out_hex, float_mode=float_mode))

        def _dbg(msg: str):
            if debug:
                wout.write("[reg:debug] " + msg + "\n")

        def _thread_num(t):
            try:
                return int(getattr(t, "num", -1))
            except Exception:
                return -1

        def _frame_loc_str():
            try:
                f = gdb.selected_frame()
            except Exception:
                return "<no-frame>"
            try:
                sal = f.find_sal()
                if sal and sal.symtab:
                    try:
                        fn = sal.symtab.fullname()
                    except Exception:
                        fn = sal.symtab.filename
                    return f"{fn}:{getattr(sal, 'line', '?')}"
            except Exception:
                pass
            try:
                return f.name()
            except Exception:
                return "<unknown-frame>"

        inf = gdb.selected_inferior()
        threads = list(inf.threads())
        if not threads:
            wout.write("reg: no threads\n")
            wout.close()
            return

        # Map gdb thread num -> thread object
        num_to_thread = {}
        for t in threads:
            try:
                num_to_thread[int(getattr(t, "num", -1))] = t
            except Exception:
                continue

        # Preserve current thread selection
        try:
            cur_thread = gdb.selected_thread()
        except Exception:
            cur_thread = None
        _dbg(f"start: selected_thread={_thread_num(cur_thread) if cur_thread else None} loc={_frame_loc_str()}")

        # Parse `info threads` to discover (CU,slot)->thread mapping.
        try:
            out = gdb.execute("info threads", to_string=True)
        except (gdb.error, gdb.MemoryError) as e:
            wout.close()
            raise gdb.GdbError(f"reg: cannot run `info threads`: {e}")

        # Example line:
        #  1346 AMDGPU Wave 8:5:1:1022 (255,0,0)/1 "hipblaslt-bench"  label_openLoopL () at ...:1748
        # `info threads` marks the current thread with a leading '*', and some builds print
        # "Wave"/"wave" with different casing and optional spaces inside "(CU, 0, 0)/slot".
        # Accept these variants.
        pat = re.compile(
            r"^\s*\*?\s*(\d+)\s+AMDGPU\s+Wave\b.*\(\s*(\d+)\s*,\s*\d+\s*,\s*\d+\s*\)/\s*(\d+)\b",
            re.IGNORECASE,
        )

        # First collect per-CU slot mapping; slot numbers are not guaranteed to start at 0 or 1,
        # so we'll sort slots per CU and map the first 4 to W0..W3.
        # cu -> {slot: ("LANES",[...]) | ("CELL",str) | ("ERR",msg)}
        cu_to_slot_val = {}
        # tid -> cu (for the current-thread workaround below)
        tid_to_cu = {}
        seen = 0

        # Pre-parse all entries first. We'll optionally do an "escape" switch if requested.
        all_entries = []      # list[(tid, cu, slot, thread_obj)]
        wanted_entries = []   # filtered list used for evaluation
        for line in out.splitlines():
            m = pat.match(line)
            if not m:
                continue
            tid = int(m.group(1))
            cu = int(m.group(2))
            slot = int(m.group(3))
            t = num_to_thread.get(tid)
            if t is None:
                continue
            tid_to_cu[tid] = cu
            all_entries.append((tid, cu, slot, t))
            if (not cu_filter) or (cu in cu_filter):
                wanted_entries.append((tid, cu, slot, t))

        # Optional: escape to another CU first (explicit opt-in).
        if escape:
            try:
                if cur_thread is not None:
                    cur_tid = _thread_num(cur_thread)
                    cur_cu = tid_to_cu.get(cur_tid)
                    need_cus = set(cu_filter) if cu_filter else None
                    if cur_cu is not None and (need_cus is None or cur_cu in need_cus):
                        for _tid, _cu, _slot, _t in all_entries:
                            if _cu != cur_cu:
                                _dbg(f"escape: switching away from CU{cur_cu} to tid={_tid} CU{_cu} slot={_slot}")
                                _t.switch()
                                try:
                                    f = gdb.newest_frame()
                                    if f is not None:
                                        f.select()
                                except Exception:
                                    pass
                                _dbg(f"escape: now selected_thread={_thread_num(gdb.selected_thread())} loc={_frame_loc_str()}")
                                break
            except Exception as e:
                _dbg(f"escape: failed: {e}")

        for tid, cu, slot, t in wanted_entries:
            if cu not in cu_to_slot_val:
                cu_to_slot_val[cu] = {}
            # Evaluate expr in that thread context and immediately capture it into
            # a thread-independent representation (important for VGPR lane arrays).
            try:
                # Avoid an extra switch if we're already on this thread.
                if cur_thread is None or getattr(cur_thread, "num", None) != getattr(t, "num", None):
                    _dbg(f"switch: -> tid={tid} CU{cu} slot={slot}")
                    t.switch()
                # Be explicit about selecting a frame for the newly-selected thread. Some ROCgdb
                # sessions keep a stale frame selected across thread switches.
                try:
                    f = gdb.newest_frame()
                    if f is not None:
                        f.select()
                except Exception:
                    pass
                _dbg(f"eval: tid={tid} CU{cu} slot={slot} loc={_frame_loc_str()} expr={eval_expr}")
                v = gdb.parse_and_eval(eval_expr)
                cu_to_slot_val[cu][slot] = _capture_in_current_thread(v)
            except (gdb.error, gdb.MemoryError) as e:
                _dbg(f"ERR: tid={tid} CU{cu} slot={slot} err={e}")
                cu_to_slot_val[cu][slot] = ("ERR", str(e))
            seen += 1

        # Restore selection
        try:
            if cur_thread is not None:
                cur_thread.switch()
        except Exception:
            pass
        _dbg(f"end: restored selected_thread={_thread_num(gdb.selected_thread()) if cur_thread else None} loc={_frame_loc_str()}")

        if not cu_to_slot_val:
            wout.write("reg: could not parse AMDGPU CU/slot from `info threads`\n")
            wout.close()
            return

        # Limit / sort rows
        if cu_filter:
            # Preserve user-specified order; ignore CUs not present.
            present = set(cu_to_slot_val.keys())
            cu_list = [cu for cu in cu_filter if cu in present]
        else:
            cu_list = sorted(cu_to_slot_val.keys())
            if max_cu is not None:
                cu_list = cu_list[:max_cu]

        # Convert to fixed 4 columns by sorting slots per CU.
        cu_to_cols = {}
        for cu in cu_list:
            slots = sorted(cu_to_slot_val[cu].keys())
            cols = [None, None, None, None]
            for i in range(min(4, len(slots))):
                cols[i] = cu_to_slot_val[cu][slots[i]]
            cu_to_cols[cu] = cols

        def fmt_cell(captured):
            # None means "no wave/slot available for this CU+column" (not an evaluation error).
            if captured is None:
                return "NA"
            if isinstance(captured, tuple) and len(captured) == 2 and captured[0] == "ERR":
                return ("ERR:" + captured[1]) if show_err else "ERR"
            kind, payload = captured
            if kind == "CELL":
                return payload
            # If it's LANES here, it means user did not specify --lane; scalar table mode won't be used.
            return "ERR"

        rows = [(cu, [fmt_cell(x) for x in cu_to_cols[cu]]) for cu in cu_list]

        # If expr is VGPR (array) and no --lane was specified, print one wave per line (64 lanes on that line).
        any_array = (lane_idx is None) and any(
            (cu_to_cols.get(cu, [None, None, None, None])[j] is not None
             and isinstance(cu_to_cols[cu][j], tuple)
             and len(cu_to_cols[cu][j]) == 2
             and cu_to_cols[cu][j][0] == "LANES")
            for cu in cu_list for j in range(4)
        )

        mode_name = float_mode if float_mode is not None else ("hex" if out_hex else "dec")
        wout.write(f"reg: {expr} ({mode_name})\n")
        if any_array:
            wout.write("CU  W   lanes\n")
            wout.write("--  --  -----\n")
            for cu in cu_list:
                cols = cu_to_cols.get(cu, [None, None, None, None])
                for w in wave_cols:
                    captured = cols[w]
                    if captured is None:
                        wout.write(f"{cu:<3d} W{w} NA\n")
                    elif isinstance(captured, tuple) and len(captured) == 2 and captured[0] == "ERR":
                        msg = captured[1]
                        wout.write(f"{cu:<3d} W{w} " + ("ERR: " + msg if show_err else "ERR") + "\n")
                    elif isinstance(captured, tuple) and len(captured) == 2 and captured[0] == "LANES":
                        lines, lo0, hi0 = captured[1]
                        for li, s in enumerate(lines):
                            lo_lane = lo0 + li * 16
                            hi_lane = min(lo_lane + 15, hi0)
                            prefix = f"{cu:<3d} W{w}" if li == 0 else " " * 6
                            wout.write(f"{prefix} [{lo_lane:02d}-{hi_lane:02d}] {s}\n")
                    else:
                        # scalar (or lane-selected VGPR that got captured as CELL)
                        try:
                            if isinstance(captured, tuple) and captured[0] == "CELL":
                                wout.write(f"{cu:<3d} W{w} {captured[1]}\n")
                            else:
                                wout.write(f"{cu:<3d} W{w} ERR\n")
                        except Exception:
                            wout.write(f"{cu:<3d} W{w} ERR\n")
            wout.close()
            return

        # Scalar/table mode (SGPR or VGPR with --lane N)
        # (Use eval_expr so `$sgprFoo` rewritten to `$sN` is also treated as SGPR-like.)
        sgpr_like = (lane_idx is None) and (expr.startswith("$sgpr") or re.match(r"^\$s\d+$", eval_expr) is not None)
        if sgpr_like:
            # SGPR-like values are identical across the 4 waves on the same CU.
            # Print compactly: 16 CUs per line.
            entries = []  # list[(cu:int, val:str)]
            for cu, r in rows:
                v = "NA"
                for wi in wave_cols:
                    c = r[wi]
                    if c != "NA":
                        v = c
                        break
                entries.append((int(cu), v))

            cell_w = max(1, max(len(v) for _cu, v in entries)) if entries else 1
            per_line = 16
            for base in range(0, len(entries), per_line):
                chunk = entries[base:base + per_line]
                lo_cu = chunk[0][0]
                hi_cu = chunk[-1][0]
                wout.write(f"[{lo_cu}-{hi_cu}] " + "  ".join(_pad(v, cell_w) for _cu, v in chunk) + "\n")
            wout.close()
            return

        w0 = max(len("CU"), max(len(str(cu)) for cu in cu_list))
        headers = [f"W{w}" for w in wave_cols]
        col_w = [len(h) for h in headers]
        for _cu, r in rows:
            for j, wi in enumerate(wave_cols):
                col_w[j] = max(col_w[j], len(r[wi]))

        # Header
        line = _pad("CU", w0)
        for j, h in enumerate(headers):
            line += "  " + _pad(h, col_w[j])
        wout.write(line + "\n")
        line = _pad("-" * w0, w0)
        for j in range(len(headers)):
            line += "  " + _pad("-" * col_w[j], col_w[j])
        wout.write(line + "\n")

        # Rows
        for cu, r in rows:
            line = _pad(str(cu), w0)
            for j, wi in enumerate(wave_cols):
                line += "  " + _pad(r[wi], col_w[j])
            wout.write(line + "\n")
        wout.close()


RegCommand()


class SwCuCommand(gdb.Command):
    """swcu <cu> [w]

Switch to a wave on a given CU.

- <cu>: CU id (decimal/hex)
- [w]: wave index 0..3 (mapped by sorting the per-CU /slot values from `info threads`)

Examples:
  (gdb) swcu 0
  (gdb) swcu 0 2
"""

    def __init__(self):
        super().__init__("swcu", gdb.COMMAND_USER)

    def invoke(self, arg, from_tty):
        argv = gdb.string_to_argv(arg)
        if (not argv) or (len(argv) == 1 and argv[0] in ("--list", "-l")):
            try:
                out = gdb.execute("info threads", to_string=True)
            except (gdb.error, gdb.MemoryError) as e:
                raise gdb.GdbError(f"swcu: cannot run `info threads`: {e}")
            pat = re.compile(
                r"^\s*\*?\s*(\d+)\s+AMDGPU\s+Wave\b.*\(\s*(\d+)\s*,\s*\d+\s*,\s*\d+\s*\)/\s*(\d+)\b",
                re.IGNORECASE,
            )
            cus = set()
            for line in out.splitlines():
                m = pat.match(line)
                if not m:
                    continue
                cus.add(int(m.group(2)))
            if not cus:
                gdb.write("swcu: no AMDGPU CUs found in `info threads`\n")
                return
            cu_list = sorted(cus)
            gdb.write("swcu: available CUs in `info threads`:\n")
            gdb.write("  " + " ".join(str(x) for x in cu_list) + "\n")
            return
        try:
            cu = int(argv[0], 0)
        except Exception:
            raise gdb.GdbError(f"swcu: invalid cu: {argv[0]}")

        w = 0
        if len(argv) >= 2:
            try:
                w = int(argv[1], 0)
            except Exception:
                raise gdb.GdbError(f"swcu: invalid w: {argv[1]}")
        if w < 0 or w > 3:
            raise gdb.GdbError("swcu: w must be 0..3")

        try:
            out = gdb.execute("info threads", to_string=True)
        except (gdb.error, gdb.MemoryError) as e:
            raise gdb.GdbError(f"swcu: cannot run `info threads`: {e}")

        # Match AMDGPU wave lines (case-insensitive) and allow spaces inside "(CU, 0, 0)/slot".
        pat = re.compile(
            r"^\s*\*?\s*(\d+)\s+AMDGPU\s+Wave\b.*\(\s*(\d+)\s*,\s*\d+\s*,\s*\d+\s*\)/\s*(\d+)\b",
            re.IGNORECASE,
        )

        slots = []  # list[(slot:int, tid:int)]
        for line in out.splitlines():
            m = pat.match(line)
            if not m:
                continue
            tid = int(m.group(1))
            cu_id = int(m.group(2))
            slot = int(m.group(3))
            if cu_id == cu:
                slots.append((slot, tid))

        if not slots:
            # Include a hint of what CUs are present.
            cus = set()
            for line in out.splitlines():
                m = pat.match(line)
                if not m:
                    continue
                cus.add(int(m.group(2)))
            hint = ""
            if cus:
                cu_list = sorted(cus)
                hint = f" (available: {cu_list[0]}..{cu_list[-1]} , count={len(cu_list)}; try `swcu --list`)"
            raise gdb.GdbError(f"swcu: CU{cu} not found in `info threads`{hint}")

        slots.sort(key=lambda x: x[0])
        if w >= len(slots):
            raise gdb.GdbError(f"swcu: CU{cu} has only {len(slots)} wave(s) in `info threads`")

        slot, tid = slots[w]
        try:
            gdb.execute(f"thread {tid}", to_string=True)
        except gdb.error as e:
            raise gdb.GdbError(f"swcu: failed to switch to thread {tid} (CU{cu}/slot {slot}): {e}")

        # Select a fresh frame (helps in some ROCgdb sessions).
        try:
            f = gdb.newest_frame()
            if f is not None:
                f.select()
        except Exception:
            pass

        gdb.write(f"swcu: switched to CU{cu} W{w} (slot {slot}, thread {tid})\n")


SwCuCommand()

#
# Memory dump helpers (shared across kernels)
#   - lds <offset> [count] [hex|fp16|bf16|fp32]
#   - global <addr-expr> [count] [hex|fp16|bf16|fp32]
#   - global <addr-lo-expr> <addr-hi-expr> [count] [hex|fp16|bf16|fp32]
#

import struct
import math


def _mem_x_hex_values(cmd):
    """Run an `x/...` command and return (vals, err)."""
    try:
        out = gdb.execute(cmd, to_string=True)
    except (gdb.MemoryError, gdb.error) as e:
        return None, str(e)
    vals = []
    for line in out.splitlines():
        if ":" not in line:
            continue
        rhs = line.split(":", 1)[1]
        for tok in re.findall(r"0x[0-9a-fA-F]+", rhs):
            vals.append(int(tok, 16))
    return vals, None


def _mem_x_hex_values_try(cmds):
    last_err = None
    for c in cmds:
        vals, err = _mem_x_hex_values(c)
        if vals is not None:
            return vals, c, None
        last_err = err
    return None, None, last_err


def _mem_eval_u64(expr: str) -> int:
    v = gdb.parse_and_eval(expr)
    ull = gdb.lookup_type("unsigned long long")
    try:
        return int(v.cast(ull)) & ((1 << 64) - 1)
    except Exception:
        return int(v) & ((1 << 64) - 1)


def _mem_try_parse_int(s: str):
    try:
        return True, int(s, 0)
    except Exception:
        return False, None


def _half_to_float(h):
    # IEEE-754 binary16 -> float32
    s = (h >> 15) & 0x1
    e = (h >> 10) & 0x1F
    f = h & 0x3FF
    if e == 0:
        if f == 0:
            return -0.0 if s else 0.0
        return ((-1.0) ** s) * (f / 1024.0) * (2.0 ** (-14))
    if e == 31:
        if f == 0:
            return float("-inf") if s else float("inf")
        return float("nan")
    return ((-1.0) ** s) * (1.0 + f / 1024.0) * (2.0 ** (e - 15))


def _bf16_to_float(b):
    u = (int(b) & 0xFFFF) << 16
    return struct.unpack("<f", struct.pack("<I", u))[0]


def _fmt_float_cell(v, decimals=6):
    # Fixed decimals + reserved sign column (aligns columns visually)
    try:
        fv = float(v)
    except Exception:
        s = str(v)
        return (" " + s) if not s.startswith("-") else s

    if math.isnan(fv):
        return " nan"
    if math.isinf(fv):
        return " inf" if fv > 0 else "-inf"

    s = f"{fv:.{decimals}f}"
    return s if s.startswith("-") else (" " + s)


class _LdsCmd(gdb.Command):
    """Dump LDS (local address space): lds <offset> [count] [hex|fp16|bf16|fp32] [--out PATH]"""

    def __init__(self):
        super().__init__("lds", gdb.COMMAND_DATA)

    def invoke(self, arg, from_tty):
        argv = gdb.string_to_argv(arg)
        out_path, argv = _parse_out_arg(argv)
        wout = _TeeWriter(out_path)
        if len(argv) == 0:
            wout.write("Usage: lds <offset> [count] [hex|fp16|bf16|fp32] [--out PATH]\n")
            wout.close()
            return

        offset = int(argv[0], 0)
        count = int(argv[1], 0) if len(argv) >= 2 else 16
        fmt = argv[2].lower() if len(argv) >= 3 else "hex"

        if fmt == "hex":
            wout.write(gdb.execute(f"x/{count}wx local#{offset}", to_string=True))
            wout.close()
            return

        if fmt == "fp32":
            ws, err = _mem_x_hex_values(f"x/{count}wx local#{offset}")
            if ws is None or len(ws) < count:
                raise gdb.GdbError(f"Could not read {count} dwords from local#{offset}: {err}")
            vals = [struct.unpack("<f", struct.pack("<I", w & 0xFFFFFFFF))[0] for w in ws[:count]]
            per_line = 16
            decimals = 6
            for base in range(0, len(vals), per_line):
                chunk = vals[base : base + per_line]
                cells = [_fmt_float_cell(v, decimals=decimals) for v in chunk]
                w = max(len(c) for c in cells) if cells else 0
                wout.write(f"[{base:4d}-{base+len(chunk)-1:4d}] " + "  ".join(c.ljust(w) for c in cells) + "\n")
            wout.close()
            return

        if fmt in ("fp16", "bf16"):
            hs, err = _mem_x_hex_values(f"x/{count}hx local#{offset}")
            if hs is None or len(hs) < count:
                raise gdb.GdbError(f"Could not read {count} halfwords from local#{offset}: {err}")
            hs = [h & 0xFFFF for h in hs[:count]]
            conv = _half_to_float if fmt == "fp16" else _bf16_to_float
            vals = [conv(h) for h in hs]
            per_line = 16
            decimals = 3
            for base in range(0, len(vals), per_line):
                chunk = vals[base : base + per_line]
                cells = [_fmt_float_cell(v, decimals=decimals) for v in chunk]
                w = max(len(c) for c in cells) if cells else 0
                wout.write(f"[{base:4d}-{base+len(chunk)-1:4d}] " + "  ".join(c.ljust(w) for c in cells) + "\n")
            wout.close()
            return

        wout.close()
        raise gdb.GdbError(f"Unknown format: {fmt}. Use hex|fp16|bf16|fp32")


class _GlobalCmd(gdb.Command):
    """Dump global/generic memory:
  global <addr-expr> [count] [hex|fp16|bf16|fp32]
  global <addr-lo-expr> <addr-hi-expr> [count] [hex|fp16|bf16|fp32]
"""

    def __init__(self):
        super().__init__("global", gdb.COMMAND_DATA)

    def invoke(self, arg, from_tty):
        argv = gdb.string_to_argv(arg)
        out_path, argv = _parse_out_arg(argv)
        wout = _TeeWriter(out_path)
        if len(argv) == 0:
            wout.write("Usage: global <addr-expr> [count] [hex|fp16|bf16|fp32] [--out PATH]\n")
            wout.write("   or: global <addr-lo-expr> <addr-hi-expr> [count] [hex|fp16|bf16|fp32] [--out PATH]\n")
            wout.close()
            return

        addr_expr = argv[0]
        count = 16
        fmt = "hex"
        hi_expr = None

        if len(argv) >= 2:
            ok, v = _mem_try_parse_int(argv[1])
            if ok:
                count = v
                if len(argv) >= 3:
                    fmt = argv[2].lower()
            else:
                hi_expr = argv[1]
                if len(argv) >= 3:
                    ok2, v2 = _mem_try_parse_int(argv[2])
                    if ok2:
                        count = v2
                        if len(argv) >= 4:
                            fmt = argv[3].lower()
                    else:
                        fmt = argv[2].lower()

        # Normalize/rewrite register-like expressions so users can omit '$' and can use
        # `sgprFoo+1` as a shorthand for `sgprFoo_1` (register index offset).
        addr_expr = _rewrite_expr_via_autogen_map(_normalize_reg_expr(addr_expr))
        if hi_expr is not None:
            hi_expr = _rewrite_expr_via_autogen_map(_normalize_reg_expr(hi_expr))
            lo_expr = addr_expr
            # Use 64-bit math; user may write `$lo+16` etc.
            addr_u64 = (((_mem_eval_u64(hi_expr) & 0xFFFFFFFF) << 32) | (_mem_eval_u64(lo_expr) & 0xFFFFFFFF)) & ((1 << 64) - 1)
            addr_for_x = f"global#{addr_u64:#x}"
            addr_for_x_fallback = f"generic#{addr_u64:#x}"
        else:
            # Preserve ROCgdb tagging by letting it evaluate the expression directly.
            addr_u64 = _mem_eval_u64(addr_expr)
            addr_for_x = addr_expr
            addr_for_x_fallback = addr_expr

        if fmt == "hex":
            try:
                wout.write(gdb.execute(f"x/{count}wx {addr_for_x}", to_string=True))
            except (gdb.MemoryError, gdb.error):
                wout.write(gdb.execute(f"x/{count}wx {addr_for_x_fallback}", to_string=True))
            wout.close()
            return

        if fmt == "fp32":
            ws, _used, err = _mem_x_hex_values_try([f"x/{count}wx {addr_for_x}", f"x/{count}wx {addr_for_x_fallback}"])
            if ws is None or len(ws) < count:
                raise gdb.GdbError(f"Cannot access global memory at {addr_for_x} (value {addr_u64:#x}): {err}")
            ws = ws[:count]
            vals = [struct.unpack("<f", struct.pack("<I", w & 0xFFFFFFFF))[0] for w in ws]
            per_line = 16
            decimals = 6
            for base in range(0, len(vals), per_line):
                chunk = vals[base : base + per_line]
                cells = [_fmt_float_cell(v, decimals=decimals) for v in chunk]
                w = max(len(c) for c in cells) if cells else 0
                wout.write(f"[{base:4d}-{base+len(chunk)-1:4d}] " + "  ".join(c.ljust(w) for c in cells) + "\n")
            wout.close()
            return

        if fmt in ("fp16", "bf16"):
            hs, _used, err = _mem_x_hex_values_try([f"x/{count}hx {addr_for_x}", f"x/{count}hx {addr_for_x_fallback}"])
            if hs is None or len(hs) < count:
                raise gdb.GdbError(f"Cannot access global memory at {addr_for_x} (value {addr_u64:#x}): {err}")
            hs = [h & 0xFFFF for h in hs[:count]]
            conv = _half_to_float if fmt == "fp16" else _bf16_to_float
            vals = [conv(h) for h in hs]
            per_line = 16
            decimals = 3
            for base in range(0, len(vals), per_line):
                chunk = vals[base : base + per_line]
                cells = [_fmt_float_cell(v, decimals=decimals) for v in chunk]
                w = max(len(c) for c in cells) if cells else 0
                wout.write(f"[{base:4d}-{base+len(chunk)-1:4d}] " + "  ".join(c.ljust(w) for c in cells) + "\n")
            wout.close()
            return

        wout.close()
        raise gdb.GdbError(f"Unknown format: {fmt}. Use hex|fp16|bf16|fp32")


_LdsCmd()
_GlobalCmd()
end


