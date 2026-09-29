# 阶段十：自动化验证、QMP 与 trace

[总路线](../QEMU_LEARNING_DESIGN.zh-CN.md) · [上一阶段](09_DEVICE_DMA_LAB.zh-CN.md) · [下一阶段](11_SYSTEMC_TLM_FOUNDATIONS.zh-CN.md)

## 1. 目标

**实验目标：** 建立具有明确通过、失败和超时判定的设备回归流程，保存 qtest 成败日志、QMP 运行状态变化及与实验问题对应的 trace 证据。

建议 3 次学习。仅用于本地实验。把人工观察转成可重复的通过/失败判断；不要求为文档和每个小改动添加测试。实际状态见[验证记录](../VALIDATION.zh-CN.md)。

| 工具 | 本课程用途 | 不能替代的证据 |
| --- | --- | --- |
| Guest GDB | 指令、寄存器、trap 与程序状态 | 设备内部线程和锁 |
| Host GDB | C 栈、回调、上下文 | Guest 软件功能验收 |
| qtest | 设备读写与可控虚拟时间 | CPU 执行、真实 Guest 驱动 |
| QMP | 运行状态、暂停、恢复、复位和退出 | 指令级调试 |
| trace / -d | 特定事件及翻译记录 | 未启用路径、未经分析的动态计数 |

## 2. 第一次：把阶段九变成回归基线

运行 [dma_qtest.py](../labs/edu/dma_qtest.py)，保存完整输出、退出码、QEMU 路径与版本。脚本在 PCI 身份、寄存器值、DMA 数据、IRQ 状态任一不符时失败，连接和读取具有墙钟超时，退出时回收子进程。

阅读[QTest 文档](../../docs/devel/testing/qtest.rst)及 `system/qtest.c` 协议。观察脚本为何要主动推进虚拟时间，而不能直接在寄存器轮询中无限等待。

当前脚本没有订阅 qtest IRQ 截获事件，只验证设备 IRQ 状态寄存器；若增加 `irq_intercept_*`，接收端必须识别异步 IRQ 行，不能假设每一行都是上一条命令响应。

把每个测试写成“输入→预期→观察点→失败条件”。为自己的代理设备补充复位、非法宽度、BUSY 重入和中途失败语义；EDU 没有的语义不能据其测试结果推断。

## 3. 第二次：QMP 控制实验生命周期

在阶段一启动参数中增加：

```text
-qmp unix:build-study/study-lab/advanced/qmp.sock,server=on,wait=off
```

先创建父目录。通过支持 Unix socket 的终端工具连接，例如本机已安装 socat 时运行：

```bash
socat -,echo=0 UNIX-CONNECT:build-study/study-lab/advanced/qmp.sock
```

收到 greeting 后逐条发送 JSON，每条一行：

```json
{"execute":"qmp_capabilities","id":"hello"}
{"execute":"query-status","id":"before"}
{"execute":"stop","id":"pause"}
{"execute":"query-status","id":"paused"}
{"execute":"cont","id":"resume"}
{"execute":"system_reset","id":"reset"}
{"execute":"quit","id":"exit"}
```

查看[QMP 协议](../../docs/interop/qmp-spec.rst)。命令返回与异步事件可能交错，自动化客户端按 id 匹配响应；`stop` 成功后再查询应显示不在运行。`system_reset` 返回成功只证明控制命令被接受，还要检查 Guest PC、设备寄存器和 IRQ 等复位结果。

每次使用新运行目录，避免连接到旧实例。不得把其他进程创建的 socket 当成可随意删除的临时文件。

## 4. 第三次：最小 trace 与故障证据

先发现当前构建实际提供的事件：

```bash
./build-study/qemu-system-riscv64 -trace help
rg -n 'serial|plic|aclint|dma' hw/char/trace-events hw/intc/trace-events hw/misc/trace-events
```

从列表选择与本次问题对应的实际事件名称，每行一个保存到本地 `events.txt`，启动参数增加 `-trace events=路径`。输出位置取决于构建启用的 trace backend，按[tracing 文档](../../docs/devel/tracing.rst)选择；不要假设任意构建均产生相同格式文件。

报告同时保留 Guest 输入、Guest 状态和 Host 事件。记录运行 ID，把不同轮次日志分开，避免将两个进程的时间戳拼成一条精确时间线。

## 5. 最小回归表

| 用例 | 必须观察 | 失败判定 |
| --- | --- | --- |
| 基础 ELF | K 与 result=15 | 任一不符 |
| trap/IRQ | 三个计数与 UART 字节 | 缺失、重复或 unexpected |
| EDU DMA | 源/目标逐字、BUSY、IRQ status | 超时或数据不符 |
| SystemC 模型 | 数据、错误状态、25 ns | 非零退出或断言失败 |
| 代理复位（后续实现） | epoch、任务、IRQ、已提交 RAM | 旧任务继续生效 |

交付：一份通过日志、一份故意变更预期后产生的失败日志、QMP 状态记录、选定 trace 事件说明。程序挂住后由超时终止属于失败，不计为完成实验。
