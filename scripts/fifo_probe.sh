#!/bin/sh
# fifo_probe.sh -- drive axi_fifo_echo (axi_fifo_mm_s, TXD->RXD self-loop) via
# devmem and observe whether a push lands and whether the transmit loops back.
# Run on the KR260 as root after `xmutil loadapp mktdata_poc`.
#
# axi_fifo_echo ctrl @ 0x80100000, data @ 0x80110000 (64-bit AXI4 data port).
set -u
C=0x80100000          # ctrl base
ISR=0x80100000
TDFR=0x80100008
TDFV=0x8010000C
TLR=0x80100014
RDFO=0x8010001C
SRR=0x80100028
TDFD=0x80110000       # 64-bit data port (push)

echo "== reset =="
devmem $SRR  32 0xA5
devmem $TDFR 32 0xA5
devmem 0x80100018 32 0xA5     # RDFR
devmem $ISR  32 0xFFFFFFFF
echo "TDFV=$(devmem $TDFV 32)  RDFO=$(devmem $RDFO 32)  ISR=$(devmem $ISR 32)"

echo "== push 4 x 64-bit words to TDFD =="
# Try 64-bit writes first; if devmem lacks 64-bit, fall back to 32-bit pairs.
if devmem $TDFD 64 0xCAFE000000000001 2>/dev/null; then
    devmem $TDFD 64 0xCAFE000000000002
    devmem $TDFD 64 0xCAFE000000000003
    devmem $TDFD 64 0xCAFE000000000004
    echo "(used 64-bit writes)"
else
    echo "(devmem 64-bit unsupported -- using 32-bit pairs lo,hi)"
    for w in 1 2 3 4; do
        devmem $TDFD       32 0x0000000$w
        devmem 0x80110004  32 0xCAFE0000
    done
fi
echo "after push: TDFV=$(devmem $TDFV 32)  ISR=$(devmem $ISR 32)"

echo "== write TLR = 32 bytes (4 x 64-bit) =="
devmem $TLR 32 32
sleep 1
echo "after TLR:  TDFV=$(devmem $TDFV 32)  RDFO=$(devmem $RDFO 32)  ISR=$(devmem $ISR 32)"
