# 阶段七：异常、中断、定时器与 WFI

[总路线](../QEMU_LEARNING_DESIGN.zh-CN.md) · [上一阶段](06_INTEGRATED_EXPERIMENT.zh-CN.md) · [下一阶段](08_EVENT_LOOPS_AND_TIME.zh-CN.md)

## 1. 范围与目标

**实验目标：** 运行裸机程序，分别完成一次 ecall、定时器中断和 UART 接收中断，验证 WFI 唤醒、三个事件计数均为 1，以及输入字节被正确记录。

建议 6 次学习，每次 1～2 小时。前置为六阶段基线；本章及配套代码仅用于个人本地实验，不用于 QEMU 上游贡献。实验状态统一见[验证记录](../VALIDATION.zh-CN.md)。

完成三个不同事件：M-mode `ecall`、机器定时器中断、UART 接收外部中断。必须保存 cause、epc、tval、计数器与中断撤销证据。字符发送成功不作为中断验收。

固定 RV64、单 hart、TCG、`virt,aia=none,aclint=off`、无固件、M-mode。不要把本章地址照搬到 AIA、多 hart 或 Linux 驱动。

## 2. 第一次：阅读程序和硬件连接

完整材料：[traps.S](../labs/interrupts/traps.S)、[link.ld](../labs/interrupts/link.ld)。程序先处理一次 ecall，再开启 UART RX 和定时器，等待两个中断均被处理，最后停在 `finished`。

| 项目 | 本实验取值 | 核对位置 |
| --- | --- | --- |
| UART0 | `0x10000000`，PLIC source 10 | `hw/riscv/virt.c`、`include/hw/riscv/virt.h` |
| PLIC priority[10] | `0x0c000028` | priority base + 10 × 4 |
| hart0 M enable | `0x0c002000`，bit 10 | context 0 enable |
| hart0 M threshold / claim | `0x0c200000` / `0x0c200004` | context 0 |
| mtime / hart0 mtimecmp | `0x0200bff8` / `0x02004000` | virt CLINT 布局及 ACLINT 实现 |

TCG 下默认带 S 扩展的 CPU 的 PLIC context 顺序可在 `hw/riscv/boot.c` 的 `riscv_plic_hart_config_string` 核对。定时器不经过 PLIC；UART 外部中断经过 PLIC。这两条路径分别画图。

处理器只保存实际使用的 t0～t2；程序无 C 调用、嵌套中断和多 hart。不能将这个最小处理器直接用作通用运行时。ecall 确定为 4 字节，只有处理该同步异常时才将 mepc 加 4；中断返回不跳过被中断指令。

## 3. 第二次：构建与启动

从仓库根目录执行，先完成阶段一 QEMU 构建：

```bash
mkdir -p build-study/study-lab/advanced
riscv64-linux-gnu-gcc -g -march=rv64im_zicsr -mabi=lp64 \
  -nostdlib -nostartfiles -static -fno-pie -no-pie \
  -Wl,--build-id=none -Wl,--no-relax \
  -T learning/labs/interrupts/link.ld \
  -o build-study/study-lab/advanced/traps.elf learning/labs/interrupts/traps.S
riscv64-linux-gnu-objdump -d build-study/study-lab/advanced/traps.elf
./build-study/qemu-system-riscv64 \
  -machine virt,aia=none,aclint=off -accel tcg,thread=single \
  -smp 1 -m 128M -bios none -display none -monitor none -serial stdio \
  -device loader,file=build-study/study-lab/advanced/traps.elf,cpu-num=0 \
  -S -gdb tcp:127.0.0.1:1234
```

终端 B 启动 `gdb-multiarch build-study/study-lab/advanced/traps.elf`：

```gdb
target remote 127.0.0.1:1234
break handle_ecall
break handle_timer
break handle_external
break unexpected
break finished
continue
```

每次停下执行 `info registers mcause mepc mtval mstatus mie mip`。`last_*` 是最近一次入口快照，会被后续中断覆盖；逐次保存 GDB 输出。

## 4. 第三次：同步异常和定时器

第一次应停在 `handle_ecall`，mcause=11。继续后应进入 `handle_timer`，mcause=`0x8000000000000007`。定时器相对当前 mtime 加 1000000 tick，实际秒数取决于平台 timebase，不能把 tick 当 ns。

处理器把 mtimecmp 写为最大值以撤销当前条件。继续后在 Guest GDB 中断运行并检查 `x/gd &timer_count`，预期 1；让系统继续运行，再次检查计数不应持续增长。设置断点会扰动时序，不用墙钟等待长度推断虚拟时间。

## 5. 第四次：UART→PLIC→CPU→处理器

继续运行，在终端 A 输入一个 ASCII 字符 `x`（本实验只输入一个字节）。应停在 `handle_external`，mcause=`0x800000000000000b`。逐步执行 claim 读取，预期取得 source 10。处理器读 UART RBR，禁用 RX IRQ，然后完成 PLIC claim。

到达 `finished` 后检查：

```gdb
x/gd &exception_count
x/gd &timer_count
x/gd &external_count
x/gx &received_byte
```

预期分别为 1、1、1、`0x78`。如果输入先于 timer，处理顺序可以不同，但最终数值相同。`finished` 为忙循环，需手动结束 QEMU。

不要用 GDB 额外读取 PLIC claim 或 UART RBR 来“看看”，这些读取有副作用，可能消费实验事件。观察程序实际读取后的寄存器。

## 6. 第五次：WFI 与丢失唤醒

检查 `wait_loop`：先关闭全局 MIE，再检查完成条件，然后 WFI，醒来后重新打开 MIE。局部 mie 仍使能相应中断；这一结构避免“检查完条件，中断刚好处理完，再执行 WFI 永久等待”的窗口。WFI 也可能提前返回，因此外层必须重查条件。相关全局/局部使能语义见 [RISC-V Machine-Level ISA 的 WFI 说明](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)。

在宿主调试的独立一轮中，对 `riscv_cpu_do_interrupt`、`riscv_aclint_mtimer_write`、`serial_update_irq` 设置断点（先用 rg 核对符号）。记录设备置位与 Guest trap 的两个观察点，不能用一个断点代表完整路径。

## 7. 第六次：故障定位与验收

在本地副本中只改一项：将 PLIC threshold 改为 1，其他配置不变。预期 timer 仍完成，UART 外部中断不能通过当前优先级门槛。恢复 threshold=0 后重新运行，不能沿用旧实例的状态。

| 症状 | 定位顺序 |
| --- | --- |
| 停在 unexpected | 先读 last_cause / last_epc / last_tval，不直接跳过异常 |
| UART 无中断 | 输入字节→IER→PLIC pending→priority/threshold→enable→mie/MIE |
| timer 重复触发 | 是否更新 mtimecmp，是否观察的是同一次运行 |
| 收到 IRQ 但程序不完成 | claim 值、RBR 读取、计数器、返回 PC |

交付：三种事件记录、UART claim/complete 与撤销记录、WFI 等待图、threshold 对照结果。只有这些动态证据齐全，才标记“Guest 中断已验证”。
