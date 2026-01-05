/* Graphene Kernel Linker Script */

OUTPUT_FORMAT(elf64-x86-64)
ENTRY(kernel_main)

/* Limine loads us at this address in the higher half */
KERNEL_OFFSET = 0xffffffff80000000;

PHDRS {
    text    PT_LOAD FLAGS(5); /* r-x */
    rodata  PT_LOAD FLAGS(4); /* r-- */
    data    PT_LOAD FLAGS(6); /* rw- */
}

SECTIONS {
    . = KERNEL_OFFSET;

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(4096);

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(4096);

    .data : {
        *(.data .data.*)
    } :data

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
