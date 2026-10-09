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

本节从一条真实的 `add t0, t0, t1` 出发，沿着“机器码 → 解码参数 → 翻译函数 → TCG 操作”走一遍。命令从仓库根目录执行。若系统没有 `rg`，以下使用 `grep`。

### 4.1 找到解码规则和翻译函数

先确认 ELF 里的 `add` 地址和指令，再定位 QEMU 中对应实现：

```bash
riscv64-linux-gnu-objdump -d build-study/study-lab/program.elf
grep -n -E '^add[[:space:]]|^addi[[:space:]]|^bne[[:space:]]' target/riscv/insn32.decode
grep -n -E 'trans_add\(|trans_addi\(|trans_bne\(' target/riscv/tcg/insn_trans/trans_rvi.c.inc
```

在反汇编的 `sum_loop` 里找到 `add`。它应当是类似 `add t0,t0,t1` 的指令；RISC-V 中 `t0` 是 `x5`，`t1` 是 `x6`。`insn32.decode` 描述机器码位如何匹配指令、如何提取操作数；生成的解码器再把操作数交给 `trans_add`。解码器是构建生成的，不要手工修改生成文件。

### 4.2 从源码追踪一次翻译

依次查看下面这些位置：

```bash
grep -n -E 'riscv_tr_translate_insn|decode_opc|decode_insn32' target/riscv/tcg/translate.c
grep -n -E 'trans_add\(|trans_addi\(|trans_bne\(' target/riscv/tcg/insn_trans/trans_rvi.c.inc
grep -n -E 'gen_arith\(|gen_arith_imm_fn\(|gen_branch\(|get_gpr\(|dest_gpr\(|gen_set_gpr\(' target/riscv/tcg/translate.c
grep -n -E 'translate_insn|ops->translate_insn' accel/tcg/translator.c
```

可以用 `sed -n '起始行,结束行p' 文件名` 查看搜索结果附近的代码。例如：

```bash
sed -n '715,740p' target/riscv/tcg/insn_trans/trans_rvi.c.inc
sed -n '963,989p' target/riscv/tcg/translate.c
sed -n '405,430p' target/riscv/tcg/translate.c
```

阅读时对照这条路径：

```text
riscv_tr_translate_insn
  → decode_opc / 自动生成的 decode_insn32
  → trans_add(ctx, a)
  → gen_arith(..., tcg_gen_add_tl, ...)
  → get_gpr 取 rs1、rs2；dest_gpr 准备目的值
  → 生成 TCG 加法；gen_set_gpr 写回 rd
```

对 `add t0,t0,t1`，解码参数应对应 `rd=x5, rs1=x5, rs2=x6`。`trans_add` 本身只是选择通用加法翻译函数和 TCG 加法操作；它运行时是在**生成翻译**，不是完成 Guest 的一次加法执行。`addi` 类似，但第二个输入是立即数。`bne` 调用 `gen_branch`，比较两个寄存器并生成条件分支。

特别看 `dest_gpr` 和 `gen_set_gpr`：`x0` 作为源寄存器读取时提供常数零；写回时若 `rd==0` 则不写入 CPU 状态。这就是 `x0` 恒为零的关键处理。再看 `get_gpr` 如何把 Guest 寄存器映射到 TCG 值。不要只看到 `tcg_gen_add_tl` 就结束；要跟到结果如何写回。

### 4.3 用宿主 GDB 在翻译函数处停下

确认 `build-study` 是带调试信息的构建（第一阶段使用 `--enable-debug`），在一个终端从仓库根目录运行：

```bash
gdb --args ./build-study/qemu-system-riscv64 \
  -machine virt -accel tcg,thread=single -smp 1 -m 128M \
  -bios none -display none -monitor none \
  -serial file:build-study/study-lab/host-debug-uart.log \
  -device loader,file=build-study/study-lab/program.elf,cpu-num=0
```

在宿主 GDB 提示符依次输入：

```gdb
set pagination off
break trans_add
run
bt
info args
info locals
p/x ctx->base.pc_next
p a->rd
p a->rs1
p a->rs2
```

断点命中时，调用栈应显示 QEMU 正在翻译 Guest 指令；`pc_next` 应与反汇编中 `sum_loop` 的 `add` 地址相符，操作数寄存器编号应是 `5, 5, 6`。结构字段或变量若显示不可用，以当前构建中的 `info args`、`info locals` 和源码为准。若 `break trans_add` 找不到符号，先检查是否用了本仓库的调试版 QEMU；也可用 `break target/riscv/tcg/insn_trans/trans_rvi.c.inc:行号` 设置源码行断点。

这次命中只证明 QEMU 正在为包含该 Guest 指令的 TB 生成代码。循环动态执行五次，并不意味着 `trans_add` 一定会被调用五次；TB 生成后通常会被重复执行。用 `continue` 可以观察后续翻译断点，按 `Ctrl+C` 中断，输入 `quit` 退出 GDB。

### 4.4 对照 TCG 日志

从仓库根目录另开终端运行下列命令。它会运行 Guest 程序、在终端输出字符，并把翻译日志写入文件：

```bash
./build-study/qemu-system-riscv64 \
  -machine virt -accel tcg,thread=single -smp 1 -m 128M \
  -bios none -display none -monitor none -serial stdio \
  -device loader,file=build-study/study-lab/program.elf,cpu-num=0 \
  -d in_asm,op,out_asm -D build-study/study-lab/tcg.log
```

看到预期字符后按 `Ctrl+C` 停止 QEMU，再根据反汇编里的 `add` 地址搜索日志：

```bash
grep -n -A20 -B3 '8000000c' build-study/study-lab/tcg.log
```

如果你的 `add` 地址不是 `0x8000000c`，把命令中的地址换成自己的。日志格式和宿主汇编会随构建版本、优化和宿主架构变化；重点辨认 `in_asm` 中的 Guest 指令、`op` 中与加法及寄存器读写相关的 TCG 操作、`out_asm` 中生成的 Host 指令。三者不保证逐行一一对应。也可用 `less` 打开日志并搜索地址。

完成后记录：Guest PC、解码得到的 `rd/rs1/rs2`、`trans_add` 调用的辅助函数、观察到的 TCG 操作，以及 Guest GDB 中一次 `add` 执行前后的 `t0`。这些证据来自不同阶段：宿主断点和 TCG 日志看翻译，Guest GDB 看执行。

首次学习只需读 [TCG 概述](../../docs/devel/tcg.rst) 和 [TCG 操作](../../docs/devel/tcg-ops.rst) 中遇到的概念。解码生成过程可参考 [decodetree](../../docs/devel/decodetree.rst)，不必完整学习其语法。

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
