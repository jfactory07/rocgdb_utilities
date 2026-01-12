## `global` — dump global/generic memory

### Syntax

Two forms:

```text
global <addr-expr> [count] [hex|fp8|fp8e4m3fn|fp8e5m2|fp16|bf16|fp32] [--out PATH]
global <addr-lo-expr> <addr-hi-expr> [count] [hex|fp8|fp8e4m3fn|fp8e5m2|fp16|bf16|fp32] [--out PATH]
```

Notes:

- `<addr-expr>` can be a register or expression (e.g. `$sgprAddressB`, `$sgprSrdB_0+16`).
- For the lo/hi form, `addr = (hi<<32) | lo` (both are evaluated as 32-bit).
- `+16` means **16 bytes**; for N fp16/bf16 elements, use `+(N*2)`.

### Examples

```gdb
global $sgprAddressB
global $sgprAddressB 64 fp8
global $sgprAddressB 64 fp8e4m3fn
global $sgprAddressB 64 fp8e5m2
global $sgprAddressB 64 fp16
global $sgprAddressB 16 fp32
global $sgprAddressB_0 $sgprAddressB_1 16 fp32
global $sgprSrdB_0+16 $sgprSrdB_1 1880 bf16
global $sgprAddressB 64 fp16 --out /tmp/global.txt
```

