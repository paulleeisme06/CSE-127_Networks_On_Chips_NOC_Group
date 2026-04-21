# GF180MCU 1024x8 SRAM Configuration

## SRAM Overview

This project uses Tim Edwards' 3.3V 1024x8 SRAM with the following configuration:

### Memory Layout

| Address Range | Usage | Size |
|--------------|-------|------|
| 0 - 895 | Program + Data Memory | 896 bytes |
| 896 - 1019 | General Purpose Registers (x31 → x1) | 124 bytes |
| 1020 - 1023 | Zero Register (x0, always reads 0) | 4 bytes |

**Total:** 1024 bytes (8-bit words)

---

## Register File Mapping

The RISC-V register file is stored at the **top of SRAM in reverse order**:
- **x0** (zero register) is at the very top: addresses 1020–1023
- **x31** is at the bottom of the register file: addresses 896–899

### Detailed Register-to-SRAM Mapping

| RISC-V Register | RF Byte Address | SRAM Address | Notes |
|----------------|-----------------|--------------|-------|
| x0 (byte 3) | 3 | 1020 | MSB of x0 |
| x0 (byte 2) | 2 | 1021 | |
| x0 (byte 1) | 1 | 1022 | |
| x0 (byte 0) | 0 | 1023 | LSB of x0 |
| x1 (byte 3) | 7 | 1016 | MSB of x1 |
| x1 (byte 2) | 6 | 1017 | |
| x1 (byte 1) | 5 | 1018 | |
| x1 (byte 0) | 4 | 1019 | LSB of x1 |
| ... | ... | ... | ... |
| x31 (byte 3) | 127 | 896 | MSB of x31 |
| x31 (byte 2) | 126 | 897 | |
| x31 (byte 1) | 125 | 898 | |
| x31 (byte 0) | 124 | 899 | LSB of x31 |

> **Note:** Each RISC-V register is 32 bits (4 bytes) stored in big-endian format.

---

## Testing

### test_sram_gf180.py

This test script verifies SRAM functionality independently of the SERV CPU.

**To run:**
```bash
make
```

**Purpose:**
- Tests basic SRAM read/write operations
- Validates memory addressing
- Checks register file mapping
- Does **not** require the full SERV CPU to be functional

---

## Memory Map Visualization

```
┌─────────────────────────────────────┐
│  Address 0                          │
│  ┌───────────────────────────────┐  │
│  │                               │  │
│  │   Program + Data Memory       │  │
│  │   (896 bytes)                 │  │
│  │                               │  │
│  └───────────────────────────────┘  │
│  Address 895                        │
├─────────────────────────────────────┤
│  Address 896                        │
│  ┌───────────────────────────────┐  │
│  │  x31 (4 bytes)                │  │
│  │  x30 (4 bytes)                │  │
│  │  ...                          │  │
│  │  x2  (4 bytes)                │  │
│  │  x1  (4 bytes)                │  │
│  │                               │  │
│  │  Register File                │  │
│  │  (124 bytes)                  │  │
│  └───────────────────────────────┘  │
│  Address 1019                       │
├─────────────────────────────────────┤
│  Address 1020                       │
│  ┌───────────────────────────────┐  │
│  │  x0 (zero register)           │  │
│  │  (4 bytes, always reads 0)    │  │
│  └───────────────────────────────┘  │
│  Address 1023                       │
└─────────────────────────────────────┘
```

---

## Key Design Features

- **8-bit word width**: Each address holds one byte
- **Reverse register ordering**: Simplifies SERV's register file access pattern
- **Zero register at top**: x0 is hardwired to read zero, located at highest addresses
- **896 bytes for code/data**: Sufficient for small embedded programs
