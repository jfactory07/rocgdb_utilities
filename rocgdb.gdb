# ROCgdb entrypoint (single-source convenience)
#
# This file just sources the two scripts in this folder so you only need:
#   (gdb) source rocgdb_utilities/rocgdb.gdb
#
# Note: paths are relative to your current working directory in gdb.
# We intentionally keep them as `rocgdb_utilities/...` for portability.

source rocgdb_utilities/src/rocgdb_autogen.gdb
source rocgdb_utilities/src/rocgdb_utilities.gdb


