#include <stdint.h>

#define NOC_INJECT_BASE  0x80000000u
#define NOC_RECV_BASE    0x80000004u
#define NOC_ID_BASE      0x80000008u

#define TILE_ID(r,c)     (((uint32_t)(r) << 2) | (uint32_t)(c))
#define FLIT_DEST_SHIFT  28u
#define FLIT_BMAP_MASK   0x3FFu
#define FLIT_VALID_BIT   0x400u

#define SIG_BOOT_ALIVE   0xF0000001u
#define SIG_SEED_LIVE    0xF0000002u
#define SIG_MATH_DONE    0xF0000003u
#define SIG_GEN_STABLE   0xF0000004u

#define SIZE       10
#define MESH_ROWS  3
#define MESH_COLS  3

#define GRID_BASE       0x0500u
#define GHOST_BASE      0x0600u
#define NEXT_GRID_BASE  0x0640u

#define DEBUG_BASE           0x0700u
#define DEBUG_COL_TRACE      0x0710u
#define DEBUG_LAST_RECV_N    (DEBUG_BASE +  0)
#define DEBUG_LAST_RECV_S    (DEBUG_BASE +  4)
#define DEBUG_LAST_RECV_W    (DEBUG_BASE +  8)
#define DEBUG_LAST_RECV_E    (DEBUG_BASE + 12)
#define DEBUG_NEIGHBOR_HIST  (DEBUG_BASE + 16)
#define DEBUG_ITER_COUNT     (DEBUG_BASE + 28)
#define DEBUG_GHOST_FLAGS    (DEBUG_BASE + 32)

#define grid      ((volatile uint8_t *)GRID_BASE)
#define ghost_N   ((volatile uint8_t *)(GHOST_BASE +  0))
#define ghost_S   ((volatile uint8_t *)(GHOST_BASE + 10))
#define ghost_W   ((volatile uint8_t *)(GHOST_BASE + 20))
#define ghost_E   ((volatile uint8_t *)(GHOST_BASE + 30))
#define next_grid ((volatile uint8_t *)NEXT_GRID_BASE)

#define debug_last_recv_n   ((volatile uint32_t *)DEBUG_LAST_RECV_N)
#define debug_last_recv_s   ((volatile uint32_t *)DEBUG_LAST_RECV_S)
#define debug_last_recv_w   ((volatile uint32_t *)DEBUG_LAST_RECV_W)
#define debug_last_recv_e   ((volatile uint32_t *)DEBUG_LAST_RECV_E)
#define debug_neighbor_hist ((volatile uint8_t  *)DEBUG_NEIGHBOR_HIST)
#define debug_iter_count    ((volatile uint32_t *)DEBUG_ITER_COUNT)
#define debug_ghost_flags   ((volatile uint32_t *)DEBUG_GHOST_FLAGS)

static inline void noc_write(uint32_t word)
{
    *(volatile uint32_t *)NOC_INJECT_BASE = word;
}

static inline uint32_t noc_recv_raw(void)
{
    return *(volatile uint32_t *)NOC_RECV_BASE;
}

static inline uint32_t noc_read_my_id(void)
{
    return *(volatile uint32_t *)NOC_ID_BASE & 0xFu;
}

static inline void noc_signal(uint32_t sig_word)
{
    noc_write(sig_word);
}

__attribute__((noinline))
static uint32_t col_bitmap(int col)
{
    uint32_t accumulated_bm = 0; 
    uint32_t count = 0;
    volatile uint8_t *trace = (volatile uint8_t *)0x0710u;
    for (int r = 0; r < SIZE; r++) {
        if (grid[r * SIZE + col] & 1u) {
            uint8_t val = grid[r * SIZE + col];
            trace[r] = val; 
            count++;
            uint32_t bit = (1u << r);
            accumulated_bm = accumulated_bm + bit; 

            *debug_last_recv_e = count;
        }
    }
    return accumulated_bm;
}


static inline uint32_t recv_ghost(void)
{
    uint32_t p;
    do { p = *(volatile uint32_t *)NOC_RECV_BASE; } while (!(p & FLIT_VALID_BIT));
    return p & FLIT_BMAP_MASK;
}

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

__attribute__((section(".text.init"), naked))
void _start(void)
{
    __asm__ volatile (
        "li   sp, 0x7fc\n"
        "li   t0, 0x0600\n"
        "li   t1, 0x0628\n"
        "1: bge  t0, t1, 2f\n"
        "   sb   zero, 0(t0)\n"
        "   addi t0, t0, 1\n"
        "   j    1b\n"
        "2: li   t0, 0x0640\n"
        "li   t1, 0x06a4\n"
        "3: bge  t0, t1, 4f\n"
        "   sb   zero, 0(t0)\n"
        "   addi t0, t0, 1\n"
        "   j    3b\n"
        "4: li   t0, 0x0700\n"
        "li   t1, 0x0724\n"
        "5: bge  t0, t1, 6f\n"
        "   sb   zero, 0(t0)\n"
        "   addi t0, t0, 1\n"
        "   j    5b\n"
        "6: call main\n"
        "7: j    7b\n"
    );
}

int main(void)
{
    uint32_t my_id = noc_read_my_id();
    *(volatile uint32_t *)(0x0700u + 44u) = my_id; 
    int my_row = (int)((my_id >> 2) & 0x3u);
    int my_col = (int)(my_id & 0x3u);

    noc_signal(SIG_BOOT_ALIVE);

    for (int i = 0; i < SIZE * SIZE; i++) grid[i] = 0u;
    grid[4 * SIZE + 5] = 1; grid[5 * SIZE + 5] = 1; grid[6 * SIZE + 5] = 1;
    grid[8 * SIZE + 0] = 1; grid[9 * SIZE + 0] = 1;
    grid[8 * SIZE + 9] = 1; grid[9 * SIZE + 9] = 1;

   noc_signal(SIG_SEED_LIVE);


    uint32_t iter = 0;
    while (1) {
        *debug_iter_count = iter;
        /* TEST: only tile (0,1) sends col 0 to tile (0,0).
         * Only tile (0,0) receives.
         * Everyone else does nothing in ghost exchange.
         * Expected: tile (0,0) debug_last_recv_e = 0x300
         *           (bits 8,9 set — seed has live cells at rows 8,9 col 0)
         */
        // --- Ghost exchange: send west edge (col 0) to western neighbour ---
       if (my_col > 0) {
            // I have a western neighbour: send them my leftmost column
            uint32_t dest = TILE_ID(my_row, my_col);
            *(volatile uint32_t *)(DEBUG_BASE + 48) = 
                ((uint32_t)grid[80] << 8) | (uint32_t)grid[90]; 
            uint32_t bm9   = col_bitmap(0);          
            //uint32_t bm9   = 0x300;
            noc_write((dest << FLIT_DEST_SHIFT) | FLIT_VALID_BIT | (bm9 & FLIT_BMAP_MASK));
            *debug_ghost_flags |= 0x8;
        }

        if (my_col < MESH_COLS - 1) {
            uint32_t dest = TILE_ID(my_row, my_col + 1);
            //uint32_t bm0   = col_bitmap(0); 
            uint32_t bm0   = 0x300;
            noc_write((dest << FLIT_DEST_SHIFT) | FLIT_VALID_BIT | (bm0 & FLIT_BMAP_MASK));
            *debug_ghost_flags |= 0x4;
        }

        // Receive ghost from west neighbour (they sent their col 9 = our ghost_W)
        if (my_col > 0) {
            uint32_t bm = recv_ghost();
            for (int i = 0; i < SIZE; i++) ghost_W[i] = (bm >> i) & 1u;
        }

        // Receive ghost from east neighbour (they sent their col 0 = our ghost_E)
        if (my_col < MESH_COLS - 1) {
            uint32_t bm = recv_ghost();
            for (int i = 0; i < SIZE; i++) ghost_E[i] = (bm >> i) & 1u;
        }

        uint8_t neighbor_counts[9] = {0};
        for (int row = 0; row < SIZE; row++) {
            for (int col = 0; col < SIZE; col++) {
                int alive = grid[row * SIZE + col] & 1;
                int n     = neighbour_count(row, col);
                next_grid[row * SIZE + col] =
                    (uint8_t)(alive ? (n == 2 || n == 3) : (n == 3));
                if (n <= 8) neighbor_counts[n]++;
            }
        }
        for (int i = 0; i <= 8; i++)
            debug_neighbor_hist[i] = neighbor_counts[i];

        noc_signal(SIG_MATH_DONE);

        for (int i = 0; i < SIZE * SIZE; i++)
            grid[i] = next_grid[i];

        noc_signal(SIG_GEN_STABLE);
        iter++;
    }
    return 0;
}