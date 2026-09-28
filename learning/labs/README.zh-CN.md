# 本地学习实验材料

所有材料用于个人研究、调试和本地实验，不用于 QEMU 上游贡献；遵循[代码来源政策](../../docs/devel/code-provenance.rst)。生成文件放在 `build-study/study-lab/advanced/`，不放入教材目录。

| 材料 | 对应教材 | 能验证什么 |
| --- | --- | --- |
| [interrupts/traps.S](interrupts/traps.S) | [阶段七](../stages/07_TRAPS_INTERRUPTS_AND_TIMERS.zh-CN.md) | ecall、timer、UART RX、PLIC、WFI |
| [interrupts/paging.S](interrupts/paging.S) | [支线十三](../stages/13_MMU_AND_LINUX.zh-CN.md) | Sv39 大页、MPRV、写权限异常 |
| [interrupts/link.ld](interrupts/link.ld) | 两个裸机实验共用 | RV64 入口与加载布局 |
| [edu/dma_qtest.py](edu/dma_qtest.py) | [阶段九](../stages/09_DEVICE_DMA_LAB.zh-CN.md) | PCI 配置、MMIO、双向 DMA、IRQ 状态 |
| [systemc/register.cc](systemc/register.cc) | [阶段十一](../stages/11_SYSTEMC_TLM_FOUNDATIONS.zh-CN.md) | 独立 TLM 事务、错误响应、时间消耗 |

完整构建和运行命令在对应教材。Python 脚本仅依赖标准库，但需要已构建且包含 EDU/qtest 的 `qemu-system-riscv64`；它会创建并回收自己的 QEMU 进程。SystemC 例子需要安装开发库并匹配 C++ ABI。

实际执行范围见[验证记录](../VALIDATION.zh-CN.md)。不能将 ELF 可编译、脚本语法通过、SystemC 单端通过，合并描述为 QEMU 或联合仿真已经运行通过。
