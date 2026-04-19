# test_hk_boot_adapter.py
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

async def wb_write(dut, addr, data):
    """Issue one Wishbone write and wait for ack."""
    await RisingEdge(dut.clk)
    dut.wbs_adr.value = addr
    dut.wbs_dat.value = data
    dut.wbs_cyc.value = 1
    dut.wbs_stb.value = 1
    dut.wbs_we.value  = 1

    # Wait for ack — adapter stalls until all 4 bytes done
    for _ in range(20):
        await RisingEdge(dut.clk)
        if dut.wbs_ack.value == 1:
            break

    dut.wbs_cyc.value = 0
    dut.wbs_stb.value = 0
    dut.wbs_we.value  = 0
    await RisingEdge(dut.clk)

@cocotb.test()
async def test_single_word(dut):
    """One WB write should produce 4 sequential boot_wen pulses."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    await Timer(40, unit="ns")
    dut.rst.value = 0
    dut.wbs_cyc.value = 0
    dut.wbs_stb.value = 0

    # Write 0xDEADBEEF to address 0x1000 (SRAM offset 0)
    captured = []
    async def capture():
        while True:
            await RisingEdge(dut.clk)
            if dut.boot_wen.value == 0:
                captured.append({
                    "addr": int(dut.boot_addr.value),
                    "data": int(dut.boot_data.value),
                })

    cocotb.start_soon(capture())
    await wb_write(dut, 0x1000, 0xDEADBEEF)
    await Timer(50, unit="ns")  # let last capture settle

    assert len(captured) == 4, f"Expected 4 write pulses, got {len(captured)}"
    assert captured[0] == {"addr": 0, "data": 0xEF}, f"byte 0 wrong: {captured[0]}"
    assert captured[1] == {"addr": 1, "data": 0xBE}, f"byte 1 wrong: {captured[1]}"
    assert captured[2] == {"addr": 2, "data": 0xAD}, f"byte 2 wrong: {captured[2]}"
    assert captured[3] == {"addr": 3, "data": 0xDE}, f"byte 3 wrong: {captured[3]}"
    print("PASS: single word → 4 byte writes, correct addr/data")

@cocotb.test()
async def test_sequential_words(dut):
    """Two consecutive WB writes should not overlap — ack gates the FSM."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    await Timer(40, unit="ns")
    dut.rst.value = 0
    dut.wbs_cyc.value = 0
    dut.wbs_stb.value = 0

    captured = []
    async def capture():
        while True:
            await RisingEdge(dut.clk)
            if dut.boot_wen.value == 0:
                captured.append(int(dut.boot_addr.value))

    cocotb.start_soon(capture())

    await wb_write(dut, 0x1000, 0x11223344)
    await wb_write(dut, 0x1004, 0xAABBCCDD)
    await Timer(50, unit="ns")

    assert len(captured) == 8, f"Expected 8 total byte writes, got {len(captured)}"
    # Addresses should be 0,1,2,3 then 4,5,6,7 — no overlap
    assert captured == [0,1,2,3,4,5,6,7], f"Address sequence wrong: {captured}"
    print("PASS: sequential words, no overlap")

@cocotb.test()
async def test_ack_timing(dut):
    """ack must not assert until after the 4th byte write."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    await Timer(40, unit="ns")
    dut.rst.value = 0
    dut.wbs_cyc.value = 0
    dut.wbs_stb.value = 0

    await RisingEdge(dut.clk)
    dut.wbs_adr.value = 0x1008
    dut.wbs_dat.value = 0xCAFEBABE
    dut.wbs_cyc.value = 1
    dut.wbs_stb.value = 1
    dut.wbs_we.value  = 1

    wen_count = 0
    ack_cycle = None
    for cycle in range(20):
        await RisingEdge(dut.clk)
        if dut.boot_wen.value == 0:
            wen_count += 1
        if dut.wbs_ack.value == 1 and ack_cycle is None:
            ack_cycle = cycle

    assert ack_cycle is not None, "ack never asserted"
    assert wen_count == 4, f"Expected exactly 4 wen pulses before/at ack, got {wen_count}"
    # ack should come on or after the 4th wen cycle
    assert ack_cycle >= 3, f"ack too early at cycle {ack_cycle}"
    print(f"PASS: ack at cycle {ack_cycle}, {wen_count} byte writes")

    