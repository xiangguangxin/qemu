# 阶段四：地址空间、RAM 与 MMIO

[返回总路线](../QEMU_LEARNING_DESIGN.zh-CN.md) · [上一阶段](03_TCG_AND_INSTRUCTIONS.zh-CN.md) · [下一阶段](05_DEVICES_AND_INTERRUPTS.zh-CN.md)

## 1. 目标与前置条件

**实验目标：** 观察一次 RAM 写入和一次 UART MMIO 写入，记录地址空间映射、结果字节及设备回调参数，解释 GVA、GPA、HVA 和区域内偏移的区别。

建议 5 次学习，每次 1～2 小时。已能使用 Guest GDB，并理解翻译与执行的区别。使用第一阶段 ELF 与启动参数；本章为个人本地实验。

本阶段跟通两次访问：`sw t0, 0(t3)` 写 RAM，`sb t5, 0(t4)` 写 UART。最小裸机实验不建立页表；分页先做源码分析，再进入[支线十三](13_MMU_AND_LINUX.zh-CN.md)的自包含 Sv39 实验与 Linux 扩展。

## 2. 第一次学习：地址层次与两种写入去向

### 2.1 GVA、GPA、HVA、HPA

| 缩写 | 英文全称 | 含义 |
| --- | --- | --- |
| GVA | Guest Virtual Address | Guest 指令或软件使用的虚拟地址 |
| GPA | Guest Physical Address | Guest 物理地址；虚拟机平台把 RAM、UART 等映射在这个地址空间 |
| HVA | Host Virtual Address | QEMU 进程可访问的宿主虚拟地址；TCG 访问 RAM backing 时会使用相应映射 |
| HPA | Host Physical Address | 宿主硬件的物理地址；由宿主内核和硬件虚拟化机制管理，通常不是 QEMU 设备回调直接使用的指针 |

地址处理可以分成两个问题：Guest 的地址如何变成 GPA，以及 GPA 在虚拟机平台上对应 RAM 还是设备。不要把它们混成一次转换。

```text
Guest 指令发出的地址
  │
  ├─ 若当前特权级/配置启用地址转换：GVA --Guest 页表与权限检查--> GPA
  └─ 若未启用相应转换：按架构规则直接得到/使用 GPA
                                         │
                         QEMU 平台 AddressSpace 按 GPA 查映射
                            ┌────────────┴─────────────┐
                            │                          │
                       普通 RAM                    MMIO 设备
                 访问 RAM backing             调用 MemoryRegionOps
                 （TCG 下映射到 HVA）         回调并传入区域内偏移
```

本实验的裸机程序在默认 M-mode、未设置 `MPRV` 等改变访存特权级的情况下，不走普通 S-mode 页表转换，因此可把本例中的有效地址按 GPA 分析。不要把这个结论推广到启用分页的 Guest OS 或其他特权级设置。

`0x80000000` 在本 `virt` 平台上是 RAM 起始 GPA，不是 QEMU 进程的 HVA。GPA 和 HPA 也不是同一个概念。可以把 QEMU 的映射看作“Guest 可见的 GPA 如何落到 QEMU 管理的 RAM 或设备”；HPA 则属于宿主机硬件/内核的物理内存管理层。

### 2.2 普通 RAM 写入与 UART MMIO 写入

**普通 RAM 写入：**CPU 向映射为 RAM 的 GPA 写入数据时，QEMU 通过 RAM 区域访问对应的 backing memory。TCG 的软件 TLB 快速路径可以直接把 Guest 地址映射到 QEMU 进程可访问的 RAM（HVA）并完成读写，不一定每次都进入通用地址空间派发函数。例如，向普通 RAM 写入一个字节 `0x42`，之后从同一 Guest 地址读取应得到 `0x42`。

在本练习程序中，实际的 RAM 写入是 `sw t0, 0(t3)`：`result` 位于 GPA `0x80000048`，写入的是 32 位结果 `15`，小端字节序下内存字节为 `0f 00 00 00`。这与上面的单字节示例是同一种 RAM 路径，但访问宽度不同。

**UART MMIO 写入：**CPU 向映射为 UART 寄存器的 GPA 写入时，QEMU 根据地址空间映射识别出这是 MMIO。设备的 `MemoryRegionOps` 写回调收到区域内偏移、写入值和访问宽度，再由 UART 逻辑解释寄存器写入。例如向本练习平台 UART 的发送数据寄存器地址 `0x10000000` 写入 `0x41`（ASCII `A`），回调通常看到区域内偏移 `0`、值 `0x41`、宽度 1 字节，随后串口后端输出字符 `A`。它不会像普通 RAM 那样把 `0x41` 存进一块供 Guest 普通读写的 RAM。

上述地址、偏移、回调名称和参数是本实验配置下的示例；它们会随 QEMU 版本、machine、UART 型号和设备映射而变化。RAM 与 UART 的具体观察步骤见本章第 4、5 节。

### 2.3 TCG 与硬件加速下的宿主映射

在本章使用的 **TCG** 模式中，QEMU 软件模拟 Guest 的地址转换和访问权限；软件 TLB 命中时，RAM 访问通常走快速路径，MMIO 访问则进入设备模拟逻辑。此时不要把 GPA→HVA 称为 EPT/NPT。

使用 **KVM 等硬件加速**时，Guest 页表仍负责 Guest 虚拟地址到 Guest 物理地址的转换（启用分页时）；在支持二阶段转换的主机架构上，硬件可再用 Intel EPT 或 AMD NPT 将 GPA 映射到 HPA。KVM 还会把 Guest RAM 区域与 QEMU 用户态提供的 backing 映射关联起来。RAM 访问可以由硬件直接执行；未映射为 RAM 的 MMIO 访问通常导致 VM exit，再由 KVM/QEMU 进行设备模拟。具体实现依赖主机架构、KVM 和设备配置。

读 [内存模型](../../docs/devel/memory.rst) 的区域类型和可见性部分，再读 [访存接口](../../docs/devel/loads-stores.rst)；TCG 的软件 MMU 说明见 [TCG 内部机制](../../docs/devel/tcg.rst)。KVM 的 Guest 物理内存区域和 userspace backing 关系可参考[内核 KVM API 文档](https://docs.kernel.org/virt/kvm/api.html#kvm-set-user-memory-region)。

## 3. 第二次学习：MemoryRegion 与 AddressSpace

`MemoryRegion` 描述 RAM、MMIO、容器、别名等区域；`AddressSpace` 表示某一访问主体看到的映射视图。设备 DMA 以后也需要选择正确地址空间，并不是所有访问都天然等价于 CPU 的虚拟地址访问。

从 [virt.c](../../hw/riscv/virt.c) 找到：

```bash
rg -n 'virt_memmap|VIRT_DRAM|VIRT_UART0|memory_region_add_subregion|machine->ram' hw/riscv/virt.c
rg -n 'memory_region_init_io|memory_region_add_subregion' hw/char/serial-mm.c
```

记录 RAM 和 UART 的基址、长度以及注册路径。若要从 Monitor 查看映射，单独启动一轮，将第一阶段的 `-monitor none -serial stdio` 替换成：

```text
-monitor stdio -serial file:build-study/study-lab/memory-uart.log
```

在 QEMU Monitor 中执行 `info mtree`，保存相关 RAM、UART 条目。Monitor 命令不是 shell 命令。需要退出时使用 `quit`。

## 4. 第三次学习：观察 RAM 写入

按第二阶段启动 Guest GDB，在 `after_store` 停住：

```gdb
info registers t0 t3
p/x &result
x/4bx &result
x/wx &result
```

预期 `t0=15`，`t3` 指向 `result`，32 位值为 `0x0000000f`。小端字节序下四个字节为 `0f 00 00 00`。

将汇编求和初值改为 1，得到新变体；预期最终结果为 16。重新编译、加载匹配符号并重复检查，然后恢复基线。这样能确认观察的是本次程序写入，而不是一个恰巧同值的地址。

不要期待每次 RAM store 都经过 `address_space_rw()` 或 `memory_region_dispatch_write()`。TCG 软件 TLB 命中时可以走快速路径；普通 GDB 内存查看也是调试访问，不能当成 Guest load 的执行路径证据。

## 5. 第四次学习：观察 MMIO 的区域内偏移

在宿主 GDB 运行第一阶段 QEMU 参数，将串口输出重定向到文件。设置：

```gdb
break serial_mm_write
run
info args
bt
```

程序先写 UART 偏移 3 设置线路控制，后写偏移 0 输出字符，所以第一次断点不一定是 `K`。观察每次参数：

| 写入 | Guest 地址 | MMIO 回调内 addr | 值 |
| --- | --- | --- | --- |
| 线路控制 | `0x10000003` | `3` | `3` |
| 字符输出 | `0x10000000` | `0` | `75` |

回调的 addr 是区域内偏移，不是完整 Guest 地址。两次访问宽度均为 1 字节。结合 [serial-mm.c](../../hw/char/serial-mm.c) 解释如何进入寄存器实现。

对照 [memory.h](../../include/system/memory.h) 的 `MemoryRegionOps`：`endianness`、`valid`、`impl` 分别控制什么？尤其注意实现宽度与 Guest 允许宽度不是一个概念。

## 6. 第五次学习：理解 TLB 与异常边界

源码阅读入口：

- [cpu_helper.c](../../target/riscv/tcg/cpu_helper.c)：`riscv_cpu_tlb_fill`、`get_physical_address`。
- [cputlb.c](../../accel/tcg/cputlb.c)：软件 TLB 与访存慢路径。
- [memory.c](../../system/memory.c)：区域派发与地址空间操作。

回答：TLB 未命中后谁填充？权限与映射错误在哪里转为架构异常？MMIO 为什么需要进入设备逻辑？只需沿当前访存涉及的分支读，不用读完整 MMU 实现。

在裸机实验中观察到 `satp=0` 并不能证明已经理解页表遍历。分页进阶实验应使用能启动的 Linux，在已知 S/U 模式访存处同时记录模式、satp、虚拟地址和翻译结果；没有准备好 Linux 时，明确将这一项标记为未验证。

有了阶段七的异常基础后，可按[支线十三](13_MMU_AND_LINUX.zh-CN.md)先验证一张 Sv39 大页及写权限异常，无需等待 Linux 镜像。

首轮不要随意访问非法地址做“异常实验”：本裸机没有 trap handler，异常可能跳入未设置的入口并循环。要研究异常，先准备能记录 cause、epc、tval 的受控异常处理程序或使用现成 OS。

## 7. 交付、排错与验收

交付物：地址空间图、`info mtree` 摘录、RAM 字节检查、UART 两次写回调的参数与调用栈。

| 疑问 | 解释方向 |
| --- | --- |
| 宿主查不到 0x80000000 | 误把 GPA 当 HVA |
| RAM 写断点从不触发 | 可能选择了只用于慢路径的函数 |
| UART addr 只有 0 或 3 | 回调收到的是区域偏移 |
| GDB 读内存没有触发预期 TLB 路径 | 调试访问不同于 Guest 执行 load |

- [ ] 能区分 GVA、GPA、HVA。
- [ ] 能用字节结果证明小端 RAM 写入。
- [ ] 能解释 RAM 快速访问与 MMIO 回调的差异。
- [ ] 知道本实验没有验证页表遍历和缓存一致性。

自测：未来 SystemC 设备发 DMA 时，应该传递哪一类地址？如果启用 IOMMU 又有何变化？提示：设备地址空间中的地址；不能把 Guest 用户进程指针或宿主指针直接当 DMA 地址。
