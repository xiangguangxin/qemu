# 阶段八：主循环、执行上下文与虚拟时间

[总路线](../QEMU_LEARNING_DESIGN.zh-CN.md) · [上一阶段](07_TRAPS_INTERRUPTS_AND_TIMERS.zh-CN.md) · [下一阶段](09_DEVICE_DMA_LAB.zh-CN.md)

## 1. 目标与准备

建议 4 次学习。沿用阶段七可运行的 timer/IRQ 程序；仅用于个人本地调试。状态见[验证记录](../VALIDATION.zh-CN.md)。目标是回答“谁执行回调、什么时候执行、等待谁”，为后续双向通信建立基础。

先读[多 IOThread](../../docs/devel/multiple-iothreads.rst)、[icount](../../docs/devel/tcg-icount.rst)。不要求此时掌握多线程 TCG、RCU 或完整协程系统。

| 机制 | 需要区分的职责 |
| --- | --- |
| vCPU 执行 | 执行 Guest、处理退出和异常 |
| 主事件循环 | 服务文件描述符、运行控制和相应事件 |
| AioContext | 关联事件源与服务上下文，不等于任意线程都能操作设备 |
| BH | 延后执行回调，不是新建一个线程 |
| BQL | 串行化需要该锁的 QEMU 状态访问，不是队列锁 |
| QEMU_CLOCK_VIRTUAL | 模拟时间，不是宿主墙钟 |

## 2. 第一次：用线程和调用栈定位执行上下文

使用宿主 GDB 启动阶段七的 QEMU（去掉 Guest `-S/-gdb`，串口仍留在终端）。执行：

```gdb
set pagination off
break qemu_main_loop
break riscv_aclint_mtimer_write
run
info threads
thread apply all bt 6
continue
```

若符号变化先搜索：

```bash
rg -n 'qemu_main_loop|main_loop_wait' system/ util/
rg -n 'timer_mod|timer_new|mtimer.*cb|mtimer.*write' hw/intc/riscv_aclint.c
rg -n 'aio_bh_schedule_oneshot|aio_bh_new|aio_poll' include/qemu/aio.h util/
```

在 mtimer 写入和回调处分别记录线程 ID、栈和时间字段。线程名字或编号依运行环境变化，教材不预设。不要仅凭“在 vCPU 线程”就推断所有操作都无锁。

## 3. 第二次：跟通定时器生命周期

在 `hw/intc/riscv_aclint.c` 中依次标出：mtimecmp 写入、比较期限计算、timer 注册/修改、到期回调、CPU IRQ 更新。把 Guest tick 到 QEMU 时间单位的换算写出来，并与平台 timebase 对照。

做两轮实验，把本地 traps.S 的 `1000000` 改为 `2000000`，分别保存 ELF。验证 compare 与当前 mtime 的差值改变；不要求宿主墙钟耗时精确翻倍。

记录表：

| 事件 | 执行线程/上下文 | 模拟时间/单位 | 被修改状态 |
| --- | --- | --- | --- |
| Guest 写 compare | 实测 | 实测 | compare |
| 定时事件到期 | 实测 | 实测 | timer pending |
| CPU 进入 trap | 实测 | 实测 | mcause/mepc |
| Guest 撤销条件 | 实测 | 实测 | compare/IRQ |

## 4. 第三次：观察 icount 和暂停

两次独立运行阶段七启动命令，第二次增加：

```text
-icount shift=0,align=off,sleep=off
```

先验证同样的计数器结果，再分析时间。固定 shift=0 将执行指令映射到虚拟 ns，但不模拟真实流水线或缓存；WFI 空闲推进也不等于执行了更多指令。没有统一输入时刻的终端输入不能用于证明整段运行完全确定。

再将 `-monitor none -serial stdio` 替换为：

```text
-monitor stdio -serial null
```

此轮只观察 timer，外部 UART 中断不会完成。在 HMP 中执行 `stop`、`info status`、`cont`。区分 VM 暂停与宿主 GDB 暂停：前者仍可以由主循环处理 monitor 命令，后者暂停整个被调试进程时 monitor 也可能无响应。不要把任意墙钟计时器都当成会随 VM 暂停的虚拟定时器。

## 5. 第四次：画等待关系，衔接桥接

分析这条链：vCPU 在 MMIO 中等响应→SystemC 等 QEMU DMA→DMA 服务上下文等 BQL→BQL 被等待中的路径持有。用箭头标出每个等待条件，找出环。

在当前程序中找一个真实 MMIO 栈，定位哪里进入设备回调、哪里持有/要求 BQL；再从 API 文档查一个事件提交接口。这里只进行源码分析，不在任意回调中释放 BQL或递归调用整个主循环。

验收：一张线程与事件图、一份 timer 调度记录、一份普通/固定 icount 对照、一个可解释的等待环。进入 ESL 前必须能说明：接收线程收到数据，不代表设备状态已经允许在该线程中更新。
