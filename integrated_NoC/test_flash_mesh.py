"""
test_flash_mesh.py — Cocotb: SPI flash bits -> housekeeping -> Wishbone ->
hk_boot_adapter -> mesh boot bus -> replicated tile SRAM.

Complements test_top.py (full GoL pipeline). This bench only checks that
firmware bytes from a behavioral flash model reach every tile's GF180 SRAM
memory array after housekeeping FSM completes.
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

FIRMWARE_BIN = "firmware.bin"


def load_firmware():
    p = os.path.join(os.path.dirname(__file__), FIRMWARE_BIN)
    if os.path.exists(p):
        with open(p, "rb") as f:
            return list(f.read())
    return [0xDE, 0xAD, 0xBE, 0xEF] + [0x00] * 1020


FIRMWARE = load_firmware()


async def spi_flash_stream(dut):
    """Same timing as test_top.spi_flash_model (compatible with housekeeping + boot_controller)."""
    while True:
        await FallingEdge(dut.flash_csb)
        for _ in range(32):
            await RisingEdge(dut.flash_clk)
        byte_idx = 0
        while True:
            for bit in range(7, -1, -1):
                await FallingEdge(dut.flash_clk)
                b = FIRMWARE[byte_idx] if byte_idx < len(FIRMWARE) else 0
                dut.flash_miso.value = (b >> bit) & 1
            byte_idx += 1
            if int(dut.flash_csb.value) == 1:
                break


def sram_mem_path(dut, row, col):
    return dut.mesh_inst.rows[row].cols[col].tile_inst.sram_inst.mem


@cocotb.test()
async def flash_populates_all_tile_srams(dut):
    """After hk_fsm finishes, SRAM[0:3] matches firmware for every tile."""

    cocotb.start_soon(spi_flash_stream(dut))

    dut.flash_miso.value = 0
    dut.host_csb.value = 1
    dut.host_sclk.value = 0
    dut.host_mosi.value = 0

    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    dut.rst.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst.value = 0

    cycles = 0
    limit = 5_000_000
    while cycles < limit:
        await RisingEdge(dut.clk)
        cycles += 1
        try:
            if int(dut.hk_fsm.done_loading.value) == 1:
                break
        except ValueError:
            pass
    else:
        raise AssertionError(f"Timeout waiting for housekeeping done_loading ({cycles} cycles)")

    await RisingEdge(dut.clk)

    exp0, exp1, exp2, exp3 = FIRMWARE[0], FIRMWARE[1], FIRMWARE[2], FIRMWARE[3]
    for r in range(3):
        for c in range(3):
            mem = sram_mem_path(dut, r, c)
            g0 = int(mem[0].value)
            g1 = int(mem[1].value)
            g2 = int(mem[2].value)
            g3 = int(mem[3].value)
            assert (g0, g1, g2, g3) == (
                exp0,
                exp1,
                exp2,
                exp3,
            ), f"Tile r={r} c={c} SRAM[0:3]={g0:#x},{g1:#x},{g2:#x},{g3:#x} expected {exp0:#x},{exp1:#x},{exp2:#x},{exp3:#x}"

    dut._log.info(
        "All 9 tiles: SRAM[0:3] matches firmware (%02x %02x %02x %02x)",
        exp0,
        exp1,
        exp2,
        exp3,
    )
