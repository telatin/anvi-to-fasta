# Package
version     = "0.1.0"
author      = "telatina"
description = "Export contigs and bins from anvi'o databases as FASTA"
license     = "GPL-3.0"
srcDir      = "src"
bin         = @["anvi_to_fasta"]

# Dependencies
requires "nim >= 2.0.0"
requires "argparse >= 4.0.0"
# SQLite is bundled as src/sqlite3.c (public domain amalgamation).
# No system libsqlite3 required; the binary is fully static.

# Rename the binary to use the conventional hyphenated name after build.
# nimble forbids dashes in package names but the installed binary can be named freely.
after build:
  exec "test -f anvi_to_fasta && mv anvi_to_fasta anvi-to-fasta || true"

task test, "Run smoke tests against test databases":
  exec "./anvi-to-fasta tests/data/CONTIGS.db > /dev/null"
  exec "./anvi-to-fasta tests/data/CONTIGS.db -p tests/data/PROFILE.db --list > /dev/null"
  exec "./anvi-to-fasta tests/data/CONTIGS.db -p tests/data/PROFILE.db -c default -b Bin_1 > /dev/null"
  echo "All smoke tests passed."
