MEMORY {
    sram (rwx) : ORIGIN = 0x00000000, LENGTH = 2048
}

SECTIONS {
    .text : {
        *(.text.init)
        *(.text)
        *(.rodata*)
    } > sram

    /* Force the data/bss to end before your manual GRID_BASE */
    .data : {
        *(.data*)
        *(.sdata*)
    } > sram

    .bss : {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        _bss_end = .;
    } > sram

    /* Create a "Guard" to ensure code + stack doesn't hit 0x0500 */
    _end = .;
    ASSERT(_end < 0x0400, "Error: code too large, overlaps stack region!")
}