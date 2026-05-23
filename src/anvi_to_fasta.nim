## anvi-to-fasta — export contigs / collection bins from anvi'o databases.
##
## Usage:
##   anvi-to-fasta [options] CONTIGS.db
##   anvi-to-fasta [options] CONTIGS.db -p PROFILE.db -c COLLECTION [-b BIN]
##
## Without a profile database every contig in CONTIGS.db is exported.
## With a profile database, collections and bins can be selected.

import argparse, os, strutils, sequtils
import anvio

const VERSION = "0.1.0"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

proc openOutputFile(path: string): File =
  var f: File
  if not open(f, path, fmWrite):
    stderr.writeLine("Error: cannot open output file for writing: " & path)
    quit(1)
  f

proc binFileName(collection, bin, separator: string): string =
  collection & separator & bin & ".fasta"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

proc main() =
  let p = newParser:
    help("Export contigs and bins from anvi'o databases as FASTA.\n\n" &
         "Without -p/--profile, all contigs in CONTIGS.db are exported.\n" &
         "With -p PROFILE.db, use -c/-b/-a to select collections or bins.")
    arg("contigs_db", help = "Path to anvi'o contigs database (CONTIGS.db)")

    option("-p", "--profile",
           help = "Path to anvi'o profile database (PROFILE.db)")
    option("-o", "--output",
           help = "Write FASTA to FILE instead of stdout")
    option("-d", "--dir",
           help = "Output directory for per-bin files")

    flag("-l", "--list",
         help = "List available collections and bins, then exit (requires PROFILE.db)")
    option("-c", "--collection",
           help = "Export contigs from this collection (requires PROFILE.db)")
    option("-b", "--bin",
           help = "Export only this bin (requires --collection)")
    flag("-a", "--all",
         help = "Export every collection x every bin as separate files (requires --dir)")

    option("-s", "--separator",  default = some("__"),
           help = "Separator between collection and bin name in output filenames [default: __]")
    option("--min-length",       default = some("0"),
           help = "Skip contigs shorter than INT bp [default: 0]")
    option("--prefix",
           help = "Prefix prepended to every sequence header (verbatim — include any trailing separator, e.g. --prefix mybin_)")

  var opts: typeof(p.parse(@[]))
  try:
    opts = p.parse(commandLineParams())
  except ShortCircuit as e:
    if e.flag == "argparse_help":
      echo p.help
      quit(0)
    raise
  except UsageError as e:
    stderr.writeLine("Error: " & e.msg)
    quit(1)

  # ------------------------------------------------------------------
  # Validate and open databases
  # ------------------------------------------------------------------

  let minLength = parseInt(opts.min_length)
  let prefix    = opts.prefix
  let separator = opts.separator

  let contigsDb = openContigsDb(opts.contigs_db)

  let hasProfile = opts.profile.len > 0
  var profileDb: AnvioDb
  if hasProfile:
    profileDb = openProfileDb(opts.profile)

  # ------------------------------------------------------------------
  # Mutual-exclusion and dependency checks
  # ------------------------------------------------------------------

  if opts.list and not hasProfile:
    stderr.writeLine("Error: --list requires a PROFILE.db.")
    quit(1)

  if opts.collection.len > 0 and not hasProfile:
    stderr.writeLine("Error: --collection requires a PROFILE.db.")
    quit(1)

  if opts.bin.len > 0 and opts.collection.len == 0:
    stderr.writeLine("Error: --bin requires --collection.")
    quit(1)

  if opts.all and not hasProfile:
    stderr.writeLine("Error: --all requires a PROFILE.db.")
    quit(1)

  if opts.all and opts.dir.len == 0:
    stderr.writeLine("Error: --all requires --dir.")
    quit(1)

  if opts.all and opts.collection.len > 0:
    stderr.writeLine("Error: --all and --collection are mutually exclusive.")
    quit(1)

  if opts.output.len > 0 and opts.dir.len > 0:
    stderr.writeLine("Error: --output and --dir are mutually exclusive.")
    quit(1)

  # ------------------------------------------------------------------
  # --list: print collections and exit
  # ------------------------------------------------------------------

  if opts.list:
    let collections = listCollections(profileDb)
    if collections.len == 0:
      echo "No collections found in " & profileDb.path
    else:
      for col in collections:
        echo col.name & "  (" & $col.numBins & " bins)"
        for b in col.binNames:
          echo "  - " & b
    quit(0)

  # ------------------------------------------------------------------
  # No profile: export all contigs
  # ------------------------------------------------------------------

  if not hasProfile:
    let output = if opts.output.len > 0: openOutputFile(opts.output) else: stdout
    writeAllContigs(contigsDb, output, minLength, prefix)
    if opts.output.len > 0: close(output)
    quit(0)

  # ------------------------------------------------------------------
  # --all: export every collection × every bin to --dir
  # ------------------------------------------------------------------

  if opts.all:
    createDir(opts.dir)
    for col in listCollections(profileDb):
      for bin in col.binNames:
        let fpath = opts.dir / binFileName(col.name, bin, separator)
        let f = openOutputFile(fpath)
        writeBinContigs(profileDb, contigsDb, col.name, bin, f, minLength, prefix)
        close(f)
        echo "Wrote " & fpath
    quit(0)

  # ------------------------------------------------------------------
  # --collection [--bin]: export one collection or one specific bin
  # ------------------------------------------------------------------

  if opts.collection.len > 0:
    if not hasCollection(profileDb, opts.collection):
      stderr.writeLine("Error: collection '" & opts.collection &
                       "' not found in " & profileDb.path & ".")
      stderr.writeLine("Use --list to see available collections.")
      quit(1)

    # Single bin
    if opts.bin.len > 0:
      if not hasBin(profileDb, opts.collection, opts.bin):
        stderr.writeLine("Error: bin '" & opts.bin & "' not found in collection '" &
                         opts.collection & "'.")
        stderr.writeLine("Use --list to see available bins.")
        quit(1)

      let output = if opts.output.len > 0: openOutputFile(opts.output) else: stdout
      writeBinContigs(profileDb, contigsDb, opts.collection, opts.bin,
                      output, minLength, prefix)
      if opts.output.len > 0: close(output)
      quit(0)

    # All bins in the collection
    let collections = listCollections(profileDb)
    let colInfo = collections.filterIt(it.name == opts.collection)[0]

    if opts.dir.len > 0:
      # One file per bin under --dir
      createDir(opts.dir)
      for bin in colInfo.binNames:
        let fpath = opts.dir / binFileName(opts.collection, bin, separator)
        let f = openOutputFile(fpath)
        writeBinContigs(profileDb, contigsDb, opts.collection, bin, f, minLength, prefix)
        close(f)
        echo "Wrote " & fpath
    else:
      # Merge all bins into one stream; embed bin name in each header
      let output = if opts.output.len > 0: openOutputFile(opts.output) else: stdout
      for bin in colInfo.binNames:
        let binPrefix = bin & separator & prefix
        writeBinContigs(profileDb, contigsDb, opts.collection, bin,
                        output, minLength, binPrefix)
      if opts.output.len > 0: close(output)

    quit(0)

  # ------------------------------------------------------------------
  # Profile given but no collection selected: export all contigs
  # ------------------------------------------------------------------

  let output = if opts.output.len > 0: openOutputFile(opts.output) else: stdout
  writeAllContigs(contigsDb, output, minLength, prefix)
  if opts.output.len > 0: close(output)

main()
