## `rocgdb_autogen.gdb` (auto-generate convenience vars from Tensile `.s`)

This script parses Tensile AMDGPU assembly (`.s`) **at the current stop location** and dynamically (re)defines a `roc_update` command that refreshes convenience variables like:

- `$sgprAddressB`, `$vgprSerial`
- indexed variants like `$sgprSrdB_0`, `$vgprGlobalReadOffsetB_11`

### Setup (ROCgdb)

Source once per debug session:

```gdb
source /mnt/rocm-libraries-dev/rocm-libraries/projects/hipblaslt/utilities/rocgdb/rocgdb_autogen.gdb
```

That’s it.

- The file installs a **one-shot** stop handler: on the *first* stop after sourcing, it enables auto-generation for subsequent stops.
- Auto-generation uses `gdb.events.stop` (so it does **not** conflict with VSCode’s own `hook-stop` usage).

### Manual control (optional)

- **Enable** (if you want to do it explicitly):

```gdb
roc_autogen_enable
```

- **Force regenerate on this stop**:

```gdb
roc_autogen --force
```

### Using the variables

Once you stop inside a Tensile `.s` frame:

```gdb
p/x $sgprAddressB
p/x $vgprGlobalReadOffsetB_11
```

### VSCode setup (`launch.json`)

Add this to `setupCommands` so the script is always available:

```json
{ "text": "source /mnt/rocm-libraries-dev/rocm-libraries/projects/hipblaslt/utilities/rocgdb/rocgdb_autogen.gdb" }
```


