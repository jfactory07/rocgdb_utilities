## `lds` — dump LDS (local address space)

### Syntax

```text
lds <offset> [count] [hex|fp8|fp8e4m3fn|fp8e5m2|fp16|bf16|fp32] [--out PATH]
```

Arguments:

- **`offset`**: byte offset within LDS (`local#<offset>`)
- **`count`**: number of elements (default `16`)
- **format**: `hex|fp16|bf16|fp32` (default `hex`)
- **`--out PATH`**: append output to a file

### Examples

```gdb
lds 0x200
lds 0x200 64 fp8
lds 0x200 64 fp8e4m3fn
lds 0x200 64 fp8e5m2
lds 0x200 64 fp16
lds 0x0 256 bf16
lds 0x100 32 fp32
lds 0x200 64 fp16 --out /tmp/lds.txt
```

