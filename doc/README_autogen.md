## `rocgdb_autogen.gdb` (auto-generate convenience vars from Tensile `.s`)

This script parses Tensile AMDGPU assembly (`.s`) **at the current stop location** and dynamically (re)defines a `roc_update` command that refreshes convenience variables like:

- `$sgprAddressB`, `$vgprSerial`
- indexed variants like `$sgprSrdB_0`, `$vgprGlobalReadOffsetB_11`

### Setup (ROCgdb)

Source once per debug session:

```gdb
source rocgdb_utilities/rocgdb_autogen.gdb
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

- **Full-file mode (optional)**:
  Tensile sometimes redefines `.set` symbols later in the file (e.g. resetting offsets).
  Default behavior is stop-line-aware; if you want the “last definition in the file” view:

```gdb
roc_autogen --full
roc_autogen_enable --full
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
{ "text": "source rocgdb_utilities/rocgdb_autogen.gdb" }
```


