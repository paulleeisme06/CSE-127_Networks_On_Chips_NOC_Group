OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    sram (rwx) : ORIGIN = 0x00000000, LENGTH = 1024
}

SECTIONS {
    /* The bootloader copies everything in this block from Flash to SRAM.
       We bundle code (.text) and initialized data (.data) together.
    */
    .text : {
        *(.text.init)
        *(.text)
        *(.rodata*)
        
        /* Initialized globals like current_grid now live here */
        . = ALIGN(4);
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    } > sram

    /* .bss remains for zero-initialized variables.
       The CPU still needs to clear this if it wants a clean slate,
       but hardware won't copy these bytes from Flash.
    */
    .bss : {
        . = ALIGN(4);
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        *(COMMON)
        _bss_end = .;
    } > sram

    /* Throw away compiler metadata to keep the binary lean */
    /DISCARD/ : {
        *(.comment)
        *(.riscv.attributes)
        *(.eh_frame)
    }
}