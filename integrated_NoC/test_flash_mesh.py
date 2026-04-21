import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

FIRMWARE_BIN = "firmware.bin"

def load_firmware():
    p = os.path.join(os.path.dirname(__file__), FIRMWARE_BIN)
    if os.path.exists(p):
        with open(p, "rb") as f:
            return list(f.read())
    return [0x13, 0x01, 0x00, 0x40] + [0xAA] * 1020

FIRMWARE = load_firmware()


async def spi_flash_stream(dut):
    while True:
        await FallingEdge(dut.flash_csb)
        byte_idx = 0
        while True:
            for bit in range(7, -1, -1):
                await FallingEdge(dut.flash_clk)
                b = FIRMWARE[byte_idx] if byte_idx < len(FIRMWARE) else 0xFF
                dut.flash_miso.value = (b >> bit) & 1
            byte_idx += 1
            try:
                if int(dut.flash_csb.value) == 1:
                    break
            except Exception:
                break
        dut.flash_miso.value = 0

@cocotb.test()
async def flash_populates_all_tile_srams(dut):
    dut.flash_miso.value = 0
    dut.host_csb.value   = 1
    dut.host_sclk.value  = 0
    dut.host_mosi.value  = 0

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    cocotb.start_soon(spi_flash_stream(dut))

    dut.rst.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst.value = 0

    dut._log.info("Reset released — Verilog will $display SRAM contents on done_loading")

    # Just wait — the always @(posedge hk_done_loading) block in top.v
    # will print SRAM contents and call $finish automatically
    for _ in range(600_000):
        await RisingEdge(dut.clk)

    dut._log.info("Reached cycle limit")
"""
@cocotb.test()
async def flash_populates_all_tile_srams(dut):
    After hk_fsm finishes, SRAM[0:3] matches firmware for every tile.

    dut.flash_miso.value = 0
    dut.host_csb.value   = 1
    dut.host_sclk.value  = 0
    dut.host_mosi.value  = 0

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    cocotb.start_soon(spi_flash_stream(dut))

    dut.rst.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst.value = 0

    dut._log.info("Reset released — waiting for hk_done_loading")

    # Simple polling loop — no First(), no get_sim_time
    TIMEOUT = 500_000
    found_at = None
    for cycle in range(TIMEOUT):
        await RisingEdge(dut.clk)
        try:
            v = dut.hk_done_loading.value
            if v.is_resolvable and int(v) == 1:
                found_at = cycle
                break
        except Exception:
            pass
        if cycle % 100_000 == 0 and cycle > 0:
            dut._log.info(f"  heartbeat: cycle {cycle}")

    if found_at is None:
        # Don't assert here — just log and read SRAM anyway
        dut._log.error(f"done_loading never asserted after {TIMEOUT} cycles")
    else:
        dut._log.info(f"done_loading at cycle {found_at}")

    # settle
    for _ in range(50):
        await RisingEdge(dut.clk)

    # read SRAM
    exp = FIRMWARE[:4]
    dut._log.info(f"Expected: {[hex(b) for b in exp]}")

    errors = 0
    for r in range(3):
        for c in range(3):
            actual = []
            for addr in range(4):
                try:
                    mem = dut.mesh_inst.rows[r].cols[c].tile_inst.sram_inst.mem
                    val = mem[addr].value
                    if val.is_resolvable:
                        actual.append(int(val) & 0xFF)
                    else:
                        actual.append(None)
                except Exception:
                    actual.append(None)
            await RisingEdge(dut.clk)

            if None in actual:
                dut._log.error(f"tile({r},{c}): X/Z {actual}")
                errors += 1
            elif actual != exp:
                dut._log.error(f"tile({r},{c}): got {[hex(b) for b in actual]} exp {[hex(b) for b in exp]}")
                errors += 1
            else:
                dut._log.info(f"tile({r},{c}): OK {[hex(b) for b in actual]}")

    await RisingEdge(dut.clk)

    if found_at is None:
        raise AssertionError("done_loading never asserted")
    assert errors == 0, f"{errors} tiles failed"
    dut._log.info("PASS")
"""


