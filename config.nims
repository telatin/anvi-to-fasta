# Override niqlite's default SQLITE_CFLAGS which uses -O3.
# -O2 is sufficient and avoids potential LTO-related linker issues on macOS.
when defined(macosx):
  switch("define", "SQLITE_CFLAGS=-DSQLITE_ENABLE_FTS5 -O2")
