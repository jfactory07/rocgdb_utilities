## `addr` — per-lane address calculator

### Syntax

```text
addr [ds_read|ds_write] [<vaddr-expr>]
     [--offset N] [--bytes N]
     [--cu ID]... [--max-cu N] [--wave W|W0-W1|W0,W1,...]
     [--lane N|LO-HI] [--hex|--dec] [--out PATH] [--debug]

addr [buffer_load|buffer_store] [<vaddr-expr>]
     --base <sgprSrdBase> [--soffset <expr>]
     [--offset N] [--bytes N]
     [--cu ID]... [--max-cu N] [--wave W|W0-W1|W0,W1,...]
     [--lane N|LO-HI] [--hex|--dec] [--out PATH] [--debug]
```

Notes:

- If you’re stopped on a Tensile `.s` line containing `ds_read_*`, `ds_write_*`, `buffer_load_*`, or `buffer_store_*`, you can run `addr` with **no args** and it will infer operands from the current source line.
- **`--base <sgprSrdBase>`** is the SRD base register name (lo dword). `addr` uses SRD\[0:1] as the 64-bit base: `srd[0]` = lo, `srd[1]` = hi.
- For `buffer_*` the computed address is:  
  `base64(SRD[0:1]) + vaddr + soffset + offset`

### Examples

```gdb
# LDS reads/writes (infer from current .s line):
addr

# LDS explicit:
addr ds_read  vgprLocalReadAddrA  --offset 0 --bytes 16
addr ds_write vgprLocalWriteAddrB --offset 0 --bytes 16

# buffer_load (offen), explicit:
addr buffer_load vgprGlobalReadOffsetA+0 --base sgprSrdA --soffset 0 --offset 0 --bytes 16

# buffer_store (offen), explicit:
addr buffer_store v11 --base sgprSrdD --soffset 0 --offset 0 --bytes 16

# Filter output:
addr --cu 0 --wave 2-3 --lane 0-15

# Just one lane (less spam):
addr buffer_load vgprGlobalReadOffsetA --base sgprSrdA --lane 0 --cu 0
```

