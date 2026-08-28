OUTPUT_ARCH("riscv")
ENTRY(_start)

/* Keep sparse DDR and DCCM ranges in separate ELF LOAD segments. */
PHDRS
{
  program PT_LOAD FLAGS(5); /* R + X */
  data    PT_LOAD FLAGS(6); /* R + W */
  amo     PT_LOAD FLAGS(6); /* R + W */
}

PROGRAM_BASE  = 0x80000000;
PROGRAM_LIMIT = 0xA0000000;
LSU_BASE      = 0xA0000000;
LSU_LIMIT     = 0x100000000;
/* Ordinary random load/store data use external DDR0. */
DATA_BASE     = 0xA0000000;
DATA_LIMIT    = 0xD0000000;
/* This EH2 netlist accepts AMO/LR/SC only in its 64-KiB internal DCCM. */
AMO_BASE      = 0xF0040000;
AMO_LIMIT     = 0xF0050000;

SECTIONS
{
  /* IFU image: unchanged Ethernet/DMA destination at 0x80000000. */
  . = PROGRAM_BASE;
  __program_start = .;
  .text : ALIGN(4) {
    KEEP(*(.text.eh2_start))
    KEEP(*(.text.eh2_prelude))
    *(.text)
    KEEP(*(.text.eh2_tail))
    KEEP(*(.text.eh2_post))
    *(.text.*)
  } :program
  .rodata : ALIGN(16) { *(.rodata*) } :program
  __program_end = ALIGN(., 4);

  /*
   * Ordinary LSU data is deliberately disjoint from the IFU program and all
   * reserved high-address devices.  DDR0 is cleared during READY, so these
   * writable riscv-dv pages/stacks are NOLOAD and start as zero without
   * changing the program burn image or Ethernet protocol.
   */
  . = DATA_BASE;
  .data (NOLOAD) : ALIGN(64) {
    __data_start = .;
    *(.data*)
    *(.sdata*)
    *(.h0_region_*)
    *(.h1_region_*)
    *(.h0_user_stack*)
    *(.h1_user_stack*)
    *(.h0_kernel_stack*)
    *(.h1_kernel_stack*)
    *(.tohost*)
    __data_initialized_end = .;
  } :data
  .bss (NOLOAD) : ALIGN(64) {
    *(.bss*)
    *(.sbss*)
    *(COMMON)
  } :data
  __data_end = ALIGN(., 64);

  /*
   * patch_chunk() splits riscv-dv's shared amo_0 page into one page per
   * hart.  Keeping them disjoint makes Spike/FPGA results deterministic
   * while retaining genuinely random AMO and LR/SC instruction streams.
   */
  . = AMO_BASE;
  .amo (NOLOAD) : ALIGN(64) {
    __amo_start = .;
    __amo_h0_start = .;
    *(.eh2_amo_h0_*)
    __amo_h0_end = .;
    . = ALIGN(64);
    __amo_h1_start = .;
    *(.eh2_amo_h1_*)
    __amo_h1_end = .;
    __amo_end = ALIGN(., 64);
  } :amo
  _end = __data_end;

  ASSERT(__program_start == PROGRAM_BASE,
         "program start changed from 0x80000000")
  ASSERT(__program_end <= PROGRAM_LIMIT,
         "program image exceeds the configured 512 MiB window")
  ASSERT(__data_start >= LSU_BASE,
         "ordinary LSU data begins below 0xa0000000")
  ASSERT(__data_end <= DATA_LIMIT,
         "ordinary LSU data enters a reserved high-address region")
  ASSERT(__amo_start >= AMO_BASE,
         "atomic data begins below EH2 DCCM")
  ASSERT(__amo_end <= AMO_LIMIT,
         "atomic data exceeds EH2 DCCM")
  ASSERT(__data_start >= LSU_BASE && __data_end <= LSU_LIMIT,
         "ordinary LSU data leaves 0xa0000000..0xffffffff")
  ASSERT(__amo_start >= LSU_BASE && __amo_end <= LSU_LIMIT,
         "atomic LSU data leaves 0xa0000000..0xffffffff")
}
