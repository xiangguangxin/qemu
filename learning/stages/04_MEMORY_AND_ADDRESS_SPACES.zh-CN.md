# 阶段四：地址空间、RAM 与 MMIO

[返回总路线](../QEMU_LEARNING_DESIGN.zh-CN.md) · [上一阶段](03_TCG_AND_INSTRUCTIONS.zh-CN.md) · [下一阶段](05_DEVICES_AND_INTERRUPTS.zh-CN.md)

## 1. 目标与前置条件

建议 5 次学习，每次 1～2 小时。已能使用 Guest GDB，并理解翻译与执行的区别。使用第一阶段 ELF 与启动参数；本章为个人本地实验。

本阶段跟通两次访问：`sw t0, 0(t3)` 写 RAM，`sb t5, 0(t4)` 写 UART。最小裸机实验不建立页表；分页内容先做源码分析，再使用 Linux 扩展验证。

## 2. 第一次学习：区分三个地址

| 地址 | 谁使用 | 示例与限制 |
| --- | --- | --- |
| Guest 虚拟地址 GVA | Guest 指令与软件 | 开启地址转换时需查页表 |
| Guest 物理地址 GPA | 模拟的平台地址空间 | RAM、UART 等按此布局 |
| Host 虚拟地址 HVA | QEMU 宿主进程 | RAM backing 的实际指针 |

裸机默认 M-mode、没有额外设置 MPRV 等机制时，不走普通 S-mode 分页转换；此实验访问可按 Guest 物理地址分析。不要据此推广到 Linux 用户进程或所有特权模式。

`0x80000000` 在本平台表示 RAM 的起点，不能直接作为宿主指针。Guest 物理地址也不等于 Host 物理地址。

```text
Guest 指令中的地址
  → 架构相关转换与权限检查（是否分页取决于模式）
  → Guest 物理地址空间
  ├─ RAM：访问宿主 backing memory
  └─ MMIO：调用设备访问逻辑
```

读 [内存模型](../../docs/devel/memory.rst) 的区域类型和可见性部分，再读 [访存接口](../../docs/devel/loads-stores.rst)。

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
