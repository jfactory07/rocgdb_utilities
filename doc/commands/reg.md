## `reg` — per-CU 4-wave register table

### Syntax

```text
reg <expr>
    [--max-cu N] [--cu ID]...
    [--wave W|W0-W1|W0,W1,...]
    [--hex|--dec]
    [--fp16|--bf16|--fp32]
    [--lane N|LO-HI]
    [--show-err]
    [--debug] [--escape]
    [--out PATH]

reg --map [--out PATH]
```

Notes:

- `reg` parses ROCgdb `info threads` output (CU + per-CU wave slot) and prints a **4-column table** (W0..W3) per CU.
- If `rocgdb_autogen.gdb` is also sourced, `reg` refreshes the autogen symbol map at the current stop location.
- Shorthand for indexed registers:
  - `sgprFoo+1` is treated as `sgprFoo_1` (register index +1)
  - same for `vgprFoo+K`
- VGPRs default to printing **all lanes** (grouped). Use `--lane` to select a single lane or a lane range.

### Examples

```gdb
# SGPR-like
reg sgprWorkGroup0
reg sgprWorkGroup0 --max-cu 32
reg sgprWorkGroup0 --cu 255
reg sgprWorkGroup0 --cu 0 --out /tmp/reg.txt

# VGPR lanes
reg $v192 --max-cu 1 --dec           # prints lane blocks
reg $v192 --lane 0 --max-cu 32 --dec # pick one lane
reg $v192 --lane 0-15 --max-cu 1 --dec

# Interpret lane bits
reg $v192 --max-cu 1 --fp32
reg $v192 --max-cu 1 --fp16
reg $v192 --max-cu 1 --bf16
reg $v192 --bf16 --wave 2

# Autogen symbol map
reg --map
reg --map --out /tmp/rocgdb_map.txt
```

