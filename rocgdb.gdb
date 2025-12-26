#
# Convenience wrapper for when your GDB `pwd` is the `rocgdb_utilities` repo root:
#
#   (gdb) pwd
#   .../rocgdb_utilities
#   (gdb) source rocgdb.gdb
#
# If you are not in this repo root (e.g. you are in hipblaslt workspace root),
# prefer sourcing the two scripts via absolute paths (VSCode `${workspaceFolder}`
# is perfect for that).

source src/rocgdb_autogen.gdb
source src/rocgdb_utilities.gdb


