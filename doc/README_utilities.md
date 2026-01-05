## `rocgdb_utilities.gdb` docs

### Setup

See the top-level quick start in [`../README.md`](../README.md) (VSCode `setupCommands` or manual `source`).

### Command docs (one file per command)

- **`addr`**: per-CU / per-wave / per-lane address calculator  
  See [`commands/addr.md`](commands/addr.md)
- **`reg`**: per-CU 4-wave register table (`reg --map` for autogen map)  
  See [`commands/reg.md`](commands/reg.md)
- **`swcu`**: switch to a specific CU wave  
  See [`commands/swcu.md`](commands/swcu.md)
- **`lds`**: dump LDS (`local#...`)  
  See [`commands/lds.md`](commands/lds.md)
- **`global`**: dump global/generic memory (supports lo/hi → 64-bit)  
  See [`commands/global.md`](commands/global.md)

### Shared formatting notes

- **`lds/global` float decoding**: `fp32` prints **6 decimals**, `fp16/bf16` prints **3 decimals**.
- **Output alignment**: values are aligned with a reserved sign column; columns use **two spaces**.