## `swcu` — switch to a specific CU wave

### Syntax

```text
swcu --list
swcu <cu> [w]
```

Notes:

- `<cu>`: CU id (decimal/hex)
- `[w]`: wave index `0..3` (mapped by sorting the per-CU `/slot` values from `info threads`)

### Examples

```gdb
swcu --list   # list CUs present in `info threads`
swcu 0        # CU0, W0
swcu 0 2      # CU0, W2
```

