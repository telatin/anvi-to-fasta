# anvi-to-fasta

Export contigs and collection bins from [anvi'o](https://anvio.org) databases as FASTA.

## Build

Requires [Nim](https://nim-lang.org) ≥ 2.2.4 (via [choosenim](https://github.com/dom96/choosenim)) and nimble.

```bash
choosenim 2.2.4
nimble build
```

The binary is placed at `./anvi-to-fasta`.

> **macOS note:** build outside a conda environment — conda's clang conflicts with the system linker.

## Usage

```
anvi-to-fasta CONTIGS.db [options]

  -p, --profile     PATH   anvi'o profile database
  -o, --output      FILE   output FASTA (default: stdout)
  -d, --dir         DIR    output directory for per-bin files

  -l, --list               list collections and bins, then exit
  -c, --collection  STR    export contigs from this collection
  -b, --bin         STR    export only this bin (requires -c)
  -a, --all                export every collection × bin (requires -d)

  -s, --separator   STR    separator in output filenames (default: __)
      --min-length  INT    skip contigs shorter than INT bp (default: 0)
      --prefix      STR    prefix added to every sequence header
```

## Examples

**Export all contigs from a contigs database:**

```bash
anvi-to-fasta CONTIGS.db -o all-contigs.fasta
```

**List available collections and bins in a profile database:**

```bash
anvi-to-fasta CONTIGS.db -p PROFILE.db --list
```

**Export a single bin to stdout:**

```bash
anvi-to-fasta CONTIGS.db -p PROFILE.db -c default -b Bin_1
```

**Export every bin in a collection as separate files:**

```bash
anvi-to-fasta CONTIGS.db -p PROFILE.db -c default -d bins/
# writes bins/default__Bin_1.fasta, bins/default__Bin_2.fasta, …
```

**Export all collections and all bins at once:**

```bash
anvi-to-fasta CONTIGS.db -p PROFILE.db --all -d export/
```
