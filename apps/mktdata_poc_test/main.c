/*
 * mktdata_poc_test -- exercise the mktdata_poc bitstream from Linux userspace.
 *
 * Commands:
 *   test    - the original three tests:
 *               1. my_state accumulator via axi_gpio_control (ch1=ctrl,
 *                  ch2=addend) and axi_gpio_value (ch1=sum, ch2=carry).
 *               2. axi_fifo_echo: AXI-S FIFO with TXD->RXD looped in PL.
 *               3. axi_dma_echo + axi_dma_fifo_echo: DDR -> MM2S -> FIFO ->
 *                  S2MM -> DDR, software bridges FIFO RX -> TX.
 *   reset   - pulse the NI IP reset (axi_gpio_1: 0 -> 1 -> 0) and exit.
 *   debug   - continuously poll axi_fifo_debug, hex-dump frames (Ctrl-C stops).
 *   mdebug  - same for axi_fifo_mdebug.
 *   cmd     - same for axi_fifo_cmd.
 *   poll    - poll FIFOs concurrently, one thread per FIFO. With no extra
 *             args, all three; otherwise the named subset, e.g.
 *             "poll debug mdebug".
 *
 * Runs as root (needs /dev/uioN, /proc/self/pagemap, mlock or hugepages).
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* ---- Address map (matches vivado/mktdata_poc.tcl, HPM0_FPD aperture) ---- */
#define ADDR_GPIO_CONTROL       0x80040000UL
#define ADDR_GPIO_VALUE         0x800C0000UL
#define ADDR_FIFO_MDEBUG_CTRL   0x80050000UL
#define ADDR_FIFO_MDEBUG_DATA   0x80060000UL
#define ADDR_FIFO_DEBUG_CTRL    0x80070000UL
#define ADDR_FIFO_DEBUG_DATA    0x80080000UL
#define ADDR_GPIO_1             0x80090000UL
#define ADDR_FIFO_CMD_CTRL      0x800A0000UL
#define ADDR_FIFO_CMD_DATA      0x800B0000UL
#define ADDR_FIFO_ECHO_CTRL     0x80100000UL
#define ADDR_FIFO_ECHO_DATA     0x80110000UL
#define ADDR_DMA_ECHO           0x800D0000UL
#define ADDR_DMA_FIFO_ECHO_CTRL 0x800E0000UL
#define ADDR_DMA_FIFO_ECHO_DATA 0x800F0000UL
#define MAP_SIZE                0x10000UL

/* ---- AXI GPIO v2.0 ---- */
#define GPIO_DATA   0x00    /* channel 1 data register */

/* Idle backoff for the FIFO pollers (us). */
#define POLL_IDLE_US 200

/* ---- AXI4-Stream FIFO (PG080) ---- */
#define FIFO_ISR    0x00
#define FIFO_IER    0x04
#define FIFO_TDFR   0x08
#define FIFO_TDFV   0x0C
#define FIFO_TLR    0x14
#define FIFO_RDFR   0x18
#define FIFO_RDFO   0x1C
#define FIFO_RLR    0x24
#define FIFO_SRR    0x28
#define FIFO_TDR    0x2C
#define FIFO_RDR    0x30

#define FIFO_AXI4_TDFD  0x0000
#define FIFO_AXI4_RDFD  0x1000

#define FIFO_RESET_MAGIC  0xA5

/* ---- simple_fifo (custom AXI4-Lite slave; replaces axi_fifo_echo) ----
 * push@+0 W / pop@+0 R, count@+4 R, status@+8 R (bit0=empty bit1=full),
 * reset@+0xC W. 32-bit storage: a 64-bit word is two pushes (lo then hi). */
#define SF_DATA    0x00
#define SF_COUNT   0x04
#define SF_STATUS  0x08
#define SF_RESET   0x0C
#define SF_STATUS_EMPTY  0x1u
#define SF_STATUS_FULL   0x2u

/* ---- AXI DMA (PG021), SG mode (axi_dma_echo has c_sg_length_width=16) ---- */
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
#define DMA_DMASR_ERR_MASK (0x770u)

/* Buffer Descriptor layout (PG021 ch. 5). 64-byte BD, 16-byte aligned. */
#define BD_NXTDESC          0x00
#define BD_NXTDESC_MSB      0x04
#define BD_BUFADDR          0x08
#define BD_BUFADDR_MSB      0x0C
#define BD_CONTROL          0x18
#define BD_STATUS           0x1C

#define BD_CONTROL_SOF      (1u << 27)
#define BD_CONTROL_EOF      (1u << 26)
#define BD_CONTROL_LEN_MASK 0x03FFFFFFu
#define BD_STATUS_LEN_MASK  0x03FFFFFFu

/* ---- Helpers ---- */

static int read_hex(const char *path, unsigned long *out)
{
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int n = fscanf(f, "%lx", out);
    fclose(f);
    return (n == 1) ? 0 : -1;
}

static int find_uio_for(unsigned long addr, char *out, size_t outlen)
{
    DIR *d = opendir("/sys/class/uio");
    if (!d) return -1;
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (strncmp(de->d_name, "uio", 3) != 0) continue;
        char p[256];
        unsigned long a = 0;
        snprintf(p, sizeof(p), "/sys/class/uio/%s/maps/map0/addr", de->d_name);
        if (read_hex(p, &a) < 0) continue;
        if (a == addr) {
            snprintf(out, outlen, "/dev/%s", de->d_name);
            closedir(d);
            return 0;
        }
    }
    closedir(d);
    return -1;
}

static volatile uint32_t *map_uio(unsigned long addr, const char *label, int *out_fd)
{
    char dev[64];
    if (find_uio_for(addr, dev, sizeof(dev)) < 0) {
        fprintf(stderr, "  %-22s: NO UIO at 0x%08lx\n", label, addr);
        return NULL;
    }
    int fd = open(dev, O_RDWR | O_SYNC);
    if (fd < 0) { perror(dev); return NULL; }
    void *p = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) { perror("mmap"); close(fd); return NULL; }
    printf("  %-22s: %s @ 0x%08lx\n", label, dev, addr);
    *out_fd = fd;
    return (volatile uint32_t *)p;
}

static inline void w32(volatile uint32_t *base, uint32_t off, uint32_t v) {
    base[off / 4] = v;
    asm volatile("dsb sy" ::: "memory");
}
static inline uint32_t r32(volatile uint32_t *base, uint32_t off) {
    asm volatile("dsb sy" ::: "memory");
    return base[off / 4];
}

/* aarch64 EL0 cache maintenance. SCTLR_EL1.UCI=1 on Linux exposes DC CVAC/CIVAC.
 * Cacheline is 64 B on Cortex-A53/A72. Buffers below are page-aligned 4 KiB
 * so the loop trivially covers whole lines. */
static inline void dcache_clean_range(const void *begin, size_t len)
{
    const uintptr_t start = (uintptr_t)begin;
    const uintptr_t end   = start + len;
    for (uintptr_t p = start; p < end; p += 64)
        asm volatile("dc cvac, %0" :: "r"(p) : "memory");
    asm volatile("dsb sy" ::: "memory");
}

static inline void dcache_invalidate_range(const void *begin, size_t len)
{
    const uintptr_t start = (uintptr_t)begin;
    const uintptr_t end   = start + len;
    asm volatile("dsb sy" ::: "memory");
    for (uintptr_t p = start; p < end; p += 64)
        asm volatile("dc civac, %0" :: "r"(p) : "memory");
    asm volatile("dsb sy" ::: "memory");
}

static int virt_to_phys(void *va, uint64_t *pa_out)
{
    int fd = open("/proc/self/pagemap", O_RDONLY);
    if (fd < 0) { perror("/proc/self/pagemap"); return -1; }
    long pgsz = sysconf(_SC_PAGESIZE);
    uint64_t vfn = (uintptr_t)va / pgsz;
    if (lseek(fd, vfn * 8, SEEK_SET) < 0) { perror("lseek pagemap"); close(fd); return -1; }
    uint64_t entry = 0;
    ssize_t r = read(fd, &entry, sizeof(entry));
    close(fd);
    if (r != sizeof(entry)) { fprintf(stderr, "pagemap short read\n"); return -1; }
    if (!(entry & (1ULL << 63))) { fprintf(stderr, "page not present\n"); return -1; }
    uint64_t pfn = entry & ((1ULL << 55) - 1);
    if (pfn == 0) {
        fprintf(stderr, "pagemap PFN=0 -- need root or CAP_SYS_ADMIN\n");
        return -1;
    }
    *pa_out = pfn * pgsz + ((uintptr_t)va % pgsz);
    return 0;
}

/* ---- Test 1: accumulator ---- */

static int test_accumulator(volatile uint32_t *ctrl, volatile uint32_t *val)
{
    printf("\n===== Accumulator (axi_gpio_control + axi_gpio_value) =====\n");
    int fails = 0;

    #define ACC_PULSE(op)        do { w32(ctrl, 0, 0); w32(ctrl, 0, (op)); w32(ctrl, 0, 0); } while (0)
    #define ACC_SET_ADDEND(v)    w32(ctrl, 8, (v))
    #define ACC_READ()           (((uint64_t)r32(val, 8) << 32) | (uint64_t)r32(val, 0))
    #define ACC_CHECK(label, exp_hi, exp_lo) do {                                            \
        uint64_t got = ACC_READ();                                                           \
        uint64_t exp = ((uint64_t)(exp_hi) << 32) | (uint64_t)(exp_lo);                      \
        int ok = (got == exp);                                                               \
        printf("  %-28s got=0x%016" PRIx64 " exp=0x%016" PRIx64 " %s\n",                     \
               (label), got, exp, ok ? "PASS" : "FAIL");                                     \
        if (!ok) fails++;                                                                    \
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

/* ---- Test 2: axi_fifo_echo (TXD->RXD loopback) ---- */

static int test_axi_fifo(volatile uint32_t *fifo)
{
    printf("\n===== simple_fifo push/pop (64-bit-word echo) =====\n");
    int fails = 0;

    w32(fifo, SF_RESET, 1);
    uint32_t status = r32(fifo, SF_STATUS);
    uint32_t count  = r32(fifo, SF_COUNT);
    printf("  post-reset: STATUS=0x%x (empty=%d full=%d)  COUNT=%u\n",
           status, !!(status & SF_STATUS_EMPTY), !!(status & SF_STATUS_FULL), count);
    if (!(status & SF_STATUS_EMPTY) || count != 0) {
        fprintf(stderr, "  FIFO not empty after reset\n");
        return 1;
    }

    /* 16 logical 64-bit words = 32 x 32-bit pushes (lo first, then hi). */
    enum { N_WORDS = 16 };
    uint64_t tx[N_WORDS], rx[N_WORDS];
    for (int i = 0; i < N_WORDS; i++)
        tx[i] = 0xCAFE000000000001ULL + (uint64_t)i * 0x100000010ULL;

    for (int i = 0; i < N_WORDS; i++) {
        w32(fifo, SF_DATA, (uint32_t)(tx[i] & 0xFFFFFFFFu));
        w32(fifo, SF_DATA, (uint32_t)(tx[i] >> 32));
    }

    count = r32(fifo, SF_COUNT);
    printf("  after %d 64-bit pushes: COUNT=%u (expected %u)\n",
           N_WORDS, count, N_WORDS * 2);
    if (count != (uint32_t)(N_WORDS * 2)) {
        fprintf(stderr, "  COUNT mismatch -- pushes didn't all land\n");
        return 1;
    }

    for (int i = 0; i < N_WORDS; i++) {
        uint32_t lo = r32(fifo, SF_DATA);
        uint32_t hi = r32(fifo, SF_DATA);
        rx[i] = ((uint64_t)hi << 32) | lo;
    }

    count  = r32(fifo, SF_COUNT);
    status = r32(fifo, SF_STATUS);
    int ok = (memcmp(tx, rx, sizeof(tx)) == 0) && (count == 0) &&
             (status & SF_STATUS_EMPTY);
    if (!ok) {
        for (int i = 0; i < N_WORDS; i++)
            if (tx[i] != rx[i])
                printf("    [%2d] tx=0x%016" PRIx64 " rx=0x%016" PRIx64 " MISMATCH\n",
                       i, tx[i], rx[i]);
        fails++;
    }
    printf("  echo of %d 64-bit words: %s (COUNT=%u STATUS=0x%x)\n",
           N_WORDS, ok ? "PASS" : "FAIL", count, status);
    return fails;
}

/* ---- Test 3: axi_dma_echo + axi_dma_fifo_echo ---- */

static int dma_wait_idle(volatile uint32_t *dma, uint32_t sr_off, const char *name)
{
    for (int i = 0; i < 10000000; i++) {
        uint32_t sr = r32(dma, sr_off);
        if (sr & DMA_DMASR_ERR_MASK) { fprintf(stderr, "  %s SR=0x%08x ERR\n", name, sr); return 1; }
        if (sr & DMA_DMASR_IDLE)     { printf("  %s done after %d polls, SR=0x%08x\n", name, i, sr); return 0; }
    }
    fprintf(stderr, "  %s timeout, SR=0x%08x\n", name, r32(dma, sr_off));
    return 1;
}

static int test_dma_fifo(volatile uint32_t *dma,
                         volatile uint32_t *fifo_ctrl,
                         volatile uint32_t *fifo_data)
{
    printf("\n===== axi_dma_echo + axi_dma_fifo_echo "
           "(DDR -> MM2S -> FIFO -> S2MM -> DDR) =====\n");
    int fails = 0;

    /* Buffer strategy: try MAP_HUGETLB first (PA < 4 GB, contiguous),
     * fall back to posix_memalign + mlock. */
    long pgsz = sysconf(_SC_PAGESIZE);
    size_t buf_sz = 4096;
    size_t alloc_sz = 2 * 1024 * 1024;  /* 2 MiB hugepage on aarch64 */
    int used_hugepage = 0;
    void *base = mmap(NULL, alloc_sz, PROT_READ | PROT_WRITE,
                      MAP_SHARED | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
    if (base != MAP_FAILED) {
        used_hugepage = 1;
    } else {
        fprintf(stderr, "  mmap(MAP_HUGETLB) failed (%s) -- falling back to posix_memalign\n",
                strerror(errno));
        if (posix_memalign(&base, pgsz, alloc_sz) != 0) { perror("posix_memalign"); return 1; }
        if (mlock(base, alloc_sz) != 0) { perror("mlock"); free(base); return 1; }
    }
    memset(base, 0, alloc_sz);
    for (size_t off = 0; off < alloc_sz; off += pgsz)
        ((volatile char *)base)[off] = 0;

    /* Layout inside the 2 MiB region:
     *   +0          tx_buf (4 KiB)
     *   +0x1000     rx_buf (4 KiB)
     *   +0x2000     bd_mm2s (64 B)
     *   +0x2040     bd_s2mm (64 B)
     * Single 2 MiB hugepage keeps everything PA-contiguous. */
    uint32_t *tx       = (uint32_t *)base;
    uint32_t *rx       = (uint32_t *)((char *)base + buf_sz);
    uint8_t  *bd_mm2s  = (uint8_t *)((char *)base + 2 * buf_sz);
    uint8_t  *bd_s2mm  = (uint8_t *)((char *)base + 2 * buf_sz + 64);

    const size_t n32 = buf_sz / 4;
    for (size_t i = 0; i < n32; i++) tx[i] = 0xA5A50000u ^ (uint32_t)i;

    uint64_t tx_pa = 0, rx_pa = 0, bd_mm2s_pa = 0, bd_s2mm_pa = 0;
    if (virt_to_phys(tx, &tx_pa) < 0 || virt_to_phys(rx, &rx_pa) < 0 ||
        virt_to_phys(bd_mm2s, &bd_mm2s_pa) < 0 ||
        virt_to_phys(bd_s2mm, &bd_s2mm_pa) < 0) {
        if (used_hugepage) munmap(base, alloc_sz);
        else { munlock(base, alloc_sz); free(base); }
        return 1;
    }
    printf("  %s tx VA=%p PA=0x%016" PRIx64 "  rx VA=%p PA=0x%016" PRIx64 "  size=%zu B\n",
           used_hugepage ? "[hugepage]" : "[posix_memalign]",
           (void *)tx, tx_pa, (void *)rx, rx_pa, buf_sz);
    printf("    bd_mm2s PA=0x%016" PRIx64 "  bd_s2mm PA=0x%016" PRIx64 "\n",
           bd_mm2s_pa, bd_s2mm_pa);

    /* HPC0 here is NOT coherent (PSU__AFI0_COHERENCY=0 in mktdata_poc.tcl). */
    dcache_clean_range(tx, buf_sz);
    dcache_invalidate_range(rx, buf_sz);

    w32(fifo_ctrl, FIFO_SRR, FIFO_RESET_MAGIC);
    usleep(1000);
    w32(fifo_ctrl, FIFO_TDFR, FIFO_RESET_MAGIC);
    w32(fifo_ctrl, FIFO_RDFR, FIFO_RESET_MAGIC);
    usleep(1000);
    w32(fifo_ctrl, FIFO_ISR, 0xFFFFFFFFu);

    w32(dma, DMA_MM2S_DMACR, DMA_DMACR_RESET);
    w32(dma, DMA_S2MM_DMACR, DMA_DMACR_RESET);
    int sp = 0;
    while (((r32(dma, DMA_MM2S_DMACR) & DMA_DMACR_RESET) ||
            (r32(dma, DMA_S2MM_DMACR) & DMA_DMACR_RESET)) && sp < 10000) sp++;
    if (sp >= 10000) {
        fprintf(stderr, "  DMA reset never cleared\n");
        if (used_hugepage) munmap(base, alloc_sz); else { munlock(base, alloc_sz); free(base); }
        return 1;
    }
    printf("  after reset:  MM2S CR=0x%08x SR=0x%08x  S2MM CR=0x%08x SR=0x%08x\n",
           r32(dma, DMA_MM2S_DMACR), r32(dma, DMA_MM2S_DMASR),
           r32(dma, DMA_S2MM_DMACR), r32(dma, DMA_S2MM_DMASR));

    /* Build single-BD rings in the same hugepage. */
    memset(bd_mm2s, 0, 64);
    *(volatile uint32_t *)(bd_mm2s + BD_NXTDESC)     = (uint32_t)(bd_mm2s_pa & 0xFFFFFFFFu);
    *(volatile uint32_t *)(bd_mm2s + BD_NXTDESC_MSB) = (uint32_t)(bd_mm2s_pa >> 32);
    *(volatile uint32_t *)(bd_mm2s + BD_BUFADDR)     = (uint32_t)(tx_pa & 0xFFFFFFFFu);
    *(volatile uint32_t *)(bd_mm2s + BD_BUFADDR_MSB) = (uint32_t)(tx_pa >> 32);
    *(volatile uint32_t *)(bd_mm2s + BD_CONTROL)     =
        (buf_sz & BD_CONTROL_LEN_MASK) | BD_CONTROL_SOF | BD_CONTROL_EOF;

    memset(bd_s2mm, 0, 64);
    *(volatile uint32_t *)(bd_s2mm + BD_NXTDESC)     = (uint32_t)(bd_s2mm_pa & 0xFFFFFFFFu);
    *(volatile uint32_t *)(bd_s2mm + BD_NXTDESC_MSB) = (uint32_t)(bd_s2mm_pa >> 32);
    *(volatile uint32_t *)(bd_s2mm + BD_BUFADDR)     = (uint32_t)(rx_pa & 0xFFFFFFFFu);
    *(volatile uint32_t *)(bd_s2mm + BD_BUFADDR_MSB) = (uint32_t)(rx_pa >> 32);
    *(volatile uint32_t *)(bd_s2mm + BD_CONTROL)     = buf_sz & BD_CONTROL_LEN_MASK;

    dcache_clean_range(bd_mm2s, 64);
    dcache_clean_range(bd_s2mm, 64);

    w32(dma, DMA_S2MM_CURDESC,     (uint32_t)(bd_s2mm_pa & 0xFFFFFFFFu));
    w32(dma, DMA_S2MM_CURDESC_MSB, (uint32_t)(bd_s2mm_pa >> 32));
    w32(dma, DMA_S2MM_DMACR,       DMA_DMACR_RS);
    w32(dma, DMA_S2MM_TAILDESC,    (uint32_t)(bd_s2mm_pa & 0xFFFFFFFFu));
    w32(dma, DMA_S2MM_TAILDESC_MSB,(uint32_t)(bd_s2mm_pa >> 32));

    w32(dma, DMA_MM2S_CURDESC,     (uint32_t)(bd_mm2s_pa & 0xFFFFFFFFu));
    w32(dma, DMA_MM2S_CURDESC_MSB, (uint32_t)(bd_mm2s_pa >> 32));
    w32(dma, DMA_MM2S_DMACR,       DMA_DMACR_RS);
    w32(dma, DMA_MM2S_TAILDESC,    (uint32_t)(bd_mm2s_pa & 0xFFFFFFFFu));
    w32(dma, DMA_MM2S_TAILDESC_MSB,(uint32_t)(bd_mm2s_pa >> 32));

    fails += dma_wait_idle(dma, DMA_MM2S_DMASR, "MM2S");

    /* The DMA stream now loops MM2S -> axis_data_fifo -> S2MM entirely in PL
     * (no CPU RDFD->TDFD re-injection, which used to swap the 32-bit halves of
     * each 64-bit beat). Just wait for the receive side to finish. */
    (void)fifo_data;
    if (!fails)
        fails += dma_wait_idle(dma, DMA_S2MM_DMASR, "S2MM");

    dcache_invalidate_range(rx, buf_sz);

    if (!fails) {
        if (memcmp(tx, rx, buf_sz) != 0) {
            int diffs = 0;
            for (size_t i = 0; i < n32 && diffs < 4; i++) {
                if (tx[i] != rx[i]) {
                    printf("    [%4zu] tx=0x%08x rx=0x%08x\n", i, tx[i], rx[i]);
                    diffs++;
                }
            }
            fails++;
            printf("  DMA-FIFO echo: FAIL (data mismatch)\n");
        } else {
            printf("  DMA-FIFO echo: PASS (%zu bytes round-tripped)\n", buf_sz);
        }
    }

    if (used_hugepage) munmap(base, alloc_sz);
    else { munlock(base, alloc_sz); free(base); }
    return fails;
}

/* ---- Command: test (the original three tests) ---- */

static int cmd_test(void)
{
    printf("Opening UIOs:\n");
    int fd_c, fd_v, fd_fc, fd_d, fd_dfc, fd_dfd;
    volatile uint32_t *ctrl      = map_uio(ADDR_GPIO_CONTROL,       "axi_gpio_control",     &fd_c);
    volatile uint32_t *val       = map_uio(ADDR_GPIO_VALUE,         "axi_gpio_value",       &fd_v);
    volatile uint32_t *fifo      = map_uio(ADDR_FIFO_ECHO_CTRL,     "simple_fifo (echo)",   &fd_fc);
    volatile uint32_t *dma       = map_uio(ADDR_DMA_ECHO,           "axi_dma_echo",         &fd_d);
    volatile uint32_t *dfc       = map_uio(ADDR_DMA_FIFO_ECHO_CTRL, "axi_dma_fifo_echo c",  &fd_dfc);
    volatile uint32_t *dfd       = map_uio(ADDR_DMA_FIFO_ECHO_DATA, "axi_dma_fifo_echo d",  &fd_dfd);
    if (!ctrl || !val || !fifo || !dma || !dfc || !dfd) return 1;

    int fails = 0;
    fails += test_accumulator(ctrl, val);
    fails += test_axi_fifo(fifo);
    fails += test_dma_fifo(dma, dfc, dfd);

    printf("\n=========================================\n");
    printf("Accumulator + FIFO + DMA-FIFO: %s\n", fails == 0 ? "PASS" : "FAIL");
    printf("=========================================\n");
    return fails == 0 ? 0 : 1;
}

/* ---- Command: reset (pulse the NI IP reset via axi_gpio_1) ---- */

static int cmd_reset(void)
{
    printf("Opening UIOs:\n");
    int fd_g1;
    volatile uint32_t *gpio1 = map_uio(ADDR_GPIO_1, "axi_gpio_1", &fd_g1);
    if (!gpio1) {
        fprintf(stderr, "axi_gpio_1 not found -- was the kria app rebuilt and "
                        "reloaded with the new device-tree overlay?\n");
        return 1;
    }

    printf("Pulsing NI IP reset (axi_gpio_1 -> ctrlind_17_ip_reset): 0");
    w32(gpio1, GPIO_DATA, 0);
    usleep(1000);
    printf(" -> 1");
    w32(gpio1, GPIO_DATA, 1);
    usleep(1000);
    printf(" -> 0\n");
    w32(gpio1, GPIO_DATA, 0);
    usleep(1000);
    printf("NI IP reset done.\n");
    return 0;
}

/* ---- Commands: debug / mdebug / cmd / poll (RX-only FIFO pollers) ---- */

static volatile sig_atomic_t g_stop = 0;

static void on_sigint(int sig)
{
    (void)sig;
    g_stop = 1;
}

static void install_sigint(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigint;
    sigaction(SIGINT, &sa, NULL);
}

static pthread_mutex_t g_print_lock = PTHREAD_MUTEX_INITIALIZER;

struct poller {
    const char         *tag;    /* "DEBUG" / "MDEBUG" / "CMD" */
    volatile uint32_t  *ctrl;   /* PG080 control (S_AXI) base */
    volatile uint32_t  *data;   /* PG080 data (S_AXI_FULL) base */
};

/* Format one frame as a hex dump and emit it atomically. Bytes are printed
 * in wire order: on a little-endian AXI4 read of the 64-bit RDFD, the first
 * byte on the stream is the LSB of the word. */
static void print_frame(const char *tag, unsigned frame, const uint64_t *words,
                        uint32_t len, int partial)
{
    /* header + one 24-char line per 8 bytes; frames are small (KB at most) */
    char buf[64 + ((len + 7) / 8) * 32];
    size_t pos = 0;

    pos += snprintf(buf + pos, sizeof(buf) - pos, "[%s] frame %u (%u bytes)%s:\n",
                    tag, frame, len, partial ? " (partial)" : "");
    for (uint32_t off = 0; off < len; off += 8) {
        uint32_t n = (len - off < 8) ? (len - off) : 8;
        pos += snprintf(buf + pos, sizeof(buf) - pos, "  %04x: ", off);
        for (uint32_t i = 0; i < n; i++)
            pos += snprintf(buf + pos, sizeof(buf) - pos, "%02x",
                            (unsigned)((words[off / 8] >> (8 * i)) & 0xff));
        pos += snprintf(buf + pos, sizeof(buf) - pos, "\n");
    }

    pthread_mutex_lock(&g_print_lock);
    fputs(buf, stdout);
    fflush(stdout);
    pthread_mutex_unlock(&g_print_lock);
}

/* Poll one RX-only PG080 FIFO until g_stop. Also usable as a pthread entry. */
static void *fifo_poller(void *arg)
{
    struct poller *p = (struct poller *)arg;
    volatile uint32_t *ctrl = p->ctrl;
    volatile uint64_t *d64  = (volatile uint64_t *)p->data;

    /* RX-only core reset: SRR + RDFR, then clear sticky ISR. No TX regs. */
    w32(ctrl, FIFO_SRR, FIFO_RESET_MAGIC);
    usleep(1000);
    w32(ctrl, FIFO_RDFR, FIFO_RESET_MAGIC);
    usleep(1000);
    w32(ctrl, FIFO_ISR, 0xFFFFFFFFu);

    pthread_mutex_lock(&g_print_lock);
    printf("[%s] polling (post-reset RDFO=%u)\n", p->tag, r32(ctrl, FIFO_RDFO));
    fflush(stdout);
    pthread_mutex_unlock(&g_print_lock);

    unsigned frame = 0;
    int warned_no_tlast = 0;

    while (!g_stop) {
        if (r32(ctrl, FIFO_RDFO) == 0) {
            usleep(POLL_IDLE_US);
            continue;
        }

        /* RLR is valid only once a complete (TLAST-terminated) frame is in
         * the FIFO; reading it pops the next frame's byte length. */
        uint32_t rlr = r32(ctrl, FIFO_RLR);
        if (rlr == 0) {
            if (!warned_no_tlast) {
                fprintf(stderr, "[%s] words present but no complete frame "
                                "(stream without TLAST?)\n", p->tag);
                warned_no_tlast = 1;
            }
            usleep(POLL_IDLE_US);
            continue;
        }
        warned_no_tlast = 0;

        uint32_t len     = rlr & 0x7FFFFFFFu;
        int      partial = (rlr >> 31) & 1;
        uint32_t nwords  = (len + 7) / 8;

        /* Sanity: a frame can't exceed the RX FIFO (512 x 64-bit words).
         * An implausible RLR means we've lost sync -- reset and resync. */
        if (len == 0 || len > 4096) {
            fprintf(stderr, "[%s] implausible RLR=0x%08x -- resetting RX FIFO\n",
                    p->tag, rlr);
            w32(ctrl, FIFO_RDFR, FIFO_RESET_MAGIC);
            usleep(1000);
            w32(ctrl, FIFO_ISR, 0xFFFFFFFFu);
            continue;
        }

        uint64_t words[nwords];
        for (uint32_t i = 0; i < nwords; i++) {
            asm volatile("dsb sy" ::: "memory");
            words[i] = d64[FIFO_AXI4_RDFD / 8];
        }

        frame++;
        print_frame(p->tag, frame, words, len, partial);
    }
    return NULL;
}

/* Map a poller's ctrl+data UIOs; returns 0 on success. */
static int map_poller(struct poller *p, const char *tag,
                      unsigned long ctrl_addr, unsigned long data_addr)
{
    char label[32];
    int fd_c, fd_d;
    p->tag = tag;
    snprintf(label, sizeof(label), "axi_fifo_%s (ctrl)", tag);
    p->ctrl = map_uio(ctrl_addr, label, &fd_c);
    snprintf(label, sizeof(label), "axi_fifo_%s (data)", tag);
    p->data = map_uio(data_addr, label, &fd_d);
    if (!p->ctrl || !p->data) {
        fprintf(stderr, "axi_fifo_%s not found -- was the kria app rebuilt and "
                        "reloaded with the new device-tree overlay?\n", tag);
        return -1;
    }
    return 0;
}

static int cmd_poll_one(const char *tag, unsigned long ctrl_addr,
                        unsigned long data_addr)
{
    printf("Opening UIOs:\n");
    struct poller p;
    if (map_poller(&p, tag, ctrl_addr, data_addr) < 0) return 1;

    install_sigint();
    printf("Polling %s. Press Ctrl-C to stop.\n", tag);
    fifo_poller(&p);
    printf("\nStopped.\n");
    return 0;
}

/* The pollable FIFOs, by command-line name. */
static const struct {
    const char    *name;   /* lower-case, as typed on the command line */
    const char    *tag;    /* upper-case, as printed in frame dumps */
    unsigned long  ctrl;
    unsigned long  data;
} g_fifos[] = {
    { "debug",  "DEBUG",  ADDR_FIFO_DEBUG_CTRL,  ADDR_FIFO_DEBUG_DATA  },
    { "mdebug", "MDEBUG", ADDR_FIFO_MDEBUG_CTRL, ADDR_FIFO_MDEBUG_DATA },
    { "cmd",    "CMD",    ADDR_FIFO_CMD_CTRL,    ADDR_FIFO_CMD_DATA    },
};
#define N_FIFOS ((int)(sizeof(g_fifos) / sizeof(g_fifos[0])))

/* poll [debug] [mdebug] [cmd] -- no names means all of them. */
static int cmd_poll(int nsel, char **sel)
{
    int pick[N_FIFOS] = { 0 };

    if (nsel == 0) {
        for (int i = 0; i < N_FIFOS; i++) pick[i] = 1;
    } else {
        for (int s = 0; s < nsel; s++) {
            int i;
            for (i = 0; i < N_FIFOS; i++)
                if (strcmp(sel[s], g_fifos[i].name) == 0) { pick[i] = 1; break; }
            if (i == N_FIFOS) {
                fprintf(stderr, "unknown FIFO '%s' (expected debug, mdebug or cmd)\n",
                        sel[s]);
                return 2;
            }
        }
    }

    printf("Opening UIOs:\n");
    struct poller p[N_FIFOS];
    int n = 0;
    for (int i = 0; i < N_FIFOS; i++) {
        if (!pick[i]) continue;
        if (map_poller(&p[n], g_fifos[i].tag, g_fifos[i].ctrl, g_fifos[i].data) < 0)
            return 1;
        n++;
    }

    install_sigint();
    printf("Polling");
    for (int i = 0; i < n; i++) printf("%s%s", i ? "+" : " ", p[i].tag);
    printf(". Press Ctrl-C to stop.\n");

    if (n == 1) {           /* no point spawning a thread for one FIFO */
        fifo_poller(&p[0]);
        printf("\nStopped.\n");
        return 0;
    }

    pthread_t tid[N_FIFOS];
    for (int i = 0; i < n; i++) {
        int rc = pthread_create(&tid[i], NULL, fifo_poller, &p[i]);
        if (rc != 0) {
            fprintf(stderr, "pthread_create(%s): %s\n", p[i].tag, strerror(rc));
            g_stop = 1;
            for (int j = 0; j < i; j++) pthread_join(tid[j], NULL);
            return 1;
        }
    }
    for (int i = 0; i < n; i++) pthread_join(tid[i], NULL);
    printf("\nStopped.\n");
    return 0;
}

/* ---- main ---- */

static void usage(const char *argv0)
{
    fprintf(stderr,
        "Usage: %s <command>\n"
        "  test     run the accumulator / FIFO-echo / DMA-echo tests\n"
        "  reset    pulse the NI IP reset (axi_gpio_1: 0 -> 1 -> 0) and exit\n"
        "  debug    continuously poll axi_fifo_debug and hex-dump frames\n"
        "  mdebug   continuously poll axi_fifo_mdebug and hex-dump frames\n"
        "  cmd      continuously poll axi_fifo_cmd and hex-dump frames\n"
        "  poll [debug] [mdebug] [cmd]\n"
        "           poll the named FIFOs (default: all three), one thread per FIFO\n",
        argv0);
}

int main(int argc, char **argv)
{
    if (argc < 2) { usage(argv[0]); return 2; }

    if (strcmp(argv[1], "poll") == 0)   return cmd_poll(argc - 2, argv + 2);
    if (argc != 2) { usage(argv[0]); return 2; }

    if (strcmp(argv[1], "test") == 0)   return cmd_test();
    if (strcmp(argv[1], "reset") == 0)  return cmd_reset();
    if (strcmp(argv[1], "debug") == 0)
        return cmd_poll_one("DEBUG",  ADDR_FIFO_DEBUG_CTRL,  ADDR_FIFO_DEBUG_DATA);
    if (strcmp(argv[1], "mdebug") == 0)
        return cmd_poll_one("MDEBUG", ADDR_FIFO_MDEBUG_CTRL, ADDR_FIFO_MDEBUG_DATA);
    if (strcmp(argv[1], "cmd") == 0)
        return cmd_poll_one("CMD",    ADDR_FIFO_CMD_CTRL,    ADDR_FIFO_CMD_DATA);

    usage(argv[0]);
    return 2;
}
