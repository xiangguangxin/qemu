# 阶段三：跟踪指令翻译与执行

[返回总路线](../QEMU_LEARNING_DESIGN.zh-CN.md) · [上一阶段](02_BOOT_AND_DEBUG.zh-CN.md) · [下一阶段](04_MEMORY_AND_ADDRESS_SPACES.zh-CN.md)

## 1. 目标与节奏

**实验目标：** 结合反汇编、TCG 日志和 Guest 寄存器记录，跟通一条 `add` 与一条分支的翻译和执行，解释五轮求和及 TB 复用的条件。

建议 8 次学习，每次 1～2 小时，用两周完成。延用第一阶段裸机程序，不改 QEMU。目标是解释一条加法如何变成可执行代码，以及一个循环为什么可以复用翻译结果。实验均限于本地学习。

本章始终区分两个动作：**翻译是在生成 Host 代码，执行是在运行生成的代码。** 在 `trans_add` 打断点观察到的是翻译过程，不是每次 Guest 加法执行。

## 2. 需要掌握的概念

| 概念 | 含义 | 不应误解为 |
| --- | --- | --- |
| Guest 指令 | RISC-V 编码及语义 | Host 可直接执行的指令 |
| TCG IR | QEMU 的中间操作表示 | 必定与 Guest 指令一一对应 |
| TB | 一段代码在特定翻译状态下生成的执行块 | 整个函数或固定长度指令组 |
| helper | 生成代码可调用的宿主辅助逻辑 | 所有指令都必须经过的路径 |
| TB chaining | 减少块间返回调度器开销的连接方式 | 修改了 Guest 程序控制流 |

TB 的身份不只有 PC，还与架构执行状态和翻译条件有关。代码变化、异常、调试模式等也可能影响复用。第一次先掌握概念，不追求读完缓存管理。

## 3. 第 1～2 次学习：确定真正执行的指令

```bash
riscv64-linux-gnu-objdump -d build-study/study-lab/program.elf
rg -n 'add |addi |bne ' target/riscv/insn32.decode
rg -n 'trans_add\(|trans_addi\(|trans_bne\(' target/riscv/tcg/insn_trans/trans_rvi.c.inc
```

反汇编中记录 `sum_loop` 对应的地址、机器码、`add` 的三个寄存器和 `bne` 的目标。`li`、`la`、`j` 是汇编层面的伪指令，不能直接假设源码字符串就是解码器中的真实指令名。

使用第二阶段 Guest GDB，在 `sum_loop` 停住。执行一次 `add`，确认 `t0` 从 0 变为 1；继续观察几轮，预期累加值为 1、3、6、10、15。为每轮记录输入和输出。

## 4. 第 3～4 次学习：阅读翻译前端

按顺序阅读：

1. [insn32.decode](../../target/riscv/insn32.decode)：指令位模式和参数提取。
2. [translate.c](../../target/riscv/tcg/translate.c)：搜索 `riscv_tr_translate_insn`，了解如何调用解码与翻译逻辑。
3. [trans_rvi.c.inc](../../target/riscv/tcg/insn_trans/trans_rvi.c.inc)：阅读 `trans_add`、`trans_addi`、`trans_bne`，沿它们实际调用的辅助函数继续追踪。
4. [translator.c](../../accel/tcg/translator.c)：观察架构回调如何被通用翻译流程调用。

阅读任务：标出 Guest 源寄存器在哪里被取用、TCG 值如何计算、目的寄存器如何被表示；追踪 x0 不可写的语义由哪层维护。不要只看到一个 `tcg_gen_*` 名称就结束。

读 [TCG 概述](../../docs/devel/tcg.rst) 与 [TCG 操作](../../docs/devel/tcg-ops.rst) 中遇到的操作即可。解码生成过程可参考 [decodetree](../../docs/devel/decodetree.rst)，首轮不必完整学习其语法。

在宿主 GDB 中对 `trans_add` 设置断点，以 Guest PC 与解码参数确认是否为目标指令。变量名以当前函数 `info args`、`info locals` 为准。静态函数若因优化无法断下，使用文件行断点或先检查调试构建。

## 5. 第 5 次学习：生成一份短日志

先确认本版本支持的日志选项：

```bash
./build-study/qemu-system-riscv64 -d help
```

确认存在 `in_asm`、`op`、`out_asm` 后，从仓库根目录运行：

```bash
./build-study/qemu-system-riscv64 \
  -machine virt -accel tcg,thread=single -smp 1 -m 128M \
  -bios none -display none -monitor none -serial stdio \
  -device loader,file=build-study/study-lab/program.elf,cpu-num=0 \
  -d in_asm,op,out_asm -D build-study/study-lab/tcg.log
```

出现 `K` 后结束进程。按反汇编获得的地址定位，而不是依赖日志一定包含符号名。

| 日志 | 阅读目的 |
| --- | --- |
| `in_asm` | 确认本次翻译的 Guest 指令范围 |
| `op` | 找到对应中间操作及寄存器状态关联 |
| `out_asm` | 看 Host 指令；其架构取决于运行 QEMU 的宿主 |

一条 Guest 指令可能生成多个 IR，多个 IR 也可能被优化。记录“观察到的关联”，不要强求三者逐行一一对应。

## 6. 第 6～7 次学习：理解执行和复用

阅读 [cpu-exec.c](../../accel/tcg/cpu-exec.c) 的 `cpu_exec`、`cpu_tb_exec`，以及 [translate-all.c](../../accel/tcg/translate-all.c) 的 `tb_gen_code`。画出概念流程：

```text
当前 Guest 执行状态
  → 查找可用 TB
  → 缺失时生成 TB
  → 执行 Host 代码
  → 跳转到其他块，或退出处理事件/异常
```

做两组独立记录：Guest GDB 证明循环中的 `add` 执行五次；翻译日志和宿主翻译断点说明何时发生翻译。不要把断点与单步下的 TB 行为直接当作普通运行的行为，因为调试本身可能改变块划分。

若使用 `exec` 日志，短时间采样并及时停止；`done` 无限循环可能产生大量输出。TB chaining 也会影响通过宿主调度器观察执行的方式，因此日志行数不能未经分析直接转换为指令次数。

## 7. 第 8 次学习：整理解释与做一个变体

把循环上界从 6 改为 4，重新构建独立 ELF，预期结果为 6。比较：指令语义没有改变，数据与循环次数改变；程序映像不同，不能比较两次进程的 TB 指针来证明缓存复用。

交付：一条 add 的“机器码→解码参数→翻译函数→IR→状态变化”记录，一条分支说明，一张翻译与执行关系图。

## 8. 验收与自测

- [ ] 能解释翻译断点和执行断点的区别。
- [ ] 能找到 add、addi、bne 的源码实现入口。
- [ ] 能用数据证明五轮加法的结果。
- [ ] 知道 TB 通常可以复用，但并非只由 PC 决定。
- [ ] 不把 `in_asm` 条目数当成动态指令数。

自测：一次 load 为什么可能比 add 的翻译更复杂？提示：地址空间、权限、慢路径与异常。为什么给 Guest 一条指令固定 1 ns 仍不是周期精确模拟？提示：实际流水线、缓存和执行依赖没有因此被建模。这两个问题分别衔接访存和 ESL 时间同步。
