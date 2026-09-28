/* Personal local experiment only; not for QEMU upstream contribution. */
.option norvc
.option norelax
.section .text
.globl _start, finished, unexpected
_start:
    la sp, stack_top
    la t0, trap_entry
    csrw mtvec, t0
    csrw mie, zero
    csrci mstatus, 8
    /* A known 32-bit synchronous exception; resume at the next instruction. */
    ecall
    /* UART0 RX interrupt, PLIC source 10, hart 0 M context. */
    li t0, 0x0c000028
    li t1, 1
    sw t1, 0(t0)
    li t0, 0x0c002000
    li t1, 0x400
    sw t1, 0(t0)
    li t0, 0x0c200000
    sw zero, 0(t0)
    li t0, 0x10000000
    li t1, 3
    sb t1, 3(t0)
    li t1, 1
    sb t1, 1(t0)
    /* CLINT-compatible mtime/mtimecmp layout, hart 0, RV64. */
    li t0, 0x0200bff8
    ld t1, 0(t0)
    li t2, 1000000
    add t1, t1, t2
    li t0, 0x02004000
    sd t1, 0(t0)
    li t0, 0x880
    csrw mie, t0
    csrsi mstatus, 8
wait_loop:
    /* Disable global delivery across the condition check and WFI to avoid
       sleeping after the final interrupt has already been handled. */
    csrci mstatus, 8
    la t0, timer_count
    ld t1, 0(t0)
    beqz t1, sleep_now
    la t0, external_count
    ld t1, 0(t0)
    bnez t1, finished
sleep_now:
    wfi
    csrsi mstatus, 8
    j wait_loop
finished:
    j finished
.balign 4
trap_entry:
    addi sp, sp, -48
    sd t0, 0(sp)
    sd t1, 8(sp)
    sd t2, 16(sp)
    csrr t0, mcause
    la t1, last_cause
    sd t0, 0(t1)
    csrr t2, mepc
    la t1, last_epc
    sd t2, 0(t1)
    csrr t2, mtval
    la t1, last_tval
    sd t2, 0(t1)
    li t1, 11
    beq t0, t1, handle_ecall
    li t1, 0x8000000000000007
    beq t0, t1, handle_timer
    li t1, 0x800000000000000b
    beq t0, t1, handle_external
unexpected:
    j unexpected
handle_ecall:
    la t0, exception_count
    ld t1, 0(t0)
    addi t1, t1, 1
    sd t1, 0(t0)
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    j restore
handle_timer:
    li t0, 0x02004000
    li t1, -1
    sd t1, 0(t0)
    la t0, timer_count
    ld t1, 0(t0)
    addi t1, t1, 1
    sd t1, 0(t0)
    j restore
handle_external:
    li t0, 0x0c200004
    lw t1, 0(t0)
    li t2, 10
    bne t1, t2, unexpected
    li t2, 0x10000000
    lbu t1, 0(t2)
    la t2, received_byte
    sd t1, 0(t2)
    li t2, 0x10000000
    sb zero, 1(t2)
    fence iorw, iorw
    li t1, 10
    sw t1, 0(t0)
    la t0, external_count
    ld t1, 0(t0)
    addi t1, t1, 1
    sd t1, 0(t0)
restore:
    ld t0, 0(sp)
    ld t1, 8(sp)
    ld t2, 16(sp)
    addi sp, sp, 48
    mret
.section .data
.balign 8
.globl exception_count, timer_count, external_count, received_byte
.globl last_cause, last_epc, last_tval
exception_count: .dword 0
timer_count: .dword 0
external_count: .dword 0
received_byte: .dword 0
last_cause: .dword 0
last_epc: .dword 0
last_tval: .dword 0
.section .bss
.balign 16
.skip 4096
stack_top:
