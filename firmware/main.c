#include <stdint.h>
#include <stddef.h>

/* ============================================================================
 * NOC Hardware Registers
 * ============================================================================
 * Two memory-mapped addresses.  Everything else is pure C.
 */
#define NOC_INJECT_BASE  0x80000000u
#define NOC_RECV_BASE    0x80000004u

/* ============================================================================
 * Flit Format — defined here in C, the single source of truth
 * ============================================================================
 *
 * The mesh router exposes a 32-bit inject port and a 32-bit receive port.
 *
 * INJECT: CPU writes 32-bit word W to NOC_INJECT_BASE.
 *   W[31:28] = destination tile ID  { dest_row[1:0], dest_col[1:0] }
 *   W[27: 0] = payload              (28 bits, completely opaque to hardware)
 *
 *   Hardware produces the 34-bit on-wire flit:
 *     flit[33]    = 1 (valid)
 *     flit[32:29] = W[31:28]  (destination)
 *     flit[28]    = 0         (hardware always clears this bit)
 *     flit[27: 0] = W[27: 0]  (payload, untouched)
 *
 * RECEIVE: CPU reads 32-bit word R from NOC_RECV_BASE.
 *   R[31:28] = 0            (hardware zeroes these)
 *   R[27: 0] = payload      (same 28 bits the sender wrote in W[27:0])
 *   Returns 0 if no flit is waiting.  Reading clears the register.
 *
 * ---- Tile ID encoding -------------------------------------------------------
 *   TILE_ID = (row << 2) | col        (4 bits, matches hardware MY_ID)
 *
 *   3x3 mesh:
 *     (0,0)=0x0  (0,1)=0x1  (0,2)=0x2
 *     (1,0)=0x4  (1,1)=0x5  (1,2)=0x6
 *     (2,0)=0x8  (2,1)=0x9  (2,2)=0xA
 *
 * ---- How external monitors observe flits ------------------------------------
 *   The testbench (or any external monitor) watches boundary wires such as
 *   monitor_22_se — the SE output of tile (2,2).  Flits addressed to
 *   non-existent tiles propagate through the mesh and appear on these
 *   boundary wires without being consumed by any eject register.
 *
 *   The protocol control signals exploit this deliberately: they use dest
 *   nibbles 0xA–0xF, all of which are off-mesh in a 3x3 grid.  The full
 *   32-bit word (dest nibble included) is the recognizable magic pattern.
 *
 *   noc_signal() sends the full 32-bit SIG_* word unchanged.  The upper
 *   nibble routes the flit; the lower 28 bits are the payload.  This is
 *   not a layering violation — the dest nibble is chosen as part of the
 *   magic pattern definition, and both fields are defined here in C.
 *
 * ---- Multi-byte data payload layout ----------------------------------------
 *   For general user data (not control signals):
 *
 *     W[31:28] = dest tile ID          (routing)
 *     W[27:24] = FLIT_TYPE_*           (frame type)
 *     W[23:16] = data byte 0
 *     W[15: 8] = data byte 1
 *     W[ 7: 0] = data byte 2
 *
 *   This gives 3 bytes per flit, 28 bits total payload per hardware flit.
 *
 * ============================================================================ */

/* ---- Tile addressing ------------------------------------------------------- */
#define TILE_ID(row, col)       (((uint32_t)(row) << 2) | (uint32_t)(col))
#define FLIT_DEST_SHIFT         28u
#define FLIT_DEST_MASK          0xF0000000u
#define FLIT_PAYLOAD_MASK       0x0FFFFFFFu   /* 28 usable payload bits        */

/* ---- Frame type nibble (bits [27:24] of the injected 32-bit word) --------- */
#define FLIT_HDR_SHIFT          24u
#define FLIT_HDR_MASK           0x0F000000u
#define FLIT_DATA_MASK          0x00FFFFFFu   /* 3 data bytes in [23:0]        */

#define FLIT_TYPE_DATA          0x1u   /* middle chunk of a byte stream        */
#define FLIT_TYPE_DATA_END      0x2u   /* last chunk of a byte stream          */
#define FLIT_TYPE_ROW           0xFu   /* GoL row broadcast (row | col-bitmap) */
/* 0x3..0xE reserved for user application                                      */

/* ---- Protocol control signals (full 32-bit word, dest in upper nibble) -----
 *
 * Upper nibble 0xA–0xD addresses tiles outside a 3x3 mesh.  The flit
 * propagates to mesh boundary wires where monitors can observe it without
 * consuming it from any tile's eject register.
 *
 * These exact 32-bit values are the interface contract with the testbench.
 * They are defined once here and never in Verilog.
 */
#define SIG_BOOT_ALIVE   0xAAAAAAAAu  /* firmware started       (dest = 0xA)  */
#define SIG_SEED_LIVE    0xBBBBBBBBu  /* initial grid seeded    (dest = 0xB)  */
#define SIG_MATH_DONE    0xDDDDDDDDu  /* next-gen computed      (dest = 0xD)  */
#define SIG_GEN_STABLE   0xCCCCCCCCu  /* current_grid stable    (dest = 0xC)  */
#define SIG_STOP         0x0DEAD001u  /* halt command from host (dest = 0x0)  */

/* ============================================================================
 * Primitive NOC accessors — the ONLY place hardware registers are touched
 * ============================================================================ */

/* Write a raw 32-bit word to the inject port.
 * Upper nibble [31:28] = hardware destination.
 * Lower 28 bits [27:0] = opaque payload.
 * Call only through the wrappers below.                                     */
static inline void noc_write(uint32_t word)
{
    volatile uint32_t *reg = (volatile uint32_t *)NOC_INJECT_BASE;
    *reg = word;
}

/* Non-blocking receive.  Returns the 28-bit payload if a flit is waiting,
 * or 0 if the register is empty.  Clears the register on read.             */
static inline uint32_t noc_recv(void)
{
    volatile uint32_t *reg = (volatile uint32_t *)NOC_RECV_BASE;
    uint32_t val = *reg & FLIT_PAYLOAD_MASK;
    if (val != 0) *reg = 0;
    return val;
}

/* ============================================================================
 * Application-level send helpers
 * ============================================================================ */

/* Send a protocol control signal.
 * Sends the full SIG_* word as-is; the upper nibble IS the destination.
 * Signals use off-mesh destinations so they appear on boundary wires.      */
static inline void noc_signal(uint32_t sig_word)
{
    noc_write(sig_word);
}

/* Inject a data flit to tile (dest_row, dest_col) with a 28-bit payload.
 * Bits [27:24] of payload28 should carry a FLIT_TYPE_* header.             */
static inline void noc_inject(uint8_t dest_row, uint8_t dest_col,
                               uint32_t payload28)
{
    uint32_t dest = TILE_ID(dest_row, dest_col);
    noc_write((dest << FLIT_DEST_SHIFT) | (payload28 & FLIT_PAYLOAD_MASK));
}

/* Send up to 3 data bytes to (dest_row, dest_col) in one flit.             */
static inline void noc_send_bytes3(uint8_t dest_row, uint8_t dest_col,
                                    uint8_t flit_type,
                                    uint8_t b0, uint8_t b1, uint8_t b2)
{
    uint32_t payload = ((uint32_t)flit_type << FLIT_HDR_SHIFT)
                     | ((uint32_t)b0 << 16)
                     | ((uint32_t)b1 <<  8)
                     | ((uint32_t)b2);
    noc_inject(dest_row, dest_col, payload);
}

/* Send an arbitrary byte buffer to (dest_row, dest_col).
 * Chunks into 3-byte flits; last flit tagged FLIT_TYPE_DATA_END.           */
static void noc_send_bytes(uint8_t dest_row, uint8_t dest_col,
                            const uint8_t *buf, size_t len)
{
    size_t i = 0;
    while (i + 3 <= len) {
        uint8_t type = (i + 3 == len) ? FLIT_TYPE_DATA_END : FLIT_TYPE_DATA;
        noc_send_bytes3(dest_row, dest_col, type,
                        buf[i], buf[i+1], buf[i+2]);
        i += 3;
    }
    if (i < len) {
        uint8_t b0 = buf[i];
        uint8_t b1 = (i + 1 < len) ? buf[i + 1] : 0u;
        noc_send_bytes3(dest_row, dest_col, FLIT_TYPE_DATA_END, b0, b1, 0);
    }
}

/* Receive helpers: unpack fields from a received 28-bit payload             */
static inline uint8_t  flit_type(uint32_t p)  { return (uint8_t)(p >> FLIT_HDR_SHIFT); }
static inline uint8_t  flit_byte0(uint32_t p) { return (uint8_t)(p >> 16); }
static inline uint8_t  flit_byte1(uint32_t p) { return (uint8_t)(p >>  8); }
static inline uint8_t  flit_byte2(uint32_t p) { return (uint8_t)(p      ); }

/* ============================================================================
 * Game of Life application
 * ============================================================================ */

#define SIZE 10

__attribute__((section(".text.init"), naked))
void _start(void) {
    __asm__ volatile (
        "li   sp, 0x400\n"
        "li   t0, 0x340\n"
        "li   t1, 0x3A4\n"
        "1:\n"
        "bge  t0, t1, 2f\n"
        "sb   zero, 0(t0)\n"
        "addi t0, t0, 1\n"
        "j    1b\n"
        "2:\n"
        "la   t0, _bss_start\n"
        "la   t1, _bss_end\n"
        "3:\n"
        "bge  t0, t1, 4f\n"
        "sw   zero, 0(t0)\n"
        "addi t0, t0, 4\n"
        "j    3b\n"
        "4:\n"
        "call main\n"
        "5: j 5b\n"
    );
}

/* current_grid in .data — bootloader copies it to SRAM with initial values.
 * Indices 45/55/65 = col 5, rows 4/5/6: a vertical blinker.               */
volatile uint8_t current_grid[SIZE * SIZE] __attribute__((section(".data"))) = {
    [45] = 1, [55] = 1, [65] = 1
};

/* next_grid scratch buffer at fixed address below current_grid              */
static volatile uint8_t * const next_grid = (volatile uint8_t *)0x340;

int main(void)
{
    /* ----------------------------------------------------------------
     * Boot sync: announce startup and that the seed is live.
     * Off-mesh dest nibbles mean the flits flow to boundary wires
     * where the testbench (or any monitor) can observe them.
     * ---------------------------------------------------------------- */
    noc_signal(SIG_BOOT_ALIVE);   /* 0xAAAAAAAA — dest 0xA, off-mesh */
    noc_signal(SIG_SEED_LIVE);    /* 0xBBBBBBBB — dest 0xB, off-mesh */

    while (1) {
        /* ----------------------------------------------------------------
         * 1. Compute next generation into next_grid (scratch at 0x340).
         * ---------------------------------------------------------------- */
        for (int row = 0; row < SIZE; row++) {
            for (int col = 0; col < SIZE; col++) {
                int idx   = row * SIZE + col;
                int above = (row > 0);
                int below = (row < SIZE - 1);
                int left  = (col > 0);
                int right = (col < SIZE - 1);
                int n = 0;
                if (above) {
                    if (left)  n += current_grid[idx - SIZE - 1] & 1;
                               n += current_grid[idx - SIZE    ] & 1;
                    if (right) n += current_grid[idx - SIZE + 1] & 1;
                }
                if (left)      n += current_grid[idx - 1] & 1;
                if (right)     n += current_grid[idx + 1] & 1;
                if (below) {
                    if (left)  n += current_grid[idx + SIZE - 1] & 1;
                               n += current_grid[idx + SIZE    ] & 1;
                    if (right) n += current_grid[idx + SIZE + 1] & 1;
                }
                int alive = current_grid[idx] & 1;
                next_grid[idx] = (uint8_t)(alive ? (n == 2 || n == 3)
                                                  : (n == 3));
            }
        }

        /* ----------------------------------------------------------------
         * 2. Signal: math done — current_grid still holds the old gen.
         *    Observer samples current_grid NOW (before commit).
         * ---------------------------------------------------------------- */
        noc_signal(SIG_MATH_DONE);   /* 0xDDDDDDDD — dest 0xD, off-mesh */

        /* ----------------------------------------------------------------
         * 3. Commit: copy next_grid -> current_grid.
         * ---------------------------------------------------------------- */
        for (int i = 0; i < SIZE * SIZE; i++)
            current_grid[i] = next_grid[i];

        /* ----------------------------------------------------------------
         * 4. Signal: current_grid stable with the new generation.
         *    Observer may safely sample current_grid until next SIG_MATH_DONE.
         * ---------------------------------------------------------------- */
        noc_signal(SIG_GEN_STABLE);  /* 0xCCCCCCCC — dest 0xC, off-mesh */

        /* ----------------------------------------------------------------
         * 5. Broadcast packed rows over the NOC.
         *
         *    Each row is one flit with FLIT_TYPE_ROW header (0xF):
         *      bits [27:24] = FLIT_TYPE_ROW (0xF)
         *      bits [23:16] = row index (0-9)
         *      bits [15: 0] = column live-cell bitmap
         *
         *    Sent to tile (2,2) so it propagates to the SE boundary wire.
         * ---------------------------------------------------------------- */
        for (int row = 0; row < SIZE; row++) {
            uint16_t bitmap = 0;
            for (int col = 0; col < SIZE; col++)
                bitmap |= (uint16_t)((current_grid[row * SIZE + col] & 1) << col);

            uint32_t payload = ((uint32_t)FLIT_TYPE_ROW  << FLIT_HDR_SHIFT)
                             | ((uint32_t)(uint8_t)row    << 16)
                             | (uint32_t)bitmap;

            noc_inject(2, 2, payload);
        }

        /* ----------------------------------------------------------------
         * 6. Check for STOP command from host.
         *    Host sends SIG_STOP to tile (0,0); noc_recv() returns its
         *    lower 28 bits.
         * ---------------------------------------------------------------- */
        if (noc_recv() == (SIG_STOP & FLIT_PAYLOAD_MASK)) {
            while (1) {}
        }
    }

    return 0;
}