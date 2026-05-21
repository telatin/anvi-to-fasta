set -exuo pipefail 
echo "Test 0"
./anvi-to-fasta --help
echo "Test 1"
./anvi-to-fasta tests/data/CONTIGS.db > /dev/null
echo "Test 2"
./anvi-to-fasta tests/data/CONTIGS.db -p tests/data/PROFILE.db --list > /dev/null
echo "Test 3"
./anvi-to-fasta tests/data/CONTIGS.db -p tests/data/PROFILE.db -c default -b Bin_1 > /dev/null
