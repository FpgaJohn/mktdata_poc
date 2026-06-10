#!/bin/bash
#
# setup_host.sh -- prepare the KR260 (Ubuntu) host to run mktdata_poc_test.
#
# The userspace test's DMA-echo path needs a 2 MiB hugepage. This reserves
# hugepages if they aren't already set up. Idempotent: re-running it when the
# pool is already large enough is a no-op.
#
# Usage: ./setup_host.sh [N]   (N = number of hugepages to reserve, default 8)

WANT=${1:-8}
NR=/proc/sys/vm/nr_hugepages

cur=$(cat "$NR")
echo "---- Hugepages ----"
echo "current nr_hugepages = $cur (want >= $WANT)"

if [ "$cur" -ge "$WANT" ]; then
    echo "already set up -- nothing to do"
    exit 0
fi

echo "reserving $WANT hugepages..."
echo "$WANT" | sudo tee "$NR" > /dev/null

now=$(cat "$NR")
echo "nr_hugepages = $now"
if [ "$now" -lt "$WANT" ]; then
    echo "WARNING: only got $now/$WANT hugepages (not enough free memory?)" >&2
    exit 1
fi
echo "done"
