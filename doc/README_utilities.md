## `rocgdb_utilities.gdb` (dump LDS / global / registers)

### Setup

See the top-level quick start in [`../README.md`](../README.md) (VSCode `setupCommands` or manual `source`).

### LDS / Global memory dump helpers

`rocgdb_utilities.gdb` defines:

- **`lds`**: dump LDS (work-group local/shared memory, `local#...`)
- **`global`**: dump global/generic memory from an address (often a pointer in SGPRs)

Both support:

- **`fmt=hex`**: raw hex via `x/...` (fast)
- **`fmt=fp32`**: decoded float32, **6 decimals**
- **`fmt=fp16` / `bf16`**: decoded half/bfloat16, **3 decimals**

Output is **16 values per line**, columns aligned with a reserved sign column, separated by **two spaces**.

#### `lds` syntax

`lds <offset> [count] [fmt] [--out PATH]`

- **offset**: byte offset within LDS (`local#<offset>`)
- **count**: number of elements (default 16)
- **fmt**: `hex|fp16|bf16|fp32` (default `hex`)

Examples:

- `lds 0x200`
- `lds 0x200 64 fp16`
- `lds 0x0 256 bf16`
- `lds 0x100 32 fp32`
- `lds 0x200 64 fp16 --out /tmp/lds.txt`

#### `global` syntax

Two forms are supported:

- `global <addr-expr> [count] [fmt] [--out PATH]`
- `global <addr-lo-expr> <addr-hi-expr> [count] [fmt] [--out PATH]` (combine 2x32b into 64b)

Notes:

- `<addr-expr>` can be a register or expression (e.g. `$sgprAddressB`, `$sgprSrdB_0+16`).
- For the lo/hi form, both parts are expressions. The low part can include a **byte offset** (e.g. `$sgprSrdB_0+16`).

Examples:

- `global $sgprAddressB`
- `global $sgprAddressB 64 fp16`
- `global $sgprAddressB 16 fp32`
- `global $sgprAddressB_0 $sgprAddressB_1 16 fp32`
- `global $sgprSrdB_0+16 $sgprSrdB_1 1880 bf16`
- `global $sgprAddressB 64 fp16 --out /tmp/global.txt`

Byte-offset reminder:

- `+16` means **16 bytes**.
- If you want to offset by **N bf16/fp16 elements**, use `+(N*2)`.

### Per-CU 4-wave table helper (`reg`)

If your run maps **4 waves per CU**, ROCgdb `info threads` output includes the CU and per-CU wave slot like:

- `AMDGPU Wave ... (255,0,0)/1`

`reg` parses that and prints a **4-column table** where each row is one CU and the 4 columns are the 4 waves on that CU.

Examples:

```gdb
reg sgprWorkGroup0
reg sgprWorkGroup0 --max-cu 32
reg sgprWorkGroup0 --cu 255
reg v192 --cu 255
reg sgprWorkGroup0 --cu 0 --out /tmp/reg.txt
```

If you also source `rocgdb_utilities/src/rocgdb_autogen.gdb`, `reg` will automatically refresh the autogen map
for the **current stop location** before evaluating register names.

Shorthand for indexed registers:

- `sgprFoo+1` is treated as `sgprFoo_1` (i.e. register index +1), so `reg sgprSrdA+1` maps to `$s{sgprSrdA+1}`.
- Same for `vgprFoo+K`.

For SGPR-like scalar expressions (e.g. `$sgpr...` / `$sN`), `reg` prints **one value per CU** (the 4 waves on the same CU share SGPR values).
Output is **16 values per line**, prefixed by a CU range like `[0-15]` (the per-value CU index is omitted).

For VGPRs (lane-level values), add `--lane N` to pick which lane to display per wave:

```gdb
reg $v192 --max-cu 32 --dec           # default: prints 4 lines per wave, 16 lanes per line
reg $v192 --lane 0 --max-cu 32 --dec      # pick one lane
reg $v192 --lane 0-15 --max-cu 1 --dec    # pick a lane range (inclusive)
reg $v192 --max-cu 1 --dec --show-err # show error messages for ERR cells
reg $v192 --max-cu 1 --fp32           # interpret each 32b lane as 1x fp32
reg $v192 --max-cu 1 --fp16           # interpret each 32b lane as 2x fp16 (lo16,hi16)
reg $v192 --max-cu 1 --bf16           # interpret each 32b lane as 2x bf16 (lo16,hi16)
reg $v192 --bf16 --wave 2             # only show W2 per CU
reg $v192 --bf16 --wave 0,3           # only show W0 and W3
reg $v192 --bf16 --wave 1-2           # only show W1 and W2
```

### Print autogen symbol table (`reg --map`)

If you also source `rocgdb_utilities/src/rocgdb_autogen.gdb`, it exports a symbol→register mapping table.
You can print it to verify mappings like `sgprWorkGroup0 -> $sNN`:

```gdb
reg --map
reg --map --out /tmp/rocgdb_map.txt
```

### Switch to a specific CU wave (`swcu`)

Quickly switch the selected GPU wave to a specific CU:

```gdb
swcu --list   # list CUs currently present in `info threads`
swcu 0        # CU0, W0
swcu 0 2      # CU0, W2
```

### Compute LDS addresses per-lane (`addr`)

`addr` computes **per-CU / per-wave / per-lane** addresses for LDS ops at the current stop location.

Initial support:

- **`ds_read_*`**: address = `vaddr + offset`
- **`ds_write_*`**: address = `vaddr + offset`

#### `addr` syntax

Two typical forms:

- `addr` (infer op/vaddr/offset/bytes from the current `.s` line; requires you to be stopped on a `ds_read_*`/`ds_write_*` instruction line)
- `addr ds_read|ds_write <vaddr-expr> [--offset N] [--bytes N] ...` (override / don’t rely on source-line parsing)

Common filters / formatting:

- `--cu ID` (repeatable)
- `--max-cu N`
- `--wave 0-3` / `--wave 0,2`
- `--lane N` or `--lane LO-HI`
- `--hex` / `--dec`
- `--out PATH`

Examples:

```gdb
# Stopped at: ds_read_b128 ... v[vgprLocalReadAddrA] offset:0
addr

# Stopped at: ds_write_b128 v[vgprLocalWriteAddrB], ... offset:0
addr

# Explicit:
addr ds_read  vgprLocalReadAddrA  --offset 0 --bytes 16
addr ds_write vgprLocalWriteAddrB --offset 0 --bytes 16

# Only show CU0, waves W2/W3, lanes 0-15:
addr --cu 0 --wave 2-3 --lane 0-15
```


