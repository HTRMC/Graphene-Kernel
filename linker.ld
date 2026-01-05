/* Graphene Kernel Linker Script for Limine */

OUTPUT_FORMAT(elf64-x86-64)
ENTRY(kernel_main)

/* Higher half virtual address */
KERNEL_VIRT = 0xffffffff80000000;

PHDRS {
    limine_requests PT_LOAD FLAGS(6); /* rw- for Limine requests */
    text    PT_LOAD FLAGS(5); /* r-x */
    rodata  PT_LOAD FLAGS(4); /* r-- */
    data    PT_LOAD FLAGS(6); /* rw- */
}

SECTIONS {
    . = KERNEL_VIRT;

    /* Limine requests must be in their own section */
    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :limine_requests

    . = ALIGN(4096);

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
