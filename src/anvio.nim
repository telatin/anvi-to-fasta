## anvio.nim — reusable utilities for reading anvi'o SQLite databases.
##
## Supports contigs-db and profile-db. Opening a database validates both
## the db_type field (guards against swapped arguments) and the schema
## version (warns when an untested version is encountered).

import niqlite, strutils, sequtils

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  DbKind* = enum
    dkContigs = "contigs"
    dkProfile = "profile"

  AnvioDb* = object
    path*: string
    kind*: DbKind
    version*: int
    db*: SqliteDatabase

  CollectionInfo* = object
    name*: string
    numBins*: int
    binNames*: seq[string]

# ---------------------------------------------------------------------------
# Supported schema versions.
# Add new versions here after verifying that the tables we use
# (contig_sequences, splits_basic_info, collections_of_splits,
#  collections_info) still carry the same columns.
# ---------------------------------------------------------------------------

const SUPPORTED_CONTIGS_DB_VERSIONS* = [24]
const SUPPORTED_PROFILE_DB_VERSIONS* = [40, 41, 42]

const FASTA_LINE_WIDTH* = 60

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc sqlEsc*(s: string): string =
  ## Escape a value for embedding in a SQL single-quoted literal.
  s.replace("'", "''")

proc wrapSequence*(s: string, width = FASTA_LINE_WIDTH): string =
  ## Break a bare sequence string into lines of `width` characters.
  var parts: seq[string]
  var i = 0
  while i < s.len:
    parts.add(s[i ..< min(i + width, s.len)])
    i += width
  parts.join("\n")

proc formatVersionList(versions: openArray[int]): string =
  "[" & versions.mapIt($it).join(", ") & "]"

# ---------------------------------------------------------------------------
# Database opening and validation
# ---------------------------------------------------------------------------

proc openAnvioDb*(path: string, expectedKind: DbKind): AnvioDb =
  ## Open an anvi'o SQLite database, validate its type and schema version.
  ## Exits with an error message when the db_type does not match.
  ## Prints a warning (and continues) when the version is not in the
  ## tested list.
  let db = niqlite.newSqliteDatabase(path)

  var foundKind: DbKind
  var foundVersion: int

  var stmt = db.newSqliteStatement(
    "SELECT key, value FROM self WHERE key IN ('db_type', 'version')")
  while stmt.step() == SQLITE_ROW:
    case stmt.columnText(0)
    of "db_type":
      let t = stmt.columnText(1)
      case t
      of "contigs": foundKind = dkContigs
      of "profile": foundKind = dkProfile
      else:
        stderr.writeLine("Error: unknown db_type '" & t & "' in " & path)
        quit(1)
    of "version":
      foundVersion = parseInt(stmt.columnText(1))

  if foundKind != expectedKind:
    stderr.writeLine("Error: expected a '" & $expectedKind &
                     "' database but '" & path &
                     "' has db_type='" & $foundKind & "'.")
    stderr.writeLine("Hint: check that you passed CONTIGS.db and PROFILE.db in the right order.")
    quit(1)

  let supported: seq[int] = case expectedKind
    of dkContigs: @SUPPORTED_CONTIGS_DB_VERSIONS
    of dkProfile: @SUPPORTED_PROFILE_DB_VERSIONS

  if foundVersion notin supported:
    stderr.writeLine("Warning: " & $expectedKind & " database version " &
                     $foundVersion & " is not in the tested list " &
                     formatVersionList(supported) &
                     ". Proceeding, but results may be unexpected.")

  AnvioDb(path: path, kind: foundKind, version: foundVersion, db: db)

proc openContigsDb*(path: string): AnvioDb =
  openAnvioDb(path, dkContigs)

proc openProfileDb*(path: string): AnvioDb =
  openAnvioDb(path, dkProfile)

# ---------------------------------------------------------------------------
# Collection queries (profile-db)
# ---------------------------------------------------------------------------

proc listCollections*(profileDb: AnvioDb): seq[CollectionInfo] =
  ## Return all collections stored in a profile database.
  result = @[]
  var stmt = profileDb.db.newSqliteStatement(
    "SELECT collection_name, num_bins, bin_names " &
    "FROM collections_info ORDER BY collection_name")
  while stmt.step() == SQLITE_ROW:
    result.add(CollectionInfo(
      name:     stmt.columnText(0),
      numBins:  stmt.columnInt(1),
      binNames: stmt.columnText(2).split(",")))

proc hasCollection*(profileDb: AnvioDb, collection: string): bool =
  var stmt = profileDb.db.newSqliteStatement(
    "SELECT COUNT(*) FROM collections_info WHERE collection_name = '" &
    sqlEsc(collection) & "'")
  if stmt.step() == SQLITE_ROW:
    return stmt.columnInt(0) > 0
  false

proc hasBin*(profileDb: AnvioDb, collection, bin: string): bool =
  var stmt = profileDb.db.newSqliteStatement(
    "SELECT COUNT(*) FROM collections_bins_info " &
    "WHERE collection_name = '" & sqlEsc(collection) &
    "' AND bin_name = '" & sqlEsc(bin) & "'")
  if stmt.step() == SQLITE_ROW:
    return stmt.columnInt(0) > 0
  false

# ---------------------------------------------------------------------------
# FASTA export
# ---------------------------------------------------------------------------

proc writeAllContigs*(contigsDb: AnvioDb, output: File,
                      minLength = 0, prefix = "") =
  ## Write every contig in contig_sequences as FASTA to `output`.
  var sql = "SELECT contig, sequence FROM contig_sequences"
  if minLength > 0:
    sql &= " WHERE length(sequence) >= " & $minLength
  sql &= " ORDER BY contig"

  var stmt = contigsDb.db.newSqliteStatement(sql)
  while stmt.step() == SQLITE_ROW:
    output.writeLine(">" & prefix & stmt.columnText(0))
    output.writeLine(wrapSequence(stmt.columnText(1)))

proc writeBinContigs*(profileDb: AnvioDb, contigsDb: AnvioDb,
                      collection, bin: string, output: File,
                      minLength = 0, headerPrefix = "") =
  ## Write FASTA sequences for all contigs that belong to `bin` in
  ## `collection`. Uses SQLite ATTACH to join across the two databases in
  ## a single query.
  ##
  ## The collections_of_splits table maps split names to bins; splits are
  ## joined back to their parent contigs via splits_basic_info (in contigs-db),
  ## and then sequences are fetched from contig_sequences.

  # Attach the contigs database to the profile connection so we can join
  # across both files in one query.
  var attachStmt = profileDb.db.newSqliteStatement(
    "ATTACH DATABASE '" & sqlEsc(contigsDb.path) & "' AS cdb")
  discard attachStmt.step()

  var sql =
    "SELECT DISTINCT cs.contig, cs.sequence" &
    "  FROM collections_of_splits cos" &
    "  JOIN cdb.splits_basic_info sbi ON cos.contig = sbi.split" &
    "  JOIN cdb.contig_sequences  cs  ON sbi.parent = cs.contig" &
    " WHERE cos.collection_name = '" & sqlEsc(collection) & "'" &
    "   AND cos.bin_name        = '" & sqlEsc(bin)        & "'"
  if minLength > 0:
    sql &= "   AND length(cs.sequence) >= " & $minLength
  sql &= " ORDER BY cs.contig"

  var stmt = profileDb.db.newSqliteStatement(sql)
  while stmt.step() == SQLITE_ROW:
    output.writeLine(">" & headerPrefix & stmt.columnText(0))
    output.writeLine(wrapSequence(stmt.columnText(1)))

  var detachStmt = profileDb.db.newSqliteStatement("DETACH DATABASE cdb")
  discard detachStmt.step()
