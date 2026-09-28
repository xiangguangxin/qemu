/* Personal local experiment only. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
    . = 0x80000000;
    .text : { *(.text*) }
    . = ALIGN(4096);
    .data : { *(.rodata*) *(.data*) }
    .bss : { *(.bss*) *(COMMON) }
}
