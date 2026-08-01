    .option norvc
    .section .text.init
    .globl _start
_start:
    csrr    s0, mhartid
    bnez    s0, hart_start_done
    li      t6, 2
#ifdef SPIKE_COMPAT
    /* Stock Spike does not implement EH2's private hart-start CSR. The
       Spike trace postprocessor restores this NOP to the real CSR commit. */
    nop
#else
    csrw    0x7FC, t6
#endif

hart_start_done:
    la      sp, stack_top
    slli    t0, s0, 10
    sub     sp, sp, t0
    la      s1, shared_data
    slli    t0, s0, 8
    add     s1, s1, t0
    li      t2, 0x13579bdf
    li      t3, 0x2468ace1
    li      a0, 0

    /* Each hart executes a different 100,000-instruction straight-line
       region. The two regions below therefore put 200,000 real instruction
       words in the program image; this is deliberately not a small runtime
       loop. The image must be transported as hundreds of Ethernet frames. */
    beqz    s0, hart0_straight_line
    j       hart1_straight_line

hart0_straight_line:
    .rept 12500
    addi    t2, t2, 7
    xor     t3, t3, t2
    add     t4, t2, t3
    mul     t5, t4, t2
    sw      t5, 0(s1)
    lw      s4, 0(s1)
    add     a0, a0, s4
    xori    a0, a0, 0x55
    .endr
    j       program_finish

hart1_straight_line:
    .rept 12500
    addi    t2, t2, 7
    xor     t3, t3, t2
    add     t4, t2, t3
    mul     t5, t4, t2
    sw      t5, 0(s1)
    lw      s4, 0(s1)
    add     a0, a0, s4
    xori    a0, a0, 0x55
    .endr

program_finish:
    li      t4, 0xD0580000
    li      t5, 0x00320525
    sw      t5, 0(t4)
    fence   rw, rw
done:
    wfi
    j       done

    .section .data
    .align 6
shared_data:
    .space 512

    .section .bss
    .align 12
stack_area:
    .space 8192
stack_top:
