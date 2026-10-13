/* Minimal: everything at the injection address, one blob, no memory regions. */
ENTRY(game_entry)
SECTIONS {
  . = 0x8002C000;
  .text : { *(.text*) *(.rodata*) *(.data*) }
}
