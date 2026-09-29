# 阶段十一：SystemC / TLM 基础与独立模型

[总路线](../QEMU_LEARNING_DESIGN.zh-CN.md) · [上一阶段](10_AUTOMATION_AND_OBSERVABILITY.zh-CN.md) · [下一阶段](12_COSIM_INTEGRATION.zh-CN.md)

## 1. 目标与前置知识

**实验目标：** 独立构建并运行 TLM 寄存器模型，验证读写值、四类错误响应和总计 25 ns 的模拟时间，并通过对照实验解释 delay 与状态可见性的关系。

建议 5 次学习。需要基本 C++ 类、引用、生命周期和构建链接知识；不会 C++ 时先补一份最小类与回调练习。本章仅用于个人本地实验，不用于 QEMU 上游贡献。

先独立运行一个四字节寄存器模型，再进入两个模拟器。配套 [register.cc](../labs/systemc/register.cc) 不使用 QEMU、IPC、DMA 或量子解耦，实际运行记录见[验证记录](../VALIDATION.zh-CN.md)。

| 概念 | 本例中的位置 |
| --- | --- |
| SC_MODULE | Register 和 Bench |
| SC_THREAD | Bench::run，允许等待并让出仿真调度 |
| target socket | Register 接收事务 |
| initiator socket | Bench 发起事务 |
| generic payload | command、address、data、length、response |
| b_transport | 同步函数接口；可在允许等待的仿真上下文中消耗模拟时间 |
| delay | 输入的时间标注，本例由 target 消耗并清零 |

`SC_THREAD` 是 SystemC 仿真进程，不是独立 OS 线程。不要在其中调用阻塞 socket recv 并期望其他仿真进程继续运行。

## 2. 第一次：构建并检查输出

先通过本机包管理或自己构建准备 SystemC 开发库、C++ 编译器和 pkg-config。记录版本：

```bash
c++ --version
pkg-config --modversion systemc
mkdir -p build-study/study-lab/advanced
c++ -std=c++17 -Wall -Wextra learning/labs/systemc/register.cc \
  $(pkg-config --cflags --libs systemc) \
  -o build-study/study-lab/advanced/register
./build-study/study-lab/advanced/register
```

C++ 标准必须与所链接 SystemC 库的构建兼容；若 API 版本符号链接失败，先核对库配置，不通过关闭版本检查掩盖差异。本次本机 SystemC 2.3.3 与 C++17 组合的结果见验证记录，不能推断所有发行版相同。

预期退出码 0，并出现 `PASS register: data, errors, time=25 ns`。不要使用 `-DNDEBUG` 关闭本练习的断言。

## 3. 第二次：逐笔解释事务和时间

| 事务 | 起始内核时间 | 输入 delay | 设备耗时 | 返回内核时间 |
| --- | --- | --- | --- | --- |
| 写 0x12345678 | 0 ns | 5 ns | 10 ns | 15 ns |
| 读回 | 15 ns | 0 ns | 10 ns | 25 ns |
| 四类非法请求 | 25 ns | 0 ns | 0 ns（本例约定） | 25 ns |

target 在 `wait(delay + 10 ns)` 之后才提交读写，返回 delay=0。initiator 不再等待原来的 delay，因此不会重复计时。数据按明确的小端字节序打包；不能直接把宿主 uint32_t 指针当成跨平台线格式。

非法地址、长度、字节使能和命令分别返回错误，不改变寄存器。payload 与四字节数组都在同步调用结束前有效，本例不在 target 保存它们的指针。

接口签名可对照 [Accellera simple_target_socket](https://github.com/accellera-official/systemc/blob/main/src/tlm_utils/simple_target_socket.h)；实际实验应记录安装版本，在线 main 仅用于阅读。

## 4. 第三次：理解事件与 delta cycle

在本地副本中增加一个监测 SC_THREAD，在 14 ns 和 16 ns 查看本模型公开的 value：预期前者为初值 0，后者为 0x12345678。这个观察仅为教学，不作为未来设备公共接口。

再比较 `wait(SC_ZERO_TIME)` 前后的 `sc_time_stamp()` 与 `sc_delta_count()`：时间戳可以不变，delta 计数增加。把结果写入日志，不要求所有线程在同一时间戳的打印次序天然表示数据依赖。

若添加 `sc_event`，定义谁先等待、谁通知；即时通知不会替未来才开始等待的进程保存“令牌”。需要持久状态的条件，应使用状态变量加循环检查，不能仅靠一次通知。

## 5. 第四次：练习 delay 的另一种约定

仅在独立副本中，把 target 的等待改为给 delay 增加 10 ns，由 initiator 在调用后 `wait(delay)` 并清零。对单发起方串行基线可以得到相同总时间。

同时保留第三次的并发监测者：如果 target 立即更新 value，14 ns 时可能提前看到新值。解释为什么“返回一个延迟”不会自动安排状态在未来提交。该变体用于暴露问题，不作为联合仿真可直接采用的模型。

首轮不加入 quantum keeper；先掌握状态可见性，再读 ESL 第 7 节的时间解耦与授权边界。

## 6. 第五次：升级为异步任务的设计练习

给模型设计 ID、START、BUSY、DONE 和清除状态接口。START 的传输完成后，独立仿真进程再等待任务延迟并更新 DONE；不能让 START 的寄存器写一直等待整个任务完成。

先在同一 SystemC 进程中用 byte 数组做 DMA 目标，检查输出先写入、DONE 后置位。规定零长度、重叠、越界、BUSY 时再次 START、复位中止任务的行为，并为每项安排测试。这是下一阶段 P1 的扩展工作，当前 register.cc 只实现寄存器基础，不声称已实现拷贝设备。

交付：运行日志、事务时间表、并发观察对照、异步任务状态图。能够解释“调用返回时间、状态提交时间、任务完成时间”后再进入桥接。
