# 阶段五：串口设备、对象模型与中断路径

[返回总路线](../QEMU_LEARNING_DESIGN.zh-CN.md) · [上一阶段](04_MEMORY_AND_ADDRESS_SPACES.zh-CN.md) · [下一阶段](06_INTEGRATED_EXPERIMENT.zh-CN.md)

## 1. 目标与安排

建议 8 次学习，每次 1～2 小时。前半段跟通字符输出，后半段分析 IRQ 和复位。必做实验只验证串口数据路径；完整 Guest 中断处理作为进阶任务，不能用轮询输出替代中断验收。

本章延用统一裸机程序与本地实验范围。重要分工：machine 负责把设备放到系统里，设备负责寄存器语义，字符后端负责连接宿主输入输出。

## 2. 第 1～2 次学习：沿创建设备的路径阅读

| 入口 | 阅读目标 |
| --- | --- |
| [virt.c](../../hw/riscv/virt.c) 的 `serial_mm_init` 调用 | 地址、IRQ、时钟和后端参数从哪里来 |
| [serial-mm.c](../../hw/char/serial-mm.c) 的 `serial_mm_init` | 创建、realize、MMIO 映射、中断连接 |
| 同文件的类型信息与类初始化 | 如何安装设备方法和属性 |
| [serial.c](../../hw/char/serial.c) | 通用串口寄存器与状态机 |

```bash
rg -n 'serial_mm_init|UART0_IRQ|serial_hd' hw/riscv/virt.c
rg -n 'TypeInfo|class_init|instance_init|realize|reset|sysbus' hw/char/serial-mm.c
rg -n 'realize|reset|TypeInfo|serial_update_irq' hw/char/serial.c
```

依照源码实际展开，不把寄存器模型、MMIO 包装与字符后端混成一个函数。

## 3. 第 3 次学习：只学当前需要的 QOM

阅读 [QOM](../../docs/devel/qom.rst) 与 [设备 API](../../docs/devel/qdev-api.rst)，建立以下对应关系：

| 对象概念 | 需要回答的问题 |
| --- | --- |
| TypeInfo | 类型名称、父类型、实例大小在哪里定义？ |
| instance_init | 一个实例刚创建时完成哪些初始化？ |
| class_init | 方法指针如何安装到类上？ |
| 属性 | 板级如何配置设备？ |
| realize | 什么时候把设备变为可用状态？ |
| reset | 哪些运行状态恢复初始值？ |

注册类型不会立即产生一台完整设备；创建对象也不等于已完成 realize。记录具体类型名和父类型，比泛泛背诵“C 实现面向对象”更有用。

## 4. 第 4～5 次学习：完整跟踪一个字符

源码阅读路标：

```text
Guest sb
  → serial_mm_write
  → serial_io_ops 对应的 serial_ioport_write
  → 发送寄存器 / FIFO 状态更新
  → serial_xmit
  → qemu_chr_fe_write
  → 选定字符后端
```

这是当前模型的主要观察路径，重试、FIFO 和后端不可写等情况可能引入其他分支。以实际调用栈为准。

在宿主 GDB 中以文件串口后端运行，设置：

```gdb
break serial_mm_write
break serial_ioport_write
break serial_xmit
run
```

在写字符处核对 addr、size、value 或 val；后续检查 `SerialState` 中 `thr`、`lsr`、`ier`、`lcr`。变量名依当前函数参数而定，用 `info args` 确认。保存进入字符后端前的栈。

解释本程序两次写入：先向 LCR 写 3，保持 DLAB 清零；再向偏移 0 写 75。当 DLAB 置位时，同一偏移可能用于分频器配置。因此仅知道地址与数值，还不足以解释一次寄存器访问，必须结合设备当前状态。

使用 `-serial file:build-study/study-lab/device-uart.log` 后，退出 QEMU 再检查文件，预期一个字节 `0x4b`。不要要求文件一定带换行。

## 5. 第 6 次学习：区分发送成功与 IRQ

第一阶段程序轮询 LSR，没有编写中断处理程序。字符输出成功只证明发送路径通畅，不能证明 Guest 接收了中断。

阅读 `serial_update_irq`，记录 IER、IIR 与发送/接收状态如何决定 IRQ。再回到 virt 中确认 IRQ 输入接到哪个控制器。需要固定 PLIC 配置时，先通过 `-machine virt,help` 检查参数，再使用 `aia=none`。

```text
设备条件成立且相应中断使能
  → 串口 IRQ 线状态改变
  → PLIC 输入状态变化
  → CPU 外部中断条件成立
  → Guest trap handler
  → Guest 服务设备并完成控制器协议
```

设备寄存器中的 IRQ 原因消除，与中断控制器的 claim/complete 是不同层次。不要把“完成 PLIC 服务”理解为自动清除了 UART 内部条件。

## 6. 第 7 次学习：中断进阶实验的入口条件

要让 Guest 真正处理中断，需要准备以下条件，缺少任何一项都可能导致“设备已拉高但 CPU 不响应”：

1. 建立正确的 trap 入口、保存恢复寄存器并能记录异常原因。
2. 配置目标特权模式的中断使能，明确委托关系。
3. 配置 PLIC 的 source priority、目标 context enable 和 threshold。
4. 开启 UART 对应中断，构造真实触发条件。
5. 服务 UART 状态，并按控制器协议完成处理。

本章不把上述步骤伪装成给原程序加一次寄存器写即可完成。可以使用已知可用的裸机中断例程，或第一阶段的 Linux 扩展环境。Linux 下核对 `/proc/interrupts` 的计数变化，同时检查驱动是否使用轮询，避免把日志输出等价为发送中断。

本阶段先交付设备到控制器的源码连接图；完整裸机处理器、PLIC 配置、UART RX、timer 与 WFI 动态实验已放在[阶段七](07_TRAPS_INTERRUPTS_AND_TIMERS.zh-CN.md)。以 ESL 为目标时，必须补完该实验，不能一直以源码图代替动态验收。

## 7. 第 8 次学习：复位与后端变化

对比两次全新 QEMU 启动，检查相同设备初值和相同输出。进阶时从 Monitor 执行 `system_reset`，并在设备 reset 路径停下，观察哪些字段恢复。

全机复位可能也使 Guest 再次执行输出，不能据此直接判断“串口自己重复发送”。复位前已写到宿主文件的字节也不会被撤销。

将后端由 stdio 改为文件后，Guest 地址和寄存器协议不变，宿主输出目的地变化。这正是设备前端与宿主后端分离的价值。

## 8. 验收与 ESL 衔接

- [ ] 画出设备创建、配置、realize 和映射的关系。
- [ ] 给出字符 `K` 从 store 到字符后端的调用证据。
- [ ] 能解释 DLAB 导致同一偏移含义变化。
- [ ] 能区分 UART IRQ 条件、中断控制器协议和 CPU trap。
- [ ] 明确记录 IRQ 哪些部分已运行验证、哪些只有源码分析。

交付：设备生命周期图、寄存器访问表、字符路径调用栈、中断路由图、复位观察记录。

自测：若把串口寄存器逻辑移到 SystemC，QEMU 必须保留哪些职责？提示：MMIO 窗口、消息代理、板级连接和中断注入；寄存器状态只保留一个权威来源。随后可阅读 [ESL 设计文档第 5～6 节](../QEMU_SYSTEMC_ESL_DESIGN.zh-CN.md)。
