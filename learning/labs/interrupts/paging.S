/* Personal RV64 Sv39 local experiment; M-mode code, S-mode data via MPRV. */
.option norvc
.option norelax
.section .text
.globl _start, paging_done, paging_unexpected, faulting_store
_start:
    la t0, trap
    csrw mtvec, t0
    csrw mie, zero
    csrci mstatus, 8
    /* TOR PMP entry: permit S-mode access to this experiment's RAM. */
    li t0, -1
    csrw pmpaddr0, t0
    li t0, 0x0f
    csrw pmpcfg0, t0
    li t0, 0x80010000
    li t1, 0x12345678
    sw t1, 0(t0)
    la t0, root
    /* Root index 1: VA 0x40000000 -> PA 0x80000000, 1 GiB leaf. */
    li t1, 0x200000c7
    sd t1, 8(t0)
    srli t0, t0, 12
    li t1, 0x8000000000000000
    or t0, t0, t1
    csrw satp, t0
    sfence.vma
    /* MPP=S, MPRV=1: data accesses use S translation, fetch remains M. */
    li t0, 0x21800
    csrc mstatus, t0
    li t0, 0x20800
    csrs mstatus, t0
    li t1, 0x40010000
    lw s0, 0(t1)
    li t0, 0x20000
    csrc mstatus, t0
    la t0, translated_value
    sd s0, 0(t0)
    la t0, root
    li t1, 0x200000c3
    sd t1, 8(t0)
    sfence.vma
    li t0, 0x20000
    csrs mstatus, t0
    li t1, 0x40010000
faulting_store:
    sw zero, 0(t1)
    li t0, 0x20000
    csrc mstatus, t0
    li t0, 0x80010000
    lw t1, 0(t0)
    la t0, physical_after
    sd t1, 0(t0)
paging_done:
    j paging_done
.balign 4
trap:
    li t0, 0x20000
    csrc mstatus, t0
    csrr t1, mcause
    la t0, page_cause
    sd t1, 0(t0)
    csrr t2, mtval
    la t0, page_tval
    sd t2, 0(t0)
    li t2, 15
    bne t1, t2, paging_unexpected
    csrr t1, mepc
    la t0, page_epc
    sd t1, 0(t0)
    addi t1, t1, 4
    csrw mepc, t1
    mret
paging_unexpected:
    j paging_unexpected
.section .data
.balign 8
.globl translated_value, physical_after, page_cause, page_tval, page_epc
translated_value: .dword 0
physical_after: .dword 0
page_cause: .dword 0
page_tval: .dword 0
page_epc: .dword 0
.balign 4096
root: .zero 4096
