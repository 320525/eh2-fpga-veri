
    .option norvc
    .section .text.init
    .globl _start
_start:
    csrr    s0, mhartid
    la      sp, stack_top
    slli    t0, s0, 10
    sub     sp, sp, t0
    la      s1, shared_data
    slli    t0, s0, 8
    add     s1, s1, t0
    li      t1, 4759
    li      t0, 0
    li      a0, 0
    li      t2, 0x13579bdf
    li      t3, 0x2468ace1

stress_loop:
    addi    t2, t2, 7
    xor     t3, t3, t2
    add     t4, t2, t3
    mul     t5, t4, t2
    divu    s2, t5, t2
    remu    s3, t5, t3
    sw      t5, 0(s1)
    lw      s4, 0(s1)
    addi    s4, s4, 1
    lw      s5, 0(s1)
    add     s6, s5, s4
    div     s7, s6, t2
    xor     s7, s7, t3
    addi    a0, a0, 3
    xori    a0, a0, 0x55
    and     a1, t2, t3
    or      a2, t2, t3
    sll     a3, a1, s0
    srl     a4, a2, s0
    addi    t0, t0, 1
    bne     t0, t1, stress_loop

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
