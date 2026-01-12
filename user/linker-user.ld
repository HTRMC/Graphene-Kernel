/* Graphene User Space Linker Script */
/* Places user programs at 0x400000 (standard Linux x86_64 base) */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);   /* R-X */
    rodata PT_LOAD FLAGS(4); /* R-- */
    data PT_LOAD FLAGS(6);   /* RW- */
}

SECTIONS
{
    /* User space starts at 4MB */
    . = 0x400000;

    /* Code section - Read + Execute */
    .text : ALIGN(4096)
    {
        *(.text .text.*)
    } :text

    /* Read-only data - Read only */
    .rodata : ALIGN(4096)
    {
        *(.rodata .rodata.*)
    } :rodata

    /* Initialized data - Read + Write */
    .data : ALIGN(4096)
    {
        *(.data .data.*)
    } :data

    /* Uninitialized data (BSS) - Read + Write */
    .bss : ALIGN(4096)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    } :data

    /* Debugging sections */
    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
