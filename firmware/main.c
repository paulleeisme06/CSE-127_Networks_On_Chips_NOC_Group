#include <stdint.h>

#define NOC_INJECT_BASE  0x80000000u
#define NOC_RECV_BASE    0x80000004u
#define NOC_ID_BASE      0x80000008u

/*
 * ID encoding — matches Verilog mesh_3x3.v exactly:
 *   mesh_tile #(.TILE_ID({2'(r), 2'(c)}))
 * i.e. MY_ID = (row << 2) | col
 */
#define TILE_ID(r,c)  (((uint32_t)(r) << 2) | (uint32_t)(c))
#define TILE_ROW(id)  (((uint32_t)(id) >> 2) & 0x3u)
#define TILE_COL(id)  (((uint32_t)(id)) & 0x3u)

#define FLIT_DEST_SHIFT   28u
#define FLIT_BMAP_MASK    0x3FFu
#define FLIT_VALID_BIT    0x400u

/*
 * Off-mesh protocol signals — dest=0xF, bit10 clear so recv_ghost()
 * never mistakes them for ghost flits.
 */
#define SIG_BOOT_ALIVE   0xF0000001u
#define SIG_SEED_LIVE    0xF0000002u
#define SIG_MATH_DONE    0xF0000003u
#define SIG_GEN_STABLE   0xF0000004u
#define SIG_STOP         0xF0000005u

/*
 * Parameterisation:
 *   PHYS_ROWS/COLS  — physical 3x3 hardware, never change.
 *   ACTIVE_ROWS/COLS — logical GoL region (top-left corner of mesh).
 *   Tiles outside the active region call idle_tile_forever().
 *   To run 2x2: set ACTIVE_ROWS=2, ACTIVE_COLS=2.
 */
#define PHYS_ROWS    3
#define PHYS_COLS    3
#define ACTIVE_ROWS  3
#define ACTIVE_COLS  3

#define SIZE  10

#define GRID_BASE       0x0500u
#define GHOST_BASE      0x0600u
#define NEXT_GRID_BASE  0x0640u

#define grid      ((volatile uint8_t *)GRID_BASE)
#define ghost_N   ((volatile uint8_t *)(GHOST_BASE +  0))
#define ghost_S   ((volatile uint8_t *)(GHOST_BASE + 10))
#define ghost_W   ((volatile uint8_t *)(GHOST_BASE + 20))
#define ghost_E   ((volatile uint8_t *)(GHOST_BASE + 30))
#define next_grid ((volatile uint8_t *)NEXT_GRID_BASE)

/* ── NOC primitives ─────────────────────────────────────────────────────── */

static inline void noc_write(uint32_t word)
{
    *(volatile uint32_t *)NOC_INJECT_BASE = word;
}

/*
 * noc_recv_raw — reads the eject FIFO head WITHOUT clearing it.
 * recv_ghost() MUST use this.  The Verilog pops the FIFO one cycle
 * after the CPU read (cpu_read_q).  If firmware also clears the
 * register, the flit is lost before recv_ghost() can confirm
 * FLIT_VALID_BIT — causing an infinite hang.
 */
static inline uint32_t noc_recv_raw(void)
{
    return *(volatile uint32_t *)NOC_RECV_BASE;
}

/* noc_recv — masked+clearing read, used only for stop-signal polling */
static inline uint32_t noc_recv(void)
{
    volatile uint32_t *reg = (volatile uint32_t *)NOC_RECV_BASE;
    uint32_t val = *reg & 0x0FFFFFFFu;
    if (val != 0) *reg = 0;
    return val;
}

static inline uint32_t noc_read_my_id(void)
{
    return *(volatile uint32_t *)NOC_ID_BASE & 0xFu;
}

static inline void noc_signal(uint32_t sig_word)
{
    noc_write(sig_word);
}

/* ── Bitmap helpers ─────────────────────────────────────────────────────── */

__attribute__((noinline))
static uint32_t row_bitmap(int row)
{
    uint32_t bm = 0;
    for (int c = 0; c < SIZE; c++)
        bm |= (uint32_t)(grid[row * SIZE + c] & 1u) << c;
    return bm & FLIT_BMAP_MASK;
}

__attribute__((noinline))
static uint32_t col_bitmap(int col)
{
    uint32_t bm = 0;
    for (int r = 0; r < SIZE; r++)
        bm |= (uint32_t)(grid[r * SIZE + col] & 1u) << r;
    return bm & FLIT_BMAP_MASK;
}

/* ── Ghost send / receive ───────────────────────────────────────────────── */

static inline void send_ghost(uint32_t dest_id, uint32_t bm)
{
    noc_write((dest_id << FLIT_DEST_SHIFT) | FLIT_VALID_BIT | (bm & FLIT_BMAP_MASK));
}

/*
 * recv_ghost — spins on noc_recv_raw() until FLIT_VALID_BIT (bit10) is set.
 * Empty FIFO reads return 0x00000000 (bit10=0) so the spin is safe.
 * Uses raw read — do NOT switch to noc_recv() here.
 */
static inline uint32_t recv_ghost(void)
{
    uint32_t p;
    do { p = noc_recv_raw(); } while (!(p & FLIT_VALID_BIT));
    return p & FLIT_BMAP_MASK;
}

/* ── Startup ────────────────────────────────────────────────────────────── */

__attribute__((section(".text.init"), naked))
void _start(void)
{
    __asm__ volatile (
        "li   sp, 0x7fc\n"

        /* zero ghost region 0x0600–0x0627 */
        "li   t0, 0x0600\n"
        "li   t1, 0x0628\n"
        "1: bge  t0, t1, 2f\n"
        "   sb   zero, 0(t0)\n"
        "   addi t0, t0, 1\n"
        "   j    1b\n"

        /* zero next_grid 0x0640–0x06a3 */
        "2: li   t0, 0x0640\n"
        "   li   t1, 0x06a4\n"
        "3: bge  t0, t1, 4f\n"
        "   sb   zero, 0(t0)\n"
        "   addi t0, t0, 1\n"
        "   j    3b\n"

        "4: call main\n"
        "5: j    5b\n"
    );
}

/* ── Ghost exchange ─────────────────────────────────────────────────────── */

static void ghost_exchange(int my_row, int my_col,
                           int has_N, int has_S,
                           int has_W, int has_E)
{
    /* Phase 1 — all tiles send before anyone blocks */
    if (has_S) send_ghost(TILE_ID(my_row+1, my_col), row_bitmap(SIZE-1));
    if (has_N) send_ghost(TILE_ID(my_row-1, my_col), row_bitmap(0));
    if (has_E) send_ghost(TILE_ID(my_row, my_col+1), col_bitmap(SIZE-1));
    if (has_W) send_ghost(TILE_ID(my_row, my_col-1), col_bitmap(0));

    /* Phase 2 — receive in fixed N→S→E→W order */
    if (has_N) {
        uint32_t bm = recv_ghost();
        for (int i = 0; i < SIZE; i++) ghost_N[i] = (bm >> i) & 1u;
    }
    if (has_S) {
        uint32_t bm = recv_ghost();
        for (int i = 0; i < SIZE; i++) ghost_S[i] = (bm >> i) & 1u;
    }
    if (has_E) {
        uint32_t bm = recv_ghost();
        for (int i = 0; i < SIZE; i++) ghost_E[i] = (bm >> i) & 1u;
    }
    if (has_W) {
        uint32_t bm = recv_ghost();
        for (int i = 0; i < SIZE; i++) ghost_W[i] = (bm >> i) & 1u;
    }
}

/* ── GoL neighbour count ────────────────────────────────────────────────── */

static inline int neighbour_count(int row, int col)
{
    int idx   = row * SIZE + col;
    int above = (row > 0);
    int below = (row < SIZE - 1);
    int left  = (col > 0);
    int right = (col < SIZE - 1);
    int n = 0;

    if (above) {
        if (left)  n += grid[idx - SIZE - 1] & 1;
                   n += grid[idx - SIZE    ] & 1;
        if (right) n += grid[idx - SIZE + 1] & 1;
    } else {
        if (left)  n += ghost_N[col - 1] & 1;
                   n += ghost_N[col    ] & 1;
        if (right) n += ghost_N[col + 1] & 1;
    }

    if (left)  n += grid[idx - 1] & 1;
    else       n += ghost_W[row] & 1;

    if (right) n += grid[idx + 1] & 1;
    else       n += ghost_E[row] & 1;

    if (below) {
        if (left)  n += grid[idx + SIZE - 1] & 1;
                   n += grid[idx + SIZE    ] & 1;
        if (right) n += grid[idx + SIZE + 1] & 1;
    } else {
        if (left)  n += ghost_S[col - 1] & 1;
                   n += ghost_S[col    ] & 1;
        if (right) n += ghost_S[col + 1] & 1;
    }

    return n;
}

/* ── Idle (inactive tiles) ──────────────────────────────────────────────── */

 /* That is what gives the attached version “inactive tile support.” Tiles still have hardware IDs, 
 * but they do not seed, ghost-exchange, compute, or commit if they are outside the active region.
 */
 
static void idle_tile_forever(void)
{
    while (1) {
        uint32_t p = noc_recv();
        if (p == (SIG_STOP & 0x0FFFFFFFu)) while (1) {}
    }
}

/* ── Main ───────────────────────────────────────────────────────────────── */

int main(void)
{
    uint32_t my_id = noc_read_my_id();
    int my_row = (int)TILE_ROW(my_id);
    int my_col = (int)TILE_COL(my_id);

    /* Gate out-of-bounds physical tiles first */
    if (my_row >= PHYS_ROWS || my_col >= PHYS_COLS)
        idle_tile_forever();

    /* Gate tiles outside the active logical mesh */
    if (my_row >= ACTIVE_ROWS || my_col >= ACTIVE_COLS)
        idle_tile_forever();

    int has_N = (my_row > 0);
    int has_S = (my_row < ACTIVE_ROWS - 1);
    int has_W = (my_col > 0);
    int has_E = (my_col < ACTIVE_COLS - 1);

    noc_signal(SIG_BOOT_ALIVE);

    /* Seed — vertical blinker only (matches test_mesh.py expected_blinker_seed) */
    for (int i = 0; i < SIZE * SIZE; i++) grid[i] = 0u;
    grid[4*SIZE+5] = 1; grid[5*SIZE+5] = 1; grid[6*SIZE+5] = 1;

    noc_signal(SIG_SEED_LIVE);

    while (1) {
        ghost_exchange(my_row, my_col, has_N, has_S, has_W, has_E);

        for (int row = 0; row < SIZE; row++) {
            for (int col = 0; col < SIZE; col++) {
                int alive = grid[row * SIZE + col] & 1;
                int n     = neighbour_count(row, col);
                next_grid[row * SIZE + col] =
                    (uint8_t)(alive ? (n==2||n==3) : (n==3));
            }
        }

        noc_signal(SIG_MATH_DONE);

        for (int i = 0; i < SIZE * SIZE; i++)
            grid[i] = next_grid[i];

        noc_signal(SIG_GEN_STABLE);
    }

    return 0;
}