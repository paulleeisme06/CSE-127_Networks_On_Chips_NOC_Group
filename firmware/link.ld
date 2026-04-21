OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    sram (rwx) : ORIGIN = 0x00000000, LENGTH = 2048
}

SECTIONS {
    .text : {
        *(.text.init)
        *(.text)
        *(.rodata*)
        . = ALIGN(4);
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    } > sram

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

    /DISCARD/ : {
        *(.comment)
        *(.riscv.attributes)
        *(.eh_frame)
    }
}