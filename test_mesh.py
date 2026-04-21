import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge

SIZE   = 10
MESH_R = 3
MESH_C = 3

FIRMWARE_BIN_NAME = "firmware.bin"
RESET_HOLD_MS     = 2
SEED_SAMPLE_US    = 2000
ITER_TIMEOUT_MS   = 200   # ms — matches working version

SRAM_GRID_BASE = 0x0500
print(f"[testbench] current_grid @ 0x{SRAM_GRID_BASE:04x}")


# ── ID helpers — (row<<2)|col matches Verilog {2'(r),2'(c)} ───────────────

def tile_id(r, c):
    return (r << 2) | c

def tile_row(tid):
    return (tid >> 2) & 0x3

def tile_col(tid):
    return tid & 0x3


# ── Firmware loading ───────────────────────────────────────────────────────

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


# ── DUT accessors ──────────────────────────────────────────────────────────

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


# ── NOC signal watcher — same as working version ───────────────────────────

async def wait_for_noc_signal(dut, target_payload, timeout_ms):
    max_cycles = timeout_ms * 1000 * 100
    target = target_payload & 0x1FFFFFFF
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        for tr in range(MESH_R):
            for tc in range(MESH_C):
                try:
                    flit_raw = int(dut.rows[tr].cols[tc].tile_inst.router_inst.inject_flit.value)
                    if flit_raw & (1 << 33):
                        if (flit_raw & 0x1FFFFFFF) == target:
                            return True
                except Exception:
                    pass
        try:
            mon = int(dut.monitor_22_se.value)
            if mon & (1 << 33):
                if (mon & 0x1FFFFFFF) == target:
                    return True
        except Exception:
            pass
    return False


# ── Pure-Python GoL reference ──────────────────────────────────────────────

GLOBAL_ROWS = MESH_R * SIZE
GLOBAL_COLS = MESH_C * SIZE

def expected_blinker_seed():
    """Matches firmware seed exactly — vertical blinker only."""
    exp = [[0] * SIZE for _ in range(SIZE)]
    exp[4][5] = 1; exp[5][5] = 1; exp[6][5] = 1
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


# ── SRAM helpers ───────────────────────────────────────────────────────────

def read_grid_from_sram(tile):
    g = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            row.append(sram_read_byte(tile, SRAM_GRID_BASE + y * SIZE + x))
        g.append(row)
    return g

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
    print(f"TILE ({r},{c})  hw_id=0x{tile_id(r,c):x}  ITERATION {iteration}")
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


# ── Boot ───────────────────────────────────────────────────────────────────

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


# ── Tests ──────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_iter0_seed_only(dut):
    """Boot and verify seed matches firmware initial pattern."""
    await boot_mesh(dut)
    dut._log.info(f"Waiting {SEED_SAMPLE_US} us for seed init...")
    await Timer(SEED_SAMPLE_US, unit="us")

    tile00 = get_tile(dut, 0, 0)
    dump_region(tile00, SRAM_GRID_BASE, 100)

    print("\n[testbench] Hardware tile ID mapping (row<<2)|col:")
    for r in range(MESH_R):
        for c in range(MESH_C):
            print(f"  TILE ({r},{c}) -> hw_id=0x{tile_id(r,c):x}")

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
async def test_gol_iter1_iter2(dut):
    """Run 2 GoL iterations with ghost exchange and verify results."""
    await boot_mesh(dut)

    # Iter 0
    await Timer(SEED_SAMPLE_US, unit="us")
    print("\n\n******** ITERATION 0 (seed) ********")
    iter0_mismatches = 0
    for r in range(MESH_R):
        for c in range(MESH_C):
            iter0_mismatches += print_iter_comparison(dut, r, c, 0)
    if iter0_mismatches == 0:
        dut._log.info("Iter 0: ALL tiles match seed")
    else:
        dut._log.error(f"Iter 0: {iter0_mismatches} mismatches")

    # Iter 1 — watch for SIG_GEN_STABLE on the NOC (same as working version)
    dut._log.info("Waiting for iter 1 SIG_GEN_STABLE...")
    seen = await wait_for_noc_signal(dut, 0x10000004, ITER_TIMEOUT_MS)
    if not seen:
        dut._log.warning("SIG_GEN_STABLE not seen — fallback wait")
        await Timer(ITER_TIMEOUT_MS, unit="ms")
    else:
        await Timer(10, unit="us")
        dut._log.info("Iter 1 stable.")

    print("\n\n******** ITERATION 1 ********")
    iter1_mismatches = 0
    for r in range(MESH_R):
        for c in range(MESH_C):
            iter1_mismatches += print_iter_comparison(dut, r, c, 1)
    if iter1_mismatches == 0:
        dut._log.info("Iter 1: ALL tiles match")
    else:
        dut._log.error(f"Iter 1: {iter1_mismatches} mismatches")
        dump_region(get_tile(dut, 0, 0), SRAM_GRID_BASE, 100)
        dump_region(get_tile(dut, 0, 0), 0x0600, 40)

    # Iter 2
    dut._log.info("Waiting for iter 2 SIG_GEN_STABLE...")
    seen = await wait_for_noc_signal(dut, 0x10000004, ITER_TIMEOUT_MS)
    if not seen:
        dut._log.warning("SIG_GEN_STABLE not seen — fallback wait")
        await Timer(ITER_TIMEOUT_MS, unit="ms")
    else:
        await Timer(10, unit="us")
        dut._log.info("Iter 2 stable.")

    print("\n\n******** ITERATION 2 ********")
    iter2_mismatches = 0
    for r in range(MESH_R):
        for c in range(MESH_C):
            iter2_mismatches += print_iter_comparison(dut, r, c, 2)
    if iter2_mismatches == 0:
        dut._log.info("Iter 2: ALL tiles match")
    else:
        dut._log.error(f"Iter 2: {iter2_mismatches} mismatches")
        dump_region(get_tile(dut, 0, 0), SRAM_GRID_BASE, 100)

    total = iter0_mismatches + iter1_mismatches + iter2_mismatches
    assert total == 0, (
        f"GoL test failed: iter0={iter0_mismatches}, "
        f"iter1={iter1_mismatches}, iter2={iter2_mismatches} mismatches."
    )