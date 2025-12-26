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

#### Sanity check (see commands in `help`)

After sourcing, you should see these commands under `help user-defined`:

```text
User-defined commands.
The commands in this class are those defined by the user.
Use the "define" command to define a command.

List of commands:

global -- Dump global/generic memory:
lds -- Dump LDS (local address space): lds <offset> [count] [hex|fp16|bf16|fp32] [--out PATH]
reg -- reg <expr> [--max-cu N] [--cu ID]... [--wave W|W0-W1|W0,W1,...] [--hex|--dec] [--fp16|--bf16|--fp32] [--lane N] [--show-err]
roc_autogen -- Auto-generate and source per-kernel convenience variables based on current asm stop location.
roc_autogen_enable -- Enable auto-generation by running roc_autogen on every stop (via gdb.events.stop).
roc_update -- User-defined.
swcu -- swcu <cu> [w]

Type "help" followed by command name for full documentation.
Type "apropos word" to search for commands related to "word".
Type "apropos -v word" for full documentation of commands related to "word".
Command name abbreviations are allowed if unambiguous.
```

#### Screenshot(output of `reg`)

<img width="1257" height="171" alt="image" src="https://github.com/user-attachments/assets/6caef83d-c1ab-4790-9773-64a321594971" />


