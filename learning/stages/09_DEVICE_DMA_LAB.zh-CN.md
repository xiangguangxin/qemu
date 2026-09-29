# 阶段九：通过 EDU 实践设备寄存器与 DMA

[总路线](../QEMU_LEARNING_DESIGN.zh-CN.md) · [上一阶段](08_EVENT_LOOPS_AND_TIME.zh-CN.md) · [下一阶段](10_AUTOMATION_AND_OBSERVABILITY.zh-CN.md)

## 1. 为什么增加这一层

**实验目标：** 通过 qtest 配置 EDU 的 PCI/MMIO 接口，完成 RAM 与设备缓冲区之间的双向 DMA，逐字核对数据，并验证完成中断状态的置位与清除。

建议 5 次学习。先验证 QEMU 内部的寄存器、设备缓冲区、DMA 和通知，再做跨进程联合仿真。本章使用已有 [EDU 教学设备](../../docs/specs/edu.rst)，不修改 QEMU 核心。配套脚本仅用于个人本地实验，状态见[验证记录](../VALIDATION.zh-CN.md)。

EDU 是 PCI 设备，不是后续拟议的 SysBus 代理。这里额外学习最少的 PCI 配置：发现设备、分配 BAR、开启 Memory Space 与 Bus Master。不能把 EDU 的寄存器表套到 SystemC 拷贝设备上。

## 2. 第一次：读规范，建立访问表

| 地址/字段 | 本实验作用 |
| --- | --- |
| PCI `1234:11e8` | 确认设备身份 |
| BAR0 + 0x04 | 写入值取反后读回，验证寄存器语义 |
| +0x24 / +0x60 / +0x64 | IRQ 原因、置位、确认 |
| +0x80 / +0x88 / +0x90 | DMA 源、目的、长度 |
| +0x98 | START、方向、完成 IRQ |
| 设备地址 0x40000 | EDU 内部 4096 字节缓冲区 |

跟踪 `hw/misc/edu.c` 的 `edu_mmio_write`、`dma_rw`、`edu_dma_timer`、`edu_raise_irq`。尤其注意：当前 EDU 使用虚拟定时器安排 DMA；没有推进模拟时间，轮询寄存器不保证任务完成。

## 3. 第二次：运行现成的设备级实验

先完成阶段一构建并确认 `-device help` 包含 edu。脚本会创建独立 QEMU 子进程并在退出时回收，不连接已有实例：

```bash
mkdir -p build-study/study-lab/advanced
python3 learning/labs/edu/dma_qtest.py \
  --qemu ./build-study/qemu-system-riscv64 \
  > build-study/study-lab/advanced/edu-qtest.log
```

只有命令退出码为 0，且日志含 `PASS EDU` 才通过。失败先查看日志与 stderr，不把超时当成测试通过。

脚本固定 `virt`、bus 0 / slot 1 / function 0、ECAM `0x30008000`、BAR0 `0x40000000`，并检查 PCI ID。它显式开启 PCI Memory Space 和 Bus Master，以免把被禁用的 DMA 地址空间误判为 RAM 错误。

virt RAM 在 0x80000000 起，而 EDU 默认 DMA mask 只有 28 位。因此脚本设置 `dma_mask=0xffffffff`，覆盖本实验 128 MiB RAM；否则地址会被截断。这是本平台的重要前置条件。

## 4. 第三次：解释双向 DMA 证据

脚本将四个不同 32 位值写到源 RAM，并把目标填为 `0xcccccccc`。

1. 源 RAM→EDU 缓冲区，DMA command=1。
2. 推进 100000000 ns，检查 START 清除。
3. 确认目标 RAM 尚未改变。
4. EDU 缓冲区→目标 RAM，command=7（START、反向、IRQ）。
5. 再推进 100000000 ns，逐字比较结果，检查 IRQ status=0x100。
6. 写 acknowledge 后，检查 IRQ status=0。

100 ms 是当前 EDU 实现使用的教学延迟，不是真实 DMA 带宽。两次 clock_step 是 qtest 控制时间，不是 Guest 执行。

在宿主 GDB 中调试同样配置，观察 `edu_dma_timer` 到 `pci_dma_read/write` 的地址空间路径。脚本证据证明设备寄存器和 RAM 副作用，不证明 Guest 中断处理；Guest trap 能力由阶段七独立验证。

## 5. 第四次：对照与失败语义

复制脚本到本地实验目录再变更：

| 变体 | 预期检查 |
| --- | --- |
| 更换源数据 | 输出逐字匹配新数据，不是残留缓存 |
| 第一段仅推进 50000000 ns | START 仍置位，再推进余量后完成 |
| 去掉输出 DMA 的 IRQ 位 | 数据正确，IRQ status 不置位 |
| 恢复默认 DMA mask | 不再期待原地址数据正确，定位地址截断日志 |

每轮新建实例，恢复基线后重跑。非法宽度和超范围行为应先阅读当前实现再写预期。EDU 并非完整的桥接错误语义模板：当前 DMA 回调没有把所有内存事务错误转换成可供 Guest 检查的状态，不能以 START 清除证明每种错误都被正确报告。

## 6. 第五次：为本地代理设备写规范

在实验报告中写出自己的设备契约：ID、配置寄存器、START 锁存点、BUSY 重入规则、DONE/ERROR、W1C、IRQ 电平、复位、长度和地址范围。采用 ESL 文档第 9 节建议布局即可。

此步先写可执行的验收表，而不是立刻复制 EDU 实现。独立设备开发练习应限制为个人本地分支；第一轮只加 ID、一个读写寄存器和复位，验收后再加 timer、IRQ、DMA。

交付：完整 qtest 日志、DMA 地址与数据表、两个对照结果、EDU 与拟议代理的差异表。复位行为还需检查当前 EDU 类型是否提供所需 reset 方法；重新启动进程不能替代验证设备 reset。
