"""
test_mesh.py — Cocotb testbench for SERV 3×3 GoL Mesh
======================================================

KEY CHANGE from the original:
  The original testbench used blind Timer() waits (200 ms/iter), which caused
  iteration-2 to see the iteration-0 grid.  Root cause:

    original main.c called noc_read() after computing each generation, which
    BLOCKS THE CPU FOREVER because cocotb never drives NOC_RECV_BASE.  So:

      iter 0 → CPU seeds current_grid, sends 0xAAAA/0xBBBB, starts loop.
      iter 1 → CPU computes next_grid, sends 0xDDDD … then STALLS.
               current_grid has NOT been updated yet (copy happens AFTER noc_read).
      iter 2 → testbench wakes up, reads current_grid → still sees ITER 0 SEED.
               (iter 1's result is in next_grid, not current_grid)

  The fix has two parts:
    1. main.c no longer calls noc_read() as a barrier.  It computes → copies →
       signals 0xCCCC → broadcasts → loops immediately.
    2. This testbench polls the NOC inject port (via the mesh_router's
       inject_flit register, or by watching monitor_22_se) to detect the
       0xCCCC "grid stable" signal, THEN reads current_grid from SRAM.

  Handshake protocol (from revised main.c):
    0xAAAAAAAA  — firmware boot, seed is live in current_grid
    0xBBBBBBBB  — (second boot signal, legacy; ignored here)
    0xDDDDDDDD  — math done, copy about to happen (do NOT sample yet)
    0xCCCCCCCC  — copy complete, current_grid is STABLE (safe to sample)
    0x0F??xxxx  — row broadcast (optional, used for extra debug)

  We detect these by watching the NW inject port of tile(0,0):
    dut.rows[0].cols[0].tile_inst.router_inst.inject_flit
"""

import os
import struct
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge

# ============================================================
# CONFIG
# ============================================================

SIZE   = 10
MESH_R = 3
MESH_C = 3

FIRMWARE_BIN_NAME = "firmware.bin"
FIRMWARE_ELF_NAME = "firmware/firmware.elf"

RESET_HOLD_MS    = 2      # ms to hold rst=1
SEED_SAMPLE_US   = 2000   # µs after boot before we expect the seed to be live

# Per-iteration timeout: how many ms we will wait AT MOST for the 0xCCCC signal.
# SERV @ 100 MHz: ~32 cycles/instruction, ~100 cells × 8 neighbours ≈ several
# million cycles per GoL pass.  200 ms = 20 000 000 cycles — very generous.
ITER_TIMEOUT_MS  = 200

# ============================================================
# ELF symbol reader  (pure-Python, no dependencies)
# ============================================================

def read_elf_symbol(elf_path: str, sym_name: str):
    if not os.path.exists(elf_path):
        return None
    with open(elf_path, "rb") as f:
        raw = f.read()
    if raw[0:4] != b'\x7fELF':
        return None
    e_shoff     = struct.unpack_from("<I", raw, 0x20)[0]
    e_shentsize = struct.unpack_from("<H", raw, 0x2e)[0]
    e_shnum     = struct.unpack_from("<H", raw, 0x30)[0]

    def sh(i):
        off = e_shoff + i * e_shentsize
        return struct.unpack_from("<IIIIIIIIII", raw, off)

    SHT_SYMTAB = 2
    symtab_sh = strtab_sh = None
    for i in range(e_shnum):
        s = sh(i)
        if s[1] == SHT_SYMTAB:
            symtab_sh = s
            strtab_sh = sh(s[6])
            break
    if symtab_sh is None:
        return None

    sym_offset  = symtab_sh[4]
    sym_size    = symtab_sh[5]
    sym_entsize = symtab_sh[9]
    str_offset  = strtab_sh[4]

    for i in range(sym_size // sym_entsize):
        off = sym_offset + i * sym_entsize
        st_name  = struct.unpack_from("<I", raw, off)[0]
        st_value = struct.unpack_from("<I", raw, off + 4)[0]
        name_start = str_offset + st_name
        name_end   = raw.index(b'\x00', name_start)
        name       = raw[name_start:name_end].decode("ascii", errors="replace")
        if name == sym_name:
            return st_value
    return None

# ============================================================
# Firmware loader
# ============================================================

def load_firmware_binary():
    bin_file = os.path.join(os.path.dirname(__file__), FIRMWARE_BIN_NAME)
    if os.path.exists(bin_file):
        with open(bin_file, "rb") as f:
            return list(f.read())
    return [0] * 1024

FIRMWARE = load_firmware_binary()

# ============================================================
# Resolve SRAM_GRID_BASE from ELF symbol table
# ============================================================

_elf_path  = os.path.join(os.path.dirname(__file__), FIRMWARE_ELF_NAME)
_grid_addr = read_elf_symbol(_elf_path, "current_grid")

if _grid_addr is None:
    _grid_addr = read_elf_symbol(_elf_path, "_bss_start")

if _grid_addr is None:
    _fw_bin = os.path.join(os.path.dirname(__file__), FIRMWARE_BIN_NAME)
    if os.path.exists(_fw_bin):
        _grid_addr = os.path.getsize(_fw_bin)

if _grid_addr is not None:
    SRAM_GRID_BASE = _grid_addr
    print(f"[testbench] current_grid @ 0x{SRAM_GRID_BASE:04x} ({SRAM_GRID_BASE})")
else:
    import warnings
    warnings.warn("Could not determine current_grid address. SRAM_GRID_BASE=0.", stacklevel=1)
    SRAM_GRID_BASE = 0x0000

# ============================================================
# SPI Flash Model
# ============================================================

async def spi_flash_responder(dut):
    """
    SPI flash responder matched to boot_loader.v timing.
    Drives MISO on FALLING edge of flash_clk (same edge the bootloader samples).
    """
    from cocotb.triggers import FallingEdge
    while True:
        await FallingEdge(dut.flash_cs_n)
        for _ in range(32):
            await RisingEdge(dut.flash_clk)
        byte_counter = 0
        while True:
            for bit in range(7, -1, -1):
                await FallingEdge(dut.flash_clk)
                current_byte = FIRMWARE[byte_counter] if byte_counter < len(FIRMWARE) else 0x00
                dut.flash_miso.value = (current_byte >> bit) & 0x1
            byte_counter += 1
            if int(dut.flash_cs_n.value) == 1:
                break

# ============================================================
# DUT hierarchy helpers
# ============================================================

def get_tile(dut, r, c):
    return dut.rows[r].cols[c].tile_inst

def sram_read_byte(tile, cpu_addr: int) -> int:
    mem = tile.sram_inst.mem
    elem_bits = len(mem[0])
    if elem_bits <= 8:
        return int(mem[cpu_addr].value) & 0xFF
    bytes_per_word = elem_bits // 8
    word_index = cpu_addr // bytes_per_word
    byte_lane  = cpu_addr  % bytes_per_word
    word = int(mem[word_index].value)
    return (word >> (8 * byte_lane)) & 0xFF

# ============================================================
# NOC signal monitor
# ============================================================

def read_inject_flit(dut, r=0, c=0) -> int:
    """
    Read the current inject_flit from tile(r,c)'s router.
    Returns the 29-bit payload (bits [28:0]) if the flit is valid, else 0.
    The inject_flit register is valid for one clock cycle after a NOC write.
    We read it combinatorially/polling style between rising edges.
    """
    try:
        flit = int(dut.rows[r].cols[c].tile_inst.router_inst.inject_flit.value)
        if flit & (1 << 33):   # Valid bit
            return flit & 0x1FFFFFFF
    except Exception:
        pass
    return 0

async def wait_for_noc_signal(dut, target_payload: int, timeout_ms: int,
                               r: int = 0, c: int = 0) -> bool:
    """
    Poll tile(r,c)'s inject_flit on every rising clock edge until we see
    a flit whose lower 29 bits match target_payload, or we time out.

    Returns True if the signal was seen, False on timeout.

    Why inject_flit and not the router output ports?
      inject_flit is registered exactly one cycle after the CPU's Wishbone
      write hits NOC_INJECT_BASE, so it's the earliest observable point.
      The router output ports are one cycle further delayed and get cleared
      to 0 on the next cycle, making them harder to catch reliably.
    """
    # Convert timeout to clock cycles (10 ns per cycle @ 100 MHz)
    max_cycles = timeout_ms * 1000 * 100  # ms → ns → cycles

    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        flit_raw = int(dut.rows[r].cols[c].tile_inst.router_inst.inject_flit.value)
        if flit_raw & (1 << 33):
            payload = flit_raw & 0x1FFFFFFF
            if payload == (target_payload & 0x1FFFFFFF):
                return True
    return False

# ============================================================
# Debug helpers
# ============================================================

def dump_region(tile, base, count_bytes=64):
    print(f"\nDUMP @ 0x{base:04x} ({count_bytes} bytes):")
    for off in range(0, count_bytes, 16):
        chunk = [sram_read_byte(tile, base + off + i) for i in range(min(16, count_bytes - off))]
        print("0x{:04x}: ".format(base + off) + " ".join(f"{b:02x}" for b in chunk))

def dump_next_grid(dut, r=0, c=0):
    """Dump next_grid (at 0x340) for debug — the computed-but-not-yet-committed result."""
    tile = get_tile(dut, r, c)
    NEXT_GRID_BASE = 0x340
    print(f"\n[DEBUG] next_grid (0x{NEXT_GRID_BASE:04x}) for tile({r},{c}):")
    for row in range(SIZE):
        row_vals = [sram_read_byte(tile, NEXT_GRID_BASE + row * SIZE + col) for col in range(SIZE)]
        print("  row {:2d}: {}".format(row, " ".join(f"{v}" for v in row_vals)))

# ============================================================
# Pure-Python GoL step
# ============================================================

def expected_blinker_seed():
    exp = [[0] * SIZE for _ in range(SIZE)]
    cx = SIZE // 2   # col 5
    cy = SIZE // 2   # row 5
    exp[cy - 1][cx] = 1
    exp[cy    ][cx] = 1
    exp[cy + 1][cx] = 1
    return exp

def gol_step(grid):
    new_grid = [[0] * SIZE for _ in range(SIZE)]
    for y in range(SIZE):
        for x in range(SIZE):
            neighbors = 0
            for dy in range(-1, 2):
                for dx in range(-1, 2):
                    if dx == 0 and dy == 0:
                        continue
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < SIZE and 0 <= ny < SIZE:
                        if grid[ny][nx]:
                            neighbors += 1
            cell = grid[y][x]
            if cell == 1:
                new_grid[y][x] = 1 if neighbors in (2, 3) else 0
            else:
                new_grid[y][x] = 1 if neighbors == 3 else 0
    return new_grid

GOL_ITER = [expected_blinker_seed()]
GOL_ITER.append(gol_step(GOL_ITER[0]))
GOL_ITER.append(gol_step(GOL_ITER[1]))

# ============================================================
# SRAM grid reader
# ============================================================

def read_grid_from_sram(tile):
    g = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            addr = SRAM_GRID_BASE + y * SIZE + x
            row.append(sram_read_byte(tile, addr))
        g.append(row)
    return g

def print_iter_comparison(dut, r, c, iteration):
    tile = get_tile(dut, r, c)
    exp  = GOL_ITER[iteration]
    act  = read_grid_from_sram(tile)

    print("\n===================================================")
    print(f"TILE ({r},{c})  ITERATION {iteration}")
    print("EXPECTED (Python GoL)   ACTUAL (SRAM)")
    print("---------------------------------------------------")
    mismatches = 0
    for y in range(SIZE):
        exp_row = "".join("." if exp[y][x] else "#" for x in range(SIZE))
        act_row = "".join("." if act[y][x] else "#" for x in range(SIZE))
        marker  = "" if exp_row == act_row else "  ← MISMATCH"
        if marker:
            mismatches += len([1 for x in range(SIZE) if (exp[y][x] != 0) != (act[y][x] != 0)])
        print(f"{exp_row}    {act_row}{marker}")
    print("===================================================")
    return mismatches

# ============================================================
# Common boot sequence
# ============================================================

async def boot_mesh(dut):
    """Start clock, reset, load SPI firmware, wait for cpu_rst_n."""
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

# ============================================================
# TEST 1: Iteration 0 seed check only
# ============================================================

@cocotb.test()
async def test_iter0_seed_only(dut):
    """Boot, wait for seed init, compare SRAM vs expected blinker seed."""
    await boot_mesh(dut)
    dut._log.info(f"Waiting {SEED_SAMPLE_US} µs for seed init...")
    await Timer(SEED_SAMPLE_US, unit="us")

    tile00 = get_tile(dut, 0, 0)
    dut._log.info(f"SRAM mem element width = {len(tile00.sram_inst.mem[0])} bits")
    dut._log.info(f"SRAM_GRID_BASE = 0x{SRAM_GRID_BASE:04x}")
    dump_region(tile00, SRAM_GRID_BASE, 100)

    print("\n\n******** ITERATION 0 (seed) ********")
    total = 0
    for r in range(MESH_R):
        for c in range(MESH_C):
            total += print_iter_comparison(dut, r, c, 0)

    if total == 0:
        dut._log.info("✓ ALL TILES: seed matches expected blinker pattern")
    else:
        dut._log.error(f"✗ {total} cell mismatches across all tiles")
    assert total == 0, f"Seed mismatch: {total} cells wrong."

# ============================================================
# TEST 2: Iterations 0, 1, 2 with NOC handshake
# ============================================================

@cocotb.test()
async def test_gol_iter1_iter2(dut):
    """
    Boot the mesh, then use NOC handshake signals to sample SRAM at exactly
    the right moments:

      Signal 0xAAAA / 0xBBBB  → seed is live, sample iter 0
      Signal 0xCCCCCCCC       → iter N complete, current_grid stable → sample
      Signal 0xDDDDDDDD       → math done but copy NOT yet committed → skip

    This guarantees we never read current_grid while the CPU is mid-copy,
    and we always read the generation the CPU JUST committed.
    """
    await boot_mesh(dut)

    # ----- Iter 0: wait for seed then sample -----
    dut._log.info(f"Waiting {SEED_SAMPLE_US} µs for seed init...")
    await Timer(SEED_SAMPLE_US, unit="us")

    print("\n\n******** ITERATION 0 (seed) ********")
    iter0_mismatches = 0
    for r in range(MESH_R):
        for c in range(MESH_C):
            iter0_mismatches += print_iter_comparison(dut, r, c, 0)
    if iter0_mismatches == 0:
        dut._log.info("✓ Iter 0: ALL tiles match expected seed")
    else:
        dut._log.error(f"✗ Iter 0: {iter0_mismatches} mismatches")

    # ----- Iter 1: wait for 0xCCCCCCCC then sample -----
    dut._log.info(f"[iter_test] Waiting for iter 1 completion signal (0xCCCCCCCC)...")
    seen = await wait_for_noc_signal(dut, 0x0CCCCCCC, ITER_TIMEOUT_MS)
    #                                          ^^^^^^^^ lower 29 bits of 0xCCCCCCCC

    if not seen:
        # Fallback: maybe already past it, or signal format differs — try a brief extra wait
        dut._log.warning("[iter_test] 0xCCCC not seen in time — waiting 200ms fallback")
        await Timer(ITER_TIMEOUT_MS, unit="ms")
    else:
        # Give SERV a tiny margin to finish the last current_grid[i] = next_grid[i] store
        await Timer(5, unit="us")
        dut._log.info("[iter_test] 0xCCCC signal received — iter 1 stable.")

    print("\n\n******** ITERATION 1 ********")
    iter1_mismatches = 0
    for r in range(MESH_R):
        for c in range(MESH_C):
            iter1_mismatches += print_iter_comparison(dut, r, c, 1)
    if iter1_mismatches == 0:
        dut._log.info("✓ Iter 1: ALL tiles match expected")
    else:
        dut._log.error(f"✗ Iter 1: {iter1_mismatches} mismatches")
        # Extra debug: dump next_grid and current_grid for tile(0,0)
        dut._log.info("[DEBUG] Dumping SRAM regions for tile(0,0):")
        dump_next_grid(dut, 0, 0)
        dump_region(get_tile(dut, 0, 0), SRAM_GRID_BASE, 100)

    # ----- Iter 2: wait for second 0xCCCCCCCC then sample -----
    dut._log.info(f"[iter_test] Waiting for iter 2 completion signal (0xCCCCCCCC)...")
    seen = await wait_for_noc_signal(dut, 0x0CCCCCCC, ITER_TIMEOUT_MS)

    if not seen:
        dut._log.warning("[iter_test] 0xCCCC not seen in time — waiting 200ms fallback")
        await Timer(ITER_TIMEOUT_MS, unit="ms")
    else:
        await Timer(5, unit="us")
        dut._log.info("[iter_test] 0xCCCC signal received — iter 2 stable.")

    print("\n\n******** ITERATION 2 ********")
    iter2_mismatches = 0
    for r in range(MESH_R):
        for c in range(MESH_C):
            iter2_mismatches += print_iter_comparison(dut, r, c, 2)
    if iter2_mismatches == 0:
        dut._log.info("✓ Iter 2: ALL tiles match expected")
    else:
        dut._log.error(f"✗ Iter 2: {iter2_mismatches} mismatches")
        dut._log.info("[DEBUG] Dumping SRAM regions for tile(0,0):")
        dump_next_grid(dut, 0, 0)
        dump_region(get_tile(dut, 0, 0), SRAM_GRID_BASE, 100)

    total = iter0_mismatches + iter1_mismatches + iter2_mismatches
    assert total == 0, (
        f"GoL iteration test failed: iter0={iter0_mismatches}, "
        f"iter1={iter1_mismatches}, iter2={iter2_mismatches} mismatches."
    )