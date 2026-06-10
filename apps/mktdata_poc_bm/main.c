/*
 * mktdata_poc_bm — bare-metal test for the mktdata_poc bitstream.
 *
 * Three exercises, each a standalone helper:
 *   1. test_gpio         — my_state accumulator via axi_gpio_control (ch1=ctrl,
 *                          ch2=addend) + axi_gpio_value (ch1=sum, ch2=carry).
 *   2. test_axi_fifo     — axi_fifo_echo: AXI4-Stream FIFO whose TXD→RXD is
 *                          looped in PL. Push N words, trigger TLR, pop N words.
 *   3. test_dma_fifo     — axi_dma_echo + axi_dma_fifo_echo: DDR → DMA MM2S →
 *                          axi_dma_fifo_echo (AXIS FIFO) → DMA S2MM → DDR.
 *                          DMA is programmed to push data into the FIFO's RXD,
 *                          then read it back out of the FIFO's TXD into DDR.
 *
 * Address map matches vivado/mktdata_poc.tcl (HPM0_LPD aperture, 0x8000_0000+).
 *
 *   axi_gpio_control      0x80040000  ch1=2-bit ctrl out, ch2=32-bit addend out
 *   axi_gpio_value        0x800C0000  ch1=32-bit sum in, ch2=32-bit carry in
 *   axi_fifo_echo (lite)  0x80100000  control regs (TDFR/TLR/RDFO/...)
 *   axi_fifo_echo (full)  0x80110000  data port (TDFD at +0, RDFD at +0x1000)
 *   axi_dma_echo (lite)   0x800D0000  AXI DMA control regs
 *   axi_dma_fifo_echo c   0x800E0000  data-path FIFO between DMA MM2S and S2MM
 *   axi_dma_fifo_echo d   0x800F0000
 */

#include <stdint.h>
#include <string.h>

#include "xil_io.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xparameters.h"

/* ---- Address map (matches vivado/mktdata_poc.tcl) ---- */
#define ADDR_GPIO_CONTROL       0x80040000UL
#define ADDR_GPIO_VALUE         0x800C0000UL
#define ADDR_FIFO_ECHO_CTRL     0x80100000UL
#define ADDR_FIFO_ECHO_DATA     0x80110000UL
#define ADDR_DMA_ECHO           0x800D0000UL
#define ADDR_DMA_FIFO_ECHO_CTRL 0x800E0000UL
#define ADDR_DMA_FIFO_ECHO_DATA 0x800F0000UL

/* ---- AXI GPIO (PG144) — dual-channel layout ---- */
#define GPIO_DATA   0x00   /* channel 1 */
#define GPIO2_DATA  0x08   /* channel 2 */

/* ---- AXI4-Stream FIFO (PG080) ----
 * The IP is configured with a separate AXI4 data interface (S_AXI_FULL), so:
 *   - Control regs are at the AXI4-Lite (S_AXI) base.
 *   - TDFD writes go to AXI4 data base + 0x0.
 *   - RDFD reads come from AXI4 data base + 0x1000.
 */
#define FIFO_ISR    0x00
#define FIFO_IER    0x04
#define FIFO_TDFR   0x08   /* TX reset: write 0xA5 */
#define FIFO_TDFV   0x0C   /* TX vacancy (words) */
#define FIFO_TLR    0x14   /* TX length (bytes) — write commits the packet */
#define FIFO_RDFR   0x18   /* RX reset: write 0xA5 */
#define FIFO_RDFO   0x1C   /* RX occupancy (words) */
#define FIFO_RLR    0x24   /* RX length (bytes) */
#define FIFO_SRR    0x28   /* Soft reset: write 0xA5 */
#define FIFO_TDR    0x2C   /* TX destination */
#define FIFO_RDR    0x30   /* RX destination */

#define FIFO_AXI4_TDFD  0x0000
#define FIFO_AXI4_RDFD  0x1000

#define FIFO_RESET_MAGIC  0xA5

/* ---- AXI DMA (PG021), SG mode ----
 * axi_dma_echo is configured with SG enabled (c_sg_length_width=16), so we
 * use the SG register set: CURDESC + TAILDESC walk a ring of buffer
 * descriptors (BDs). For our test one BD per direction is enough.
 */
#define DMA_MM2S_DMACR        0x00
#define DMA_MM2S_DMASR        0x04
#define DMA_MM2S_CURDESC      0x08
#define DMA_MM2S_CURDESC_MSB  0x0C
#define DMA_MM2S_TAILDESC     0x10
#define DMA_MM2S_TAILDESC_MSB 0x14

#define DMA_S2MM_DMACR        0x30
#define DMA_S2MM_DMASR        0x34
#define DMA_S2MM_CURDESC      0x38
#define DMA_S2MM_CURDESC_MSB  0x3C
#define DMA_S2MM_TAILDESC     0x40
#define DMA_S2MM_TAILDESC_MSB 0x44

#define DMA_DMACR_RS       (1u << 0)
#define DMA_DMACR_RESET    (1u << 2)
#define DMA_DMASR_HALTED   (1u << 0)
#define DMA_DMASR_IDLE     (1u << 1)
#define DMA_DMASR_SGINCLD  (1u << 3)
#define DMA_DMASR_ERR_MASK (0x770u)   /* SG, internal, slave, decode err bits */

/* ---- AXI DMA Buffer Descriptor layout (SG mode, PG021 ch. 5) ----
 * 64-byte BD. NXTDESC must be 16-byte aligned (64-byte for safety).
 */
#define BD_NXTDESC          0x00
#define BD_NXTDESC_MSB      0x04
#define BD_BUFADDR          0x08
#define BD_BUFADDR_MSB      0x0C
#define BD_CONTROL          0x18
#define BD_STATUS           0x1C

#define BD_CONTROL_SOF      (1u << 27)
#define BD_CONTROL_EOF      (1u << 26)
#define BD_CONTROL_LEN_MASK 0x03FFFFFFu
#define BD_STATUS_CMPLT     (1u << 31)
#define BD_STATUS_DEC_ERR   (1u << 30)
#define BD_STATUS_SLV_ERR   (1u << 29)
#define BD_STATUS_INT_ERR   (1u << 28)
#define BD_STATUS_LEN_MASK  0x03FFFFFFu

/* ---- Helpers ---- */

static inline void w32(uintptr_t base, uint32_t off, uint32_t v) { Xil_Out32(base + off, v); }
static inline uint32_t r32(uintptr_t base, uint32_t off) { return Xil_In32(base + off); }

/* xil_printf doesn't grok %llx — print 64-bit values as two 32-bit halves. */
static void print_u64(const char *prefix, uint64_t v) {
    xil_printf("%s0x%08x_%08x", prefix,
               (uint32_t)(v >> 32), (uint32_t)(v & 0xFFFFFFFFu));
}

/* DMA buffers in .bss, 64-byte aligned for cacheline-clean DMA. */
#define DMA_BUF_SIZE 4096
static uint8_t tx_buf[DMA_BUF_SIZE] __attribute__((aligned(64)));
static uint8_t rx_buf[DMA_BUF_SIZE] __attribute__((aligned(64)));

/* Single-entry BD rings for MM2S and S2MM. 64-byte aligned, padded to 64 B. */
static uint8_t bd_mm2s[64] __attribute__((aligned(64)));
static uint8_t bd_s2mm[64] __attribute__((aligned(64)));

static void bd_init(uint8_t *bd, uint64_t buf_pa, uint32_t len, uint32_t ctrl_flags)
{
    uint64_t bd_pa = (uint64_t)(uintptr_t)bd;
    memset(bd, 0, 64);
    /* Single-BD ring: NXTDESC points back to ourselves. */
    *(volatile uint32_t *)(bd + BD_NXTDESC)     = (uint32_t)(bd_pa & 0xFFFFFFFFu);
    *(volatile uint32_t *)(bd + BD_NXTDESC_MSB) = (uint32_t)(bd_pa >> 32);
    *(volatile uint32_t *)(bd + BD_BUFADDR)     = (uint32_t)(buf_pa & 0xFFFFFFFFu);
    *(volatile uint32_t *)(bd + BD_BUFADDR_MSB) = (uint32_t)(buf_pa >> 32);
    *(volatile uint32_t *)(bd + BD_CONTROL)     = (len & BD_CONTROL_LEN_MASK) | ctrl_flags;
    *(volatile uint32_t *)(bd + BD_STATUS)      = 0;
    /* Flush so the DMA's M_AXI_SG read sees the BD contents. */
    Xil_DCacheFlushRange((UINTPTR)bd, 64);
}

/* =========================================================================
 * Helper 1: GPIO accumulator (axi_gpio_control + axi_gpio_value + my_state)
 *
 * my_state.control opcode 1 = add (edge-triggered from 0), 2 = reset.
 * axi_gpio_control is a single dual-channel GPIO: ch1=control, ch2=addend.
 * ========================================================================= */
static int test_gpio(void)
{
    xil_printf("\r\n===== Accumulator (axi_gpio_control + axi_gpio_value) =====\r\n");
    int fails = 0;

    #define ACC_PULSE(op) do {                                 \
        w32(ADDR_GPIO_CONTROL, GPIO_DATA, 0);                  \
        w32(ADDR_GPIO_CONTROL, GPIO_DATA, (op));               \
        w32(ADDR_GPIO_CONTROL, GPIO_DATA, 0);                  \
    } while (0)

    #define ACC_SET_ADDEND(v)  w32(ADDR_GPIO_CONTROL, GPIO2_DATA, (v))

    #define ACC_READ()                                                          \
        ( ((uint64_t)r32(ADDR_GPIO_VALUE, GPIO2_DATA) << 32)                    \
        |  (uint64_t)r32(ADDR_GPIO_VALUE, GPIO_DATA) )

    #define ACC_CHECK(label, exp_hi, exp_lo) do {                               \
        uint64_t got = ACC_READ();                                              \
        uint64_t exp = ((uint64_t)(exp_hi) << 32) | (uint64_t)(exp_lo);         \
        int ok = (got == exp);                                                  \
        xil_printf("  %-28s  ", (label));                                       \
        print_u64("got=", got);                                                 \
        print_u64("  exp=", exp);                                               \
        xil_printf("  %s\r\n", ok ? "PASS" : "FAIL");                           \
        if (!ok) fails++;                                                       \
    } while (0)

    ACC_PULSE(2);                                          ACC_CHECK("reset",                0, 0);
    ACC_SET_ADDEND(5);            ACC_PULSE(1);            ACC_CHECK("+5",                   0, 5);
    ACC_PULSE(1);                                          ACC_CHECK("+5 again",             0, 10);
    ACC_SET_ADDEND(100);          ACC_PULSE(1);            ACC_CHECK("+100",                 0, 110);
    ACC_SET_ADDEND(0xFFFFFFFFu);  ACC_PULSE(1);            ACC_CHECK("+0xFFFFFFFF (cross)",  1, 109);
    ACC_PULSE(2);                                          ACC_CHECK("reset to 0",           0, 0);
    ACC_SET_ADDEND(0xDEADBEEFu);  ACC_PULSE(1);            ACC_CHECK("+0xDEADBEEF",          0, 0xDEADBEEF);
    ACC_PULSE(2); ACC_SET_ADDEND(0);                       ACC_CHECK("final reset",          0, 0);

    return fails;
}

/* =========================================================================
 * Helper 2: AXI Stream FIFO echo (axi_fifo_echo)
 *
 * The IP's AXI_STR_TXD master is wired back to its AXI_STR_RXD slave in the
 * BD, so any packet pushed via TDFD+TLR appears on the receive side after one
 * round-trip through the FIFO.
 * ========================================================================= */
static int test_axi_fifo(void)
{
    xil_printf("\r\n===== axi_fifo_echo (AXI-S FIFO TXD->RXD loopback) =====\r\n");
    int fails = 0;

    /* Soft reset both halves. */
    w32(ADDR_FIFO_ECHO_CTRL, FIFO_SRR, FIFO_RESET_MAGIC);
    /* SRR takes ~256 cycles to complete per PG080; spin briefly. */
    for (volatile int i = 0; i < 1000; i++) ;
    w32(ADDR_FIFO_ECHO_CTRL, FIFO_TDFR, FIFO_RESET_MAGIC);
    w32(ADDR_FIFO_ECHO_CTRL, FIFO_RDFR, FIFO_RESET_MAGIC);
    for (volatile int i = 0; i < 1000; i++) ;

    /* Clear any stale ISR bits (write-1-to-clear). */
    w32(ADDR_FIFO_ECHO_CTRL, FIFO_ISR, 0xFFFFFFFFu);

    uint32_t tdfv = r32(ADDR_FIFO_ECHO_CTRL, FIFO_TDFV);
    uint32_t rdfo = r32(ADDR_FIFO_ECHO_CTRL, FIFO_RDFO);
    xil_printf("  post-reset: TDFV=%u RDFO=%u\r\n", (unsigned)tdfv, (unsigned)rdfo);
    if (rdfo != 0) {
        xil_printf("  FIFO not empty after reset (RDFO=%u)\r\n", (unsigned)rdfo);
        return 1;
    }

    /* axi_fifo_echo has C_S_AXI4_DATA_WIDTH=64, so each AXI write transaction
     * on the data port consumes one 64-bit beat (= 8 bytes) regardless of
     * byte strobes. Use 64-bit accesses so TLR/RLR byte counts match the
     * actual bytes that traversed the AXIS loopback. */
    enum { N_WORDS = 16 };  /* 16 x 64-bit words = 128 bytes */
    uint64_t tx[N_WORDS], rx[N_WORDS];
    for (int i = 0; i < N_WORDS; i++)
        tx[i] = 0xCAFE000000000000ULL + (uint64_t)i * 0x100000010ULL + 1;

    /* Push N 64-bit words via the AXI4 data port at TDFD (offset 0). */
    for (int i = 0; i < N_WORDS; i++)
        Xil_Out64(ADDR_FIFO_ECHO_DATA + FIFO_AXI4_TDFD, tx[i]);

    uint32_t tdfv_after = r32(ADDR_FIFO_ECHO_CTRL, FIFO_TDFV);
    xil_printf("  after %d x 64-bit pushes: TDFV=%u (consumed %u 64-bit slots)\r\n",
               N_WORDS, (unsigned)tdfv_after, (unsigned)(508 - tdfv_after));

    /* Commit the packet -- TLR in bytes. */
    w32(ADDR_FIFO_ECHO_CTRL, FIFO_TLR, N_WORDS * 8);

    /* Wait for the loopback to deliver. */
    int spin = 0;
    while (r32(ADDR_FIFO_ECHO_CTRL, FIFO_RDFO) < N_WORDS && spin < 1000000) spin++;
    rdfo = r32(ADDR_FIFO_ECHO_CTRL, FIFO_RDFO);
    uint32_t rlr = r32(ADDR_FIFO_ECHO_CTRL, FIFO_RLR);
    uint32_t isr = r32(ADDR_FIFO_ECHO_CTRL, FIFO_ISR);
    xil_printf("  after push+TLR: spin=%d RDFO=%u RLR=%u ISR=0x%08x "
               "(expected RDFO=%u, RLR=%u bytes)\r\n",
               spin, (unsigned)rdfo, (unsigned)rlr, (unsigned)isr,
               N_WORDS, N_WORDS * 8);

    if (rdfo < N_WORDS || rlr != N_WORDS * 8) {
        xil_printf("  loopback didn't deliver -- RDFO/RLR mismatch\r\n");
        return 1;
    }

    /* Pop N 64-bit words from RDFD (offset 0x1000 of the data aperture). */
    for (int i = 0; i < N_WORDS; i++)
        rx[i] = Xil_In64(ADDR_FIFO_ECHO_DATA + FIFO_AXI4_RDFD);

    int ok = (memcmp(tx, rx, sizeof(tx)) == 0);
    if (!ok) {
        for (int i = 0; i < N_WORDS; i++) {
            if (tx[i] != rx[i]) {
                xil_printf("    [%2d] ", i);
                print_u64("tx=", tx[i]);
                print_u64("  rx=", rx[i]);
                xil_printf(" MISMATCH\r\n");
            }
        }
        fails++;
    }
    xil_printf("  echo of %d 64-bit words: %s\r\n", N_WORDS, ok ? "PASS" : "FAIL");
    return fails;
}

/* =========================================================================
 * Helper 3: AXI DMA echo via axi_dma_fifo_echo
 *
 * BD wiring:
 *   axi_dma_echo/M_AXIS_MM2S  ──>  axi_dma_fifo_echo/AXI_STR_RXD
 *   axi_dma_fifo_echo/AXI_STR_TXD  ──>  axi_dma_echo/S_AXIS_S2MM
 *
 * Software loops the FIFO through itself: MM2S pushes tx_buf into the RX
 * side of the FIFO; we mirror RX→TX in software (read RDFD, write TDFD,
 * trigger TLR); S2MM then drains the TX side into rx_buf.
 * ========================================================================= */
static int dma_wait_idle(uint32_t sr_off, const char *name)
{
    for (int i = 0; i < 10000000; i++) {
        uint32_t sr = r32(ADDR_DMA_ECHO, sr_off);
        if (sr & DMA_DMASR_ERR_MASK) {
            xil_printf("  %s SR=0x%08x ERR\r\n", name, (unsigned)sr);
            return 1;
        }
        if (sr & DMA_DMASR_IDLE) {
            xil_printf("  %s done after %d polls, SR=0x%08x\r\n",
                       name, i, (unsigned)sr);
            return 0;
        }
    }
    xil_printf("  %s timeout, SR=0x%08x\r\n",
               name, (unsigned)r32(ADDR_DMA_ECHO, sr_off));
    return 1;
}

static int test_dma_fifo(void)
{
    xil_printf("\r\n===== axi_dma_echo + axi_dma_fifo_echo "
               "(DDR -> MM2S -> FIFO -> S2MM -> DDR) =====\r\n");
    int fails = 0;
    const uint32_t buf_sz = DMA_BUF_SIZE;

    uint64_t tx_pa = (uint64_t)(uintptr_t)tx_buf;
    uint64_t rx_pa = (uint64_t)(uintptr_t)rx_buf;

    uint32_t *tx32 = (uint32_t *)tx_buf;
    uint32_t *rx32 = (uint32_t *)rx_buf;
    for (uint32_t i = 0; i < buf_sz / 4; i++)
        tx32[i] = 0xA5A50000u ^ i;
    memset(rx_buf, 0, buf_sz);

    xil_printf("  tx PA=0x%08x_%08x  rx PA=0x%08x_%08x  size=%d B\r\n",
               (uint32_t)(tx_pa >> 32), (uint32_t)(tx_pa & 0xFFFFFFFFu),
               (uint32_t)(rx_pa >> 32), (uint32_t)(rx_pa & 0xFFFFFFFFu),
               (int)buf_sz);

    Xil_DCacheFlushRange((UINTPTR)tx_buf, buf_sz);
    Xil_DCacheInvalidateRange((UINTPTR)rx_buf, buf_sz);

    /* Soft-reset the FIFO. */
    w32(ADDR_DMA_FIFO_ECHO_CTRL, FIFO_SRR, FIFO_RESET_MAGIC);
    for (volatile int i = 0; i < 1000; i++) ;
    w32(ADDR_DMA_FIFO_ECHO_CTRL, FIFO_TDFR, FIFO_RESET_MAGIC);
    w32(ADDR_DMA_FIFO_ECHO_CTRL, FIFO_RDFR, FIFO_RESET_MAGIC);
    for (volatile int i = 0; i < 1000; i++) ;
    w32(ADDR_DMA_FIFO_ECHO_CTRL, FIFO_ISR, 0xFFFFFFFFu);

    /* Reset both DMA channels. */
    w32(ADDR_DMA_ECHO, DMA_MM2S_DMACR, DMA_DMACR_RESET);
    w32(ADDR_DMA_ECHO, DMA_S2MM_DMACR, DMA_DMACR_RESET);
    int sp = 0;
    while ((r32(ADDR_DMA_ECHO, DMA_MM2S_DMACR) & DMA_DMACR_RESET) && sp < 10000) sp++;
    while ((r32(ADDR_DMA_ECHO, DMA_S2MM_DMACR) & DMA_DMACR_RESET) && sp < 10000) sp++;
    xil_printf("  after reset:  MM2S CR=0x%08x SR=0x%08x  S2MM CR=0x%08x SR=0x%08x\r\n",
               (unsigned)r32(ADDR_DMA_ECHO, DMA_MM2S_DMACR),
               (unsigned)r32(ADDR_DMA_ECHO, DMA_MM2S_DMASR),
               (unsigned)r32(ADDR_DMA_ECHO, DMA_S2MM_DMACR),
               (unsigned)r32(ADDR_DMA_ECHO, DMA_S2MM_DMASR));

    /* Build the BDs. CONTROL = length | SOF | EOF -- whole buffer is one frame. */
    bd_init(bd_mm2s, tx_pa, buf_sz, BD_CONTROL_SOF | BD_CONTROL_EOF);
    bd_init(bd_s2mm, rx_pa, buf_sz, 0);  /* S2MM ignores SOF/EOF in CONTROL */

    uint64_t bd_mm2s_pa = (uint64_t)(uintptr_t)bd_mm2s;
    uint64_t bd_s2mm_pa = (uint64_t)(uintptr_t)bd_s2mm;

    /* SG init order (PG021 sec. "Starting the SG transfer"):
     *   1. Write CURDESC while halted.
     *   2. Set DMACR.RS=1.
     *   3. Write TAILDESC -- this kicks off the transfer.
     * Do S2MM first so it's waiting for the stream from the FIFO. */
    w32(ADDR_DMA_ECHO, DMA_S2MM_CURDESC,     (uint32_t)(bd_s2mm_pa & 0xFFFFFFFFu));
    w32(ADDR_DMA_ECHO, DMA_S2MM_CURDESC_MSB, (uint32_t)(bd_s2mm_pa >> 32));
    w32(ADDR_DMA_ECHO, DMA_S2MM_DMACR,       DMA_DMACR_RS);
    w32(ADDR_DMA_ECHO, DMA_S2MM_TAILDESC,    (uint32_t)(bd_s2mm_pa & 0xFFFFFFFFu));
    w32(ADDR_DMA_ECHO, DMA_S2MM_TAILDESC_MSB,(uint32_t)(bd_s2mm_pa >> 32));

    w32(ADDR_DMA_ECHO, DMA_MM2S_CURDESC,     (uint32_t)(bd_mm2s_pa & 0xFFFFFFFFu));
    w32(ADDR_DMA_ECHO, DMA_MM2S_CURDESC_MSB, (uint32_t)(bd_mm2s_pa >> 32));
    w32(ADDR_DMA_ECHO, DMA_MM2S_DMACR,       DMA_DMACR_RS);
    w32(ADDR_DMA_ECHO, DMA_MM2S_TAILDESC,    (uint32_t)(bd_mm2s_pa & 0xFFFFFFFFu));
    w32(ADDR_DMA_ECHO, DMA_MM2S_TAILDESC_MSB,(uint32_t)(bd_mm2s_pa >> 32));

    fails += dma_wait_idle(DMA_MM2S_DMASR, "MM2S");
    if (fails) return fails;
    Xil_DCacheInvalidateRange((UINTPTR)bd_mm2s, 64);
    xil_printf("  MM2S BD status=0x%08x\r\n",
               (unsigned)(*(volatile uint32_t *)(bd_mm2s + BD_STATUS)));

    /* MM2S has filled the FIFO's RX side. Bridge it across to the TX side
     * so S2MM can pull it out: read every word from RDFD, push to TDFD,
     * then commit with TLR. axi_dma_echo strips/regenerates TLAST, so we
     * tell the FIFO to send one packet of the full byte length. */
    uint32_t rdfo = r32(ADDR_DMA_FIFO_ECHO_CTRL, FIFO_RDFO);
    uint32_t rlr  = r32(ADDR_DMA_FIFO_ECHO_CTRL, FIFO_RLR);
    xil_printf("  FIFO after MM2S: RDFO=%u RLR=%u\r\n", (unsigned)rdfo, (unsigned)rlr);

    /* axi_dma_fifo_echo also has a 64-bit AXI4 data port, so RDFO counts in
     * 64-bit-word units and the bridge runs in 64-bit beats. */
    if (rdfo < buf_sz / 8 || rlr != buf_sz) {
        xil_printf("  FIFO didn't receive full packet -- RDFO/RLR off\r\n");
        return 1;
    }

    for (uint32_t i = 0; i < buf_sz / 8; i++) {
        uint64_t w = Xil_In64(ADDR_DMA_FIFO_ECHO_DATA + FIFO_AXI4_RDFD);
        Xil_Out64(ADDR_DMA_FIFO_ECHO_DATA + FIFO_AXI4_TDFD, w);
    }
    w32(ADDR_DMA_FIFO_ECHO_CTRL, FIFO_TLR, buf_sz);

    fails += dma_wait_idle(DMA_S2MM_DMASR, "S2MM");
    Xil_DCacheInvalidateRange((UINTPTR)bd_s2mm, 64);
    xil_printf("  S2MM BD status=0x%08x (rx_len=%u)\r\n",
               (unsigned)(*(volatile uint32_t *)(bd_s2mm + BD_STATUS)),
               (unsigned)(*(volatile uint32_t *)(bd_s2mm + BD_STATUS) & BD_STATUS_LEN_MASK));

    Xil_DCacheInvalidateRange((UINTPTR)rx_buf, buf_sz);

    if (!fails) {
        if (memcmp(tx_buf, rx_buf, buf_sz) != 0) {
            int diffs = 0;
            for (uint32_t i = 0; i < buf_sz / 4 && diffs < 4; i++) {
                if (tx32[i] != rx32[i]) {
                    xil_printf("    [%4d] tx=0x%08x rx=0x%08x\r\n",
                               (int)i, (unsigned)tx32[i], (unsigned)rx32[i]);
                    diffs++;
                }
            }
            fails++;
            xil_printf("  DMA-FIFO echo: FAIL (data mismatch)\r\n");
        } else {
            xil_printf("  DMA-FIFO echo: PASS (%d bytes round-tripped)\r\n", (int)buf_sz);
        }
    }
    return fails;
}

/* ========================================================================= */

int main(void)
{
    Xil_ICacheEnable();
    Xil_DCacheEnable();

    xil_printf("\r\n=========================================\r\n");
    xil_printf("mktdata_poc_bm bare-metal test\r\n");
    xil_printf("=========================================\r\n");

    int fails = 0;
    fails += test_gpio();
    fails += test_axi_fifo();
    fails += test_dma_fifo();

    xil_printf("\r\n=========================================\r\n");
    xil_printf("RESULT: %s -- %d failures\r\n",
               fails == 0 ? "ALL PASS" : "FAIL", fails);
    xil_printf("=========================================\r\n");

    Xil_DCacheDisable();
    Xil_ICacheDisable();
    return 0;
}
