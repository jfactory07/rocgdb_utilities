## ROCgdb convenience helpers (Tensile asm `.s`)

This folder contains ROCgdb helper scripts to make Tensile AMDGPU assembly debugging easier.

### Docs (split by script)

- **Autogen convenience vars** (`src/rocgdb_autogen.gdb`): see [`doc/README_autogen.md`](doc/README_autogen.md)
- **Dump LDS / global / registers** (`src/rocgdb_utilities.gdb`): see [`doc/README_utilities.md`](doc/README_utilities.md)

### Quick start (source two scripts)

```gdb
# If you are in hipblaslt workspace root:
source utilities/rocgdb_utilities/src/rocgdb_autogen.gdb
source utilities/rocgdb_utilities/src/rocgdb_utilities.gdb

# If your `pwd` has a sibling folder named `rocgdb_utilities/`:
# source rocgdb_utilities/src/rocgdb_autogen.gdb
# source rocgdb_utilities/src/rocgdb_utilities.gdb

# If you `cd` into the rocgdb_utilities repo root:
# source src/rocgdb_autogen.gdb
# source src/rocgdb_utilities.gdb
```

<img width="474" height="295" alt="image" src="https://github.com/user-attachments/assets/c4ed3fc3-b598-4c4c-98e0-5ae52c4ece53" />

