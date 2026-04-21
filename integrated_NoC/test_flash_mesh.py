"""
test_flash_mesh.py — Cocotb: SPI flash -> housekeeping -> mesh boot bus -> all tile SRAMs.
"""

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
    # fallback: known non-zero pattern so mismatches are obvious
    return [0x13, 0x01, 0x00, 0x40] + [0xAA] * 1020

FIRMWARE = load_firmware()


async def spi_flash_stream(dut):
    """
    Behavioral SPI flash — responds to housekeeping FSM.
    No command-skip: housekeeping FSM asserts CSB then immediately
    clocks data on falling edges of flash_clk.
    If your FSM DOES send a command word first, change skip_bits below.
    """
    SKIP_BITS = 0   # set to 32 if FSM sends a command word before data

    while True:
        await FallingEdge(dut.flash_csb)

        # skip command bits if FSM sends them
        for _ in range(SKIP_BITS):
            await RisingEdge(dut.flash_clk)

        byte_idx = 0
        while True:
            # drive each bit on falling edge so it's stable for rising-edge sample
            for bit in range(7, -1, -1):
                await FallingEdge(dut.flash_clk)
                b = FIRMWARE[byte_idx] if byte_idx < len(FIRMWARE) else 0xFF
                dut.flash_miso.value = (b >> bit) & 1
            byte_idx += 1

            # stop when CSB deasserts
            try:
                if int(dut.flash_csb.value) == 1:
                    break
            except Exception:
                break

        dut.flash_miso.value = 0


def sram_read_byte(dut, row, col, addr):
    """Safe SRAM read — returns None if value contains X/Z."""
    try:
        mem = dut.mesh_inst.rows[row].cols[col].tile_inst.sram_inst.mem
        val = mem[addr].value
        if val.is_resolvable:
            return int(val) & 0xFF
        return None   # X or Z present
    except Exception as e:
        return None


def find_done_loading(dut):
    """
    Try several hierarchy paths for done_loading.
    Update these to match your actual instance names in top.v.
    
    candidates = [
        lambda: dut.hk_inst.FSM.done_loading,        # if topmod=hk_inst, fsm=FSM
        lambda: dut.hk_inst.done_loading,             # if topmod exposes it at top
        lambda: dut.topmod_inst.FSM.done_loading,
        lambda: dut.housekeeping_inst.done_loading,
    ]
    for path in candidates:
        try:
            sig = path()
            _ = sig.value   # probe it — throws if path is wrong
            return sig
        except Exception:
            continue
    return None
    """
    try:
        sig = dut.hk_done_loading   # wire at top level
        _ = sig.value
        return sig
    except Exception:
        pass
    try:
        sig = dut.hk_fsm.done_loading   # direct into FSM
        _ = sig.value
        return sig
    except Exception:
        pass
    return None


@cocotb.test()
async def flash_populates_all_tile_srams(dut):
    """After hk_fsm finishes, SRAM[0:3] matches firmware for every tile."""

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

    done_sig = dut.hk_done_loading

    TIMEOUT = 500_000
    found_at = None
    for cycle in range(TIMEOUT):
        await RisingEdge(dut.clk)
        try:
            v = done_sig.value
            if v.is_resolvable and int(v) == 1:
                found_at = cycle
                break
        except Exception:
            pass
    
    if found_at is None:
        raise AssertionError(f"Timeout: done_loading never asserted after {TIMEOUT} cycles")
    
    dut._log.info(f"done_loading asserted at cycle {found_at}")

    # Run several more cycles to let final SRAM write complete and settle.
    # The adapter may still be mid-write when done_loading asserts.
    for _ in range(20):
        await RisingEdge(dut.clk)

    # ---- SRAM readback ----
    # Read while simulation is still actively running (clock ticking).
    # Do NOT stop the clock before reading.
    exp = FIRMWARE[:4]
    dut._log.info(f"Expected SRAM[0:3] = {[f'0x{b:02x}' for b in exp]}")

    results = {}
    for r in range(3):
        for c in range(3):
            row_result = []
            try:
                mem = dut.mesh_inst.rows[r].cols[c].tile_inst.sram_inst.mem
                for addr in range(4):
                    try:
                        val = mem[addr].value
                        if hasattr(val, 'is_resolvable'):
                            if val.is_resolvable:
                                row_result.append(int(val) & 0xFF)
                            else:
                                row_result.append(None)  # X/Z
                        else:
                            row_result.append(int(val) & 0xFF)
                    except Exception as e:
                        dut._log.warning(f"tile({r},{c}) addr={addr} read failed: {e}")
                        row_result.append(None)
            except Exception as e:
                dut._log.error(f"tile({r},{c}) mem access failed: {e}")
                row_result = [None, None, None, None]
            
            results[(r, c)] = row_result

    # keep clock running during error reporting
    await RisingEdge(dut.clk)

    errors = 0
    for r in range(3):
        for c in range(3):
            actual = results[(r, c)]
            if None in actual:
                dut._log.error(
                    f"tile({r},{c}): contains X/Z → {actual} "
                    f"(boot_wen may not have fired, or SRAM CEN never asserted)"
                )
                errors += 1
            elif actual != exp:
                dut._log.error(
                    f"tile({r},{c}): MISMATCH "
                    f"got={[f'0x{b:02x}' for b in actual]} "
                    f"exp={[f'0x{b:02x}' for b in exp]}"
                )
                errors += 1
            else:
                dut._log.info(f"tile({r},{c}): ✓  {[f'0x{b:02x}' for b in actual]}")

    assert errors == 0, f"{errors} tile(s) failed SRAM verification"
    dut._log.info("✓ All 9 tiles: SRAM[0:3] match firmware")


    