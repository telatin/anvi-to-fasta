## anvio.nim — reusable utilities for reading anvi'o SQLite databases.
##
## Supports contigs-db and profile-db. Opening a database validates both
## the db_type field (guards against swapped arguments) and the schema
## version (warns when an untested version is encountered).
##
## Compiles the bundled sqlite3 amalgamation (sqlite3.c) for a single-binary
## distribution with no runtime library dependency.

import strutils, sequtils

# ---------------------------------------------------------------------------
# System libsqlite3 bindings
# ---------------------------------------------------------------------------

{.compile: "sqlite3.c".}

type
  DbConn   = pointer   # sqlite3*
  StmtPtr  = pointer   # sqlite3_stmt*

const
  SQLITE_OK*   = 0.cint
  SQLITE_ROW*  = 100.cint
  SQLITE_DONE* = 101.cint

proc sqlite3_open(filename: cstring, ppDb: ptr DbConn): cint
    {.importc, cdecl.}
proc sqlite3_close(db: DbConn): cint
    {.importc, cdecl.}
proc sqlite3_prepare_v2(db: DbConn, sql: cstring, nByte: cint,
                        ppStmt: ptr StmtPtr, pzTail: ptr cstring): cint
    {.importc, cdecl.}
proc sqlite3_step(stmt: StmtPtr): cint
    {.importc, cdecl.}
proc sqlite3_finalize(stmt: StmtPtr): cint
    {.importc, cdecl.}
proc sqlite3_column_text(stmt: StmtPtr, col: cint): cstring
    {.importc, cdecl.}
proc sqlite3_column_int(stmt: StmtPtr, col: cint): cint
    {.importc, cdecl.}
proc sqlite3_errmsg(db: DbConn): cstring
    {.importc, cdecl.}

# ---------------------------------------------------------------------------
# Thin wrappers (keep SQL strings alive across calls)
# ---------------------------------------------------------------------------

proc dbOpen(path: string): DbConn =
  var conn: DbConn
  let pathBuf = path           # keep string alive for cstring pointer
  if sqlite3_open(pathBuf.cstring, addr conn) != SQLITE_OK:
    stderr.writeLine("Error: cannot open database: " & path)
    quit(1)
  conn

proc stmtPrepare(conn: DbConn, sql: string): StmtPtr =
  var stmt: StmtPtr
  let sqlBuf = sql             # keep string alive for cstring pointer
  if sqlite3_prepare_v2(conn, sqlBuf.cstring, -1.cint,
                        addr stmt, nil) != SQLITE_OK:
    stderr.writeLine("Error: failed to prepare SQL: " & sql)
    stderr.writeLine("SQLite error: " & $sqlite3_errmsg(conn))
    quit(1)
  stmt

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  DbKind* = enum
    dkContigs = "contigs"
    dkProfile = "profile"

  AnvioDb* = object
    path*:    string
    kind*:    DbKind
    version*: int
    conn*:    DbConn

  CollectionInfo* = object
    name*:     string
    numBins*:  int
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
  let conn = dbOpen(path)

  var foundKind: DbKind
  var foundVersion: int

  let sql  = "SELECT key, value FROM self WHERE key IN ('db_type', 'version')"
  let stmt = stmtPrepare(conn, sql)
  while sqlite3_step(stmt) == SQLITE_ROW:
    let key = $sqlite3_column_text(stmt, 0)
    let val = $sqlite3_column_text(stmt, 1)
    case key
    of "db_type":
      case val
      of "contigs": foundKind = dkContigs
      of "profile": foundKind = dkProfile
      else:
        discard sqlite3_finalize(stmt)
        discard sqlite3_close(conn)
        stderr.writeLine("Error: unknown db_type '" & val & "' in " & path)
        quit(1)
    of "version":
      foundVersion = parseInt(val)
  discard sqlite3_finalize(stmt)

  if foundKind != expectedKind:
    discard sqlite3_close(conn)
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

  AnvioDb(path: path, kind: foundKind, version: foundVersion, conn: conn)

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
  let sql  = "SELECT collection_name, bin_name " &
             "FROM collections_bins_info ORDER BY collection_name, bin_name"
  let stmt = stmtPrepare(profileDb.conn, sql)
  while sqlite3_step(stmt) == SQLITE_ROW:
    let colName = $sqlite3_column_text(stmt, 0)
    let binName = $sqlite3_column_text(stmt, 1)
    if result.len > 0 and result[^1].name == colName:
      result[^1].binNames.add(binName)
      inc result[^1].numBins
    else:
      result.add(CollectionInfo(name: colName, numBins: 1, binNames: @[binName]))
  discard sqlite3_finalize(stmt)

proc hasCollection*(profileDb: AnvioDb, collection: string): bool =
  let sql  = "SELECT COUNT(*) FROM collections_info WHERE collection_name = '" &
             sqlEsc(collection) & "'"
  let stmt = stmtPrepare(profileDb.conn, sql)
  result = sqlite3_step(stmt) == SQLITE_ROW and
           sqlite3_column_int(stmt, 0) > 0
  discard sqlite3_finalize(stmt)

proc hasBin*(profileDb: AnvioDb, collection, bin: string): bool =
  let sql  = "SELECT COUNT(*) FROM collections_bins_info " &
             "WHERE collection_name = '" & sqlEsc(collection) &
             "' AND bin_name = '" & sqlEsc(bin) & "'"
  let stmt = stmtPrepare(profileDb.conn, sql)
  result = sqlite3_step(stmt) == SQLITE_ROW and
           sqlite3_column_int(stmt, 0) > 0
  discard sqlite3_finalize(stmt)

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

  let stmt = stmtPrepare(contigsDb.conn, sql)
  while sqlite3_step(stmt) == SQLITE_ROW:
    output.writeLine(">" & prefix & $sqlite3_column_text(stmt, 0))
    output.writeLine(wrapSequence($sqlite3_column_text(stmt, 1)))
  discard sqlite3_finalize(stmt)

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
  let attachSql  = "ATTACH DATABASE '" & sqlEsc(contigsDb.path) & "' AS cdb"
  let attachStmt = stmtPrepare(profileDb.conn, attachSql)
  discard sqlite3_step(attachStmt)
  discard sqlite3_finalize(attachStmt)

  var sql =
    "SELECT DISTINCT cs.contig, cs.sequence" &
    "  FROM collections_of_splits cos" &
    "  JOIN cdb.splits_basic_info sbi ON cos.split = sbi.split" &
    "  JOIN cdb.contig_sequences  cs  ON sbi.parent = cs.contig" &
    " WHERE cos.collection_name = '" & sqlEsc(collection) & "'" &
    "   AND cos.bin_name        = '" & sqlEsc(bin)        & "'"
  if minLength > 0:
    sql &= " AND length(cs.sequence) >= " & $minLength
  sql &= " ORDER BY cs.contig"

  let stmt = stmtPrepare(profileDb.conn, sql)
  while sqlite3_step(stmt) == SQLITE_ROW:
    output.writeLine(">" & headerPrefix & $sqlite3_column_text(stmt, 0))
    output.writeLine(wrapSequence($sqlite3_column_text(stmt, 1)))
  discard sqlite3_finalize(stmt)

  let detachStmt = stmtPrepare(profileDb.conn, "DETACH DATABASE cdb")
  discard sqlite3_step(detachStmt)
  discard sqlite3_finalize(detachStmt)
