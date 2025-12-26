## ROCgdb convenience helpers (Tensile asm `.s`)

This folder contains ROCgdb helper scripts to make Tensile AMDGPU assembly debugging easier.

### Docs (split by script)

- **Autogen convenience vars** (`src/rocgdb_autogen.gdb`): see [`doc/README_autogen.md`](doc/README_autogen.md)
- **Dump LDS / global / registers** (`src/rocgdb_utilities.gdb`): see [`doc/README_utilities.md`](doc/README_utilities.md)

### Quick start (source two scripts)

#### VSCode (`launch.json`)

Add these entries to your `setupCommands`:

```json
{
  "description": "ROCgdb autogen (.set → register map) + utilities (reg/lds/global/swcu)",
  "text": "source ${workspaceFolder}/rocgdb_utilities/src/rocgdb_autogen.gdb",
  "ignoreFailures": false
},
{
  "description": "ROCgdb utilities (reg/lds/global/swcu)",
  "text": "source ${workspaceFolder}/rocgdb_utilities/src/rocgdb_utilities.gdb",
  "ignoreFailures": false
}
```

#### ROCgdb (manual)

```gdb

# If your current `pwd` has a sibling folder named `rocgdb_utilities/`:
# source rocgdb_utilities/src/rocgdb_autogen.gdb
# source rocgdb_utilities/src/rocgdb_utilities.gdb

# If you `cd` into the rocgdb_utilities repo root:
# source src/rocgdb_autogen.gdb
# source src/rocgdb_utilities.gdb
```

<img width="1257" height="171" alt="image" src="https://github.com/user-attachments/assets/6caef83d-c1ab-4790-9773-64a321594971" />


