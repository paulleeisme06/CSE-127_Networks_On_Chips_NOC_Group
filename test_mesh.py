import os
import struct
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge

SIZE   = 10
MESH_R = 3
MESH_C = 3

FIRMWARE_BIN_NAME = "firmware.bin"
RESET_HOLD_MS     = 2
SEED_SAMPLE_US    = 2000
ITER_TIMEOUT_US   = 5000

SRAM_GRID_BASE = 0x0500
print(f"[testbench] current_grid @ 0x{SRAM_GRID_BASE:04x}")

DEBUG_BASE          = 0x0700
DEBUG_LAST_RECV_N   = DEBUG_BASE + 0
DEBUG_LAST_RECV_S   = DEBUG_BASE + 4
DEBUG_LAST_RECV_W   = DEBUG_BASE + 8
DEBUG_LAST_RECV_E   = DEBUG_BASE + 12
DEBUG_NEIGHBOR_HIST = DEBUG_BASE + 16
DEBUG_ITER_COUNT    = DEBUG_BASE + 28
DEBUG_GHOST_FLAGS   = DEBUG_BASE + 32
DEBUG_LIVE_COUNT    = DEBUG_BASE + 36
DEBUG_COL0_BM       = DEBUG_BASE + 40
DEBUG_MY_ID         = DEBUG_BASE + 44
DEBUG_SEND_BM       = DEBUG_BASE + 48


def load_firmware_binary():
    bin_file = os.path.join(os.path.dirname(__file__), FIRMWARE_BIN_NAME)
    if os.path.exists(bin_file):
        with open(bin_file, "rb") as f:
            return list(f.read())
    return [0] * 1024


FIRMWARE = load_firmware_binary()


async def spi_flash_responder(dut):
    from cocotb.triggers import FallingEdge
    while True:
        await FallingEdge(dut.flash_cs_n)
        for _ in range(32):
            await RisingEdge(dut.flash_clk)
        byte_counter = 0
        while True:
            for bit in range(7, -1, -1):
                await FallingEdge(dut.flash_clk)
                b = FIRMWARE[byte_counter] if byte_counter < len(FIRMWARE) else 0x00
                dut.flash_miso.value = (b >> bit) & 0x1
            byte_counter += 1
            if int(dut.flash_cs_n.value) == 1:
                break


def get_tile(dut, r, c):
    return dut.rows[r].cols[c].tile_inst


def sram_read_byte(tile, cpu_addr):
    mem = tile.sram_inst.mem
    elem_bits = len(mem[0])
    if elem_bits <= 8:
        return int(mem[cpu_addr].value) & 0xFF
    bytes_per_word = elem_bits // 8
    word_index = cpu_addr // bytes_per_word
    byte_lane  = cpu_addr % bytes_per_word
    word = int(mem[word_index].value)
    return (word >> (8 * byte_lane)) & 0xFF


def sram_read_word(tile, cpu_addr):
    b0 = sram_read_byte(tile, cpu_addr)
    b1 = sram_read_byte(tile, cpu_addr + 1)
    b2 = sram_read_byte(tile, cpu_addr + 2)
    b3 = sram_read_byte(tile, cpu_addr + 3)
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)


async def wait_for_iter(tile, target_iter, timeout_us=ITER_TIMEOUT_US):
    cycles = int(timeout_us * 100)
    for _ in range(cycles):
        await RisingEdge(tile.clk)
        cur = sram_read_word(tile, DEBUG_ITER_COUNT)
        if cur >= target_iter:
            return True
    return False


def read_debug_info(tile, label=""):
    recv_n      = sram_read_word(tile, DEBUG_LAST_RECV_N)
    recv_s      = sram_read_word(tile, DEBUG_LAST_RECV_S)
    recv_w      = sram_read_word(tile, DEBUG_LAST_RECV_W)
    recv_e      = sram_read_word(tile, DEBUG_LAST_RECV_E)
    ghost_flags = sram_read_word(tile, DEBUG_GHOST_FLAGS)
    live_count  = sram_read_word(tile, DEBUG_LIVE_COUNT)
    col0_bm     = sram_read_word(tile, DEBUG_COL0_BM)
    my_id       = sram_read_word(tile, DEBUG_MY_ID)
    send_bm     = sram_read_word(tile, DEBUG_SEND_BM)

    sent_s = (ghost_flags >> 0) & 1
    sent_n = (ghost_flags >> 1) & 1
    sent_e = (ghost_flags >> 2) & 1
    sent_w = (ghost_flags >> 3) & 1

    print(f"\n{label}")
    print(f"  my_id=0x{my_id:x}  live_count={live_count} (expect 7)  col0_bm=0x{col0_bm:03x} ({col0_bm:010b})")
    print(f"  send_bm=0x{send_bm:03x} ({send_bm:010b})")
    print(f"  Ghost flags=0x{ghost_flags:02x}: sent N={sent_n} S={sent_s} E={sent_e} W={sent_w}")
    if recv_n or sent_n: print(f"  Recv N: 0x{recv_n:03x}  {recv_n:010b}")
    if recv_s or sent_s: print(f"  Recv S: 0x{recv_s:03x}  {recv_s:010b}")
    if recv_w or sent_w: print(f"  Recv W: 0x{recv_w:03x}  {recv_w:010b}")
    if recv_e or sent_e: print(f"  Recv E: 0x{recv_e:03x}  {recv_e:010b}")
    return recv_n, recv_s, recv_w, recv_e, ghost_flags


def read_debug_neighbor_histogram(tile, label=""):
    hist = [sram_read_byte(tile, DEBUG_NEIGHBOR_HIST + i) for i in range(9)]
    total = sum(hist)
    print(f"\n{label} Neighbor Histogram (total cells={total}):")
    for n in range(9):
        bar = "#" * min(hist[n], 40)
        print(f"  n={n}: {hist[n]:4d}  {bar}")
    return hist


def read_debug_iter_count(tile):
    return sram_read_word(tile, DEBUG_ITER_COUNT)


def print_debug_state(dut, r, c, label=""):
    tile     = get_tile(dut, r, c)
    iter_num = read_debug_iter_count(tile)
    hdr      = label if label else f"TILE ({r},{c})  iter={iter_num}"
    print(f"\n{'='*60}")
    print(hdr)
    print('='*60)
    read_debug_info(tile, hdr)
    read_debug_neighbor_histogram(tile, hdr)


GLOBAL_ROWS = MESH_R * SIZE
GLOBAL_COLS = MESH_C * SIZE


def expected_blinker_seed():
    exp = [[0] * SIZE for _ in range(SIZE)]
    exp[4][5] = 1
    exp[5][5] = 1
    exp[6][5] = 1
    exp[8][0] = 1
    exp[9][0] = 1
    exp[8][9] = 1
    exp[9][9] = 1
    return exp


def build_global_seed():
    tile_seed = expected_blinker_seed()
    g = [[0] * GLOBAL_COLS for _ in range(GLOBAL_ROWS)]
    for tr in range(MESH_R):
        for tc in range(MESH_C):
            for y in range(SIZE):
                for x in range(SIZE):
                    g[tr * SIZE + y][tc * SIZE + x] = tile_seed[y][x]
    return g


def gol_step_global(grid):
    new_grid = [[0] * GLOBAL_COLS for _ in range(GLOBAL_ROWS)]
    for y in range(GLOBAL_ROWS):
        for x in range(GLOBAL_COLS):
            n = 0
            for dy in [-1, 0, 1]:
                for dx in [-1, 0, 1]:
                    if dx == 0 and dy == 0:
                        continue
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < GLOBAL_COLS and 0 <= ny < GLOBAL_ROWS:
                        n += grid[ny][nx]
            cell = grid[y][x]
            new_grid[y][x] = 1 if (cell and n in (2, 3)) or (not cell and n == 3) else 0
    return new_grid


def get_tile_expected(iteration, tr, tc):
    g = GOL_GLOBAL[iteration]
    return [g[tr * SIZE + y][tc * SIZE: tc * SIZE + SIZE] for y in range(SIZE)]


GOL_GLOBAL = [build_global_seed()]
GOL_GLOBAL.append(gol_step_global(GOL_GLOBAL[0]))
GOL_GLOBAL.append(gol_step_global(GOL_GLOBAL[1]))


def read_grid_from_sram(tile):
    return [
        [sram_read_byte(tile, SRAM_GRID_BASE + y * SIZE + x) for x in range(SIZE)]
        for y in range(SIZE)
    ]


def dump_region(tile, base, count_bytes=64):
    print(f"\nDUMP @ 0x{base:04x} ({count_bytes} bytes):")
    for off in range(0, count_bytes, 16):
        chunk = [sram_read_byte(tile, base + off + i)
                 for i in range(min(16, count_bytes - off))]
        print("0x{:04x}: ".format(base + off) + " ".join(f"{b:02x}" for b in chunk))


def print_iter_comparison(dut, r, c, iteration):
    tile = get_tile(dut, r, c)
    exp  = get_tile_expected(iteration, r, c)
    act  = read_grid_from_sram(tile)
    print(f"\n===================================================")
    print(f"TILE ({r},{c})  ITERATION {iteration}")
    print("EXPECTED (Python GoL)   ACTUAL (SRAM)")
    print("---------------------------------------------------")
    mismatches = 0
    for y in range(SIZE):
        exp_row = "".join("." if exp[y][x] else "#" for x in range(SIZE))
        act_row = "".join("." if act[y][x] else "#" for x in range(SIZE))
        marker  = "" if exp_row == act_row else "  <- MISMATCH"
        if marker:
            mismatches += sum(1 for x in range(SIZE)
                              if (exp[y][x] != 0) != (act[y][x] != 0))
        print(f"{exp_row}    {act_row}{marker}")
    print("===================================================")
    return mismatches


# ---------------------------------------------------------------------------
# col_bitmap diagnostic — reads col 0 of tile (0,1) directly from SRAM and
# reconstructs what col_bitmap(0) should have returned on each iteration.
# Compares that against DEBUG_SEND_BM written by the firmware.
# ---------------------------------------------------------------------------
def diagnose_col_bitmap(dut, iteration):
    tile01 = get_tile(dut, 0, 1)

    # What col_bitmap(0) should return: read col 0 from SRAM directly.
    actual_col = [sram_read_byte(tile01, SRAM_GRID_BASE + row * SIZE + 0)
                  for row in range(SIZE)]
    expected_bm = 0
    for row, val in enumerate(actual_col):
        if val & 1:
            expected_bm |= (1 << row)

    # What the firmware computed and stored.
    firmware_bm = sram_read_word(tile01, DEBUG_SEND_BM)   # DEBUG_SEND_BM = 0x0730

    # What tile (0,0) actually received as its East ghost.
    tile00      = get_tile(dut, 0, 0)
    received_bm = sram_read_word(tile00, DEBUG_LAST_RECV_E)

    print(f"\n{'='*60}")
    print(f"col_bitmap DIAGNOSTIC — after iter {iteration}")
    print(f"{'='*60}")
    print(f"  SRAM col 0 of tile(0,1):  {actual_col}")
    print(f"  Expected bitmap (py):     0x{expected_bm:03x}  ({expected_bm:010b})")
    print(f"  Firmware DEBUG_SEND_BM:   0x{firmware_bm:03x}  ({firmware_bm:010b})")
    print(f"  tile(0,0) DEBUG_RECV_E:   0x{received_bm:03x}  ({received_bm:010b})")
    print(f"  Correct bitmap should be: 0x300  (0b1100000000) — rows 8,9 live at seed")
    print("\ncol_bitmap trace (what firmware read per row):")
    for r in range(10):
        val = sram_read_byte(tile01, 0x0710 + r)
        print(f"  row {r}: 0x{val:02x}  ({'LIVE' if val & 1 else 'dead'})")

    if firmware_bm == expected_bm:
        print("  [OK]  firmware bitmap matches SRAM — col_bitmap reads correct grid")
    else:
        print("  [FAIL] firmware bitmap does NOT match SRAM")
        print(f"         diff bits: {firmware_bm ^ expected_bm:010b}")
        if firmware_bm == 0:
            print("         -> bitmap is all-zero: grid was empty when col_bitmap ran")
            print("            (grid overwritten before col_bitmap call, or seed never written)")
        elif firmware_bm == 0x3FF:
            print("         -> bitmap is 0x3FF: still using hardcoded test value")

    if received_bm != expected_bm:
        print(f"  [FAIL] tile(0,0) received 0x{received_bm:03x} but expected 0x{expected_bm:03x}")
        if received_bm == 0x3FF:
            print("         -> tile(0,0) still has the 0x3FF hardcoded value in its ghost buffer")
    else:
        print("  [OK]  tile(0,0) received correct bitmap")
    print()


async def boot_mesh(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.flash_miso.value = 0
    if hasattr(dut, "inject_00_nw"):
        dut.inject_00_nw.value = 0
    await Timer(RESET_HOLD_MS, unit="ms")
    dut.rst.value = 0
    cocotb.start_soon(spi_flash_responder(dut))
    while int(dut.cpu_rst_n.value) == 0:
        await Timer(10, unit="us")
    dut._log.info("[boot] cpu_rst_n asserted — CPU running.")


@cocotb.test()
async def test_iter0_seed_only(dut):
    await boot_mesh(dut)

    dut._log.info(f"Waiting {SEED_SAMPLE_US} us for seed init...")
    await Timer(SEED_SAMPLE_US, unit="us")

    print("\n\n*** SEED SANITY CHECK — all tiles ***")
    for r in range(MESH_R):
        for c in range(MESH_C):
            tile = get_tile(dut, r, c)
            read_debug_info(tile, f"TILE ({r},{c}) seed sanity")
            dump_region(tile, SRAM_GRID_BASE, 100)

    print("\n\n******** ITERATION 0 (seed) ********")
    total = 0
    for r in range(MESH_R):
        for c in range(MESH_C):
            total += print_iter_comparison(dut, r, c, 0)

    if total == 0:
        dut._log.info("ALL TILES: seed matches")
    else:
        dut._log.error(f"{total} mismatches in seed")
    assert total == 0, f"Seed mismatch: {total} cells wrong."


@cocotb.test()
async def test_col_bitmap_diagnostic(dut):
    """
    Focused test: boots the mesh, waits for iter 1, then runs the col_bitmap
    diagnostic on tile (0,1) to check what col_bitmap(0) actually computed vs
    what the SRAM grid contains and what tile (0,0) received.

    Expected result:
      - SRAM col 0 of tile(0,1) has 1s at rows 8 and 9 only.
      - Expected bitmap = 0x300.
      - DEBUG_SEND_BM written by firmware == 0x300.
      - tile(0,0) DEBUG_LAST_RECV_E == 0x300.

    If DEBUG_SEND_BM is 0x000:
      The grid was all-zero when col_bitmap ran — the seed copy happened
      AFTER the ghost-exchange block, or next_grid→grid copy from iter 0
      produced zeros (next_grid was not computed correctly on iter 0).

    If DEBUG_SEND_BM is 0x3FF:
      Firmware still uses the hardcoded test value, not col_bitmap().
    """
    await boot_mesh(dut)
    await Timer(SEED_SAMPLE_US, unit="us")

    tile00 = get_tile(dut, 0, 0)
    tile01 = get_tile(dut, 0, 1)

    # ---- iter 0 col_bitmap snapshot (before any evolution) ------------------
    print("\n\n*** col_bitmap DIAGNOSTIC — ITER 0 (seed, pre-evolution) ***")
    diagnose_col_bitmap(dut, iteration=0)

    # Dump raw grid bytes of tile (0,1) so we can see the seed directly.
    print("\nTILE (0,1) grid dump at ITER 0:")
    dump_region(tile01, SRAM_GRID_BASE, 100)

    # ---- wait for iter 1 ----------------------------------------------------
    dut._log.info("Waiting for iter_count >= 1 on tile(0,0) ...")
    seen = await wait_for_iter(tile00, 1)
    if not seen:
        dut._log.warning("iter_count did not advance to 1 within timeout")
    await Timer(10, unit="us")

    print("\n\n*** col_bitmap DIAGNOSTIC — ITER 1 (post first GoL step) ***")
    diagnose_col_bitmap(dut, iteration=1)

    print("\nTILE (0,1) grid dump at ITER 1:")
    dump_region(tile01, SRAM_GRID_BASE, 100)

    print("\nTILE (0,1) full debug info at ITER 1:")
    read_debug_info(tile01, "TILE (0,1) iter=1")

    print("\nTILE (0,0) full debug info at ITER 1:")
    read_debug_info(tile00, "TILE (0,0) iter=1")

    # ---- verify iter 1 correctness for tile (0,0) ---------------------------
    print("\n\n******** ITERATION 1 — tile(0,0) only ********")
    mismatches = print_iter_comparison(dut, 0, 0, 1)
    if mismatches == 0:
        dut._log.info("tile(0,0) iter=1: PASS")
    else:
        dut._log.error(f"tile(0,0) iter=1: {mismatches} mismatches")
        dump_region(tile00, SRAM_GRID_BASE, 100)
        dump_region(tile00, 0x0600, 40)    # ghost region
        dump_region(tile00, DEBUG_BASE, 52)

    assert mismatches == 0, f"col_bitmap test: {mismatches} cell mismatches in tile(0,0) iter=1"


@cocotb.test()
async def test_gol_iter1_iter2(dut):
    await boot_mesh(dut)
    await Timer(SEED_SAMPLE_US, unit="us")

    print("\n\n*** SEED SANITY CHECK — all tiles ***")
    for r in range(MESH_R):
        for c in range(MESH_C):
            tile = get_tile(dut, r, c)
            read_debug_info(tile, f"TILE ({r},{c}) seed sanity")

    print("\n\n******** ITERATION 0 (seed) ********")
    iter0_mismatches = 0
    for r in range(MESH_R):
        for c in range(MESH_C):
            iter0_mismatches += print_iter_comparison(dut, r, c, 0)

    if iter0_mismatches == 0:
        dut._log.info("Iter 0: ALL tiles match seed")
    else:
        dut._log.error(f"Iter 0: {iter0_mismatches} mismatches")

    tile00 = get_tile(dut, 0, 0)
    dut._log.info("Waiting for debug_iter_count >= 1 ...")
    seen = await wait_for_iter(tile00, 1)
    if not seen:
        dut._log.warning("iter_count did not advance to 1")
    await Timer(10, unit="us")

    # col_bitmap diagnostic at iter 1
    print("\n\n*** col_bitmap DIAGNOSTIC at ITER 1 ***")
    diagnose_col_bitmap(dut, iteration=1)

    print("\n\n******** ITERATION 1 ********")
    iter1_mismatches = 0
    for r in range(MESH_R):
        for c in range(MESH_C):
            m = print_iter_comparison(dut, r, c, 1)
            iter1_mismatches += m
            if m > 0:
                print_debug_state(dut, r, c, f"TILE ({r},{c}) iter=1 MISMATCH debug")

    if iter1_mismatches == 0:
        dut._log.info("Iter 1: ALL tiles match")
    else:
        dut._log.error(f"Iter 1: {iter1_mismatches} mismatches")
        for r in range(MESH_R):
            for c in range(MESH_C):
                dump_region(get_tile(dut, r, c), SRAM_GRID_BASE, 100)
                dump_region(get_tile(dut, r, c), 0x0600, 40)
                dump_region(get_tile(dut, r, c), DEBUG_BASE, 52)

    dut._log.info("Waiting for debug_iter_count >= 2 ...")
    seen = await wait_for_iter(tile00, 2)
    if not seen:
        dut._log.warning("iter_count did not advance to 2")
    await Timer(10, unit="us")

    # col_bitmap diagnostic at iter 2
    print("\n\n*** col_bitmap DIAGNOSTIC at ITER 2 ***")
    diagnose_col_bitmap(dut, iteration=2)

    print("\n\n******** ITERATION 2 ********")
    iter2_mismatches = 0
    for r in range(MESH_R):
        for c in range(MESH_C):
            m = print_iter_comparison(dut, r, c, 2)
            iter2_mismatches += m
            if m > 0:
                print_debug_state(dut, r, c, f"TILE ({r},{c}) iter=2 MISMATCH debug")

    if iter2_mismatches == 0:
        dut._log.info("Iter 2: ALL tiles match")
    else:
        dut._log.error(f"Iter 2: {iter2_mismatches} mismatches")

    total = iter0_mismatches + iter1_mismatches + iter2_mismatches
    assert total == 0, (
        f"GoL test failed: iter0={iter0_mismatches}, "
        f"iter1={iter1_mismatches}, iter2={iter2_mismatches} mismatches."
    )