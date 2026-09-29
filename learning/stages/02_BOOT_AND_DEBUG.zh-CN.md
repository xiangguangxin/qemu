# 阶段二：跟踪启动并掌握两侧调试

[返回总路线](../QEMU_LEARNING_DESIGN.zh-CN.md) · [上一阶段](01_ENVIRONMENT_AND_FIRST_RUN.zh-CN.md) · [下一阶段](03_TCG_AND_INSTRUCTIONS.zh-CN.md)

## 1. 目标与准备

**实验目标：** 分别使用 Host GDB 和 Guest GDB 捕获整机初始化调用栈、验证内存参数，并在程序断点处确认求和结果为 15、UART 写入值为 75。

建议 5 次学习，每次 1～2 小时。准备第一阶段的调试构建和 `program.elf`，所有 shell 命令从仓库根目录运行。本文属于总路线约定的个人本地调试实验。

本阶段必须分别完成：在宿主 GDB 中停到 QEMU 的初始化函数；在 Guest GDB 中单步 RISC-V 指令并确认求和结果。两次实验先分开做，熟悉后再同时连接。

## 2. 两个调试器看的不是同一套状态

| 操作 | 宿主 GDB | Guest GDB |
| --- | --- | --- |
| 加载文件 | `qemu-system-riscv64` | `program.elf` |
| 断点 | `qemu_init`、`virt_machine_init` | `_start`、`sum_loop` |
| 寄存器 | 宿主进程当前线程的寄存器 | Guest CPU 的寄存器 |
| 内存地址 | QEMU 进程的虚拟地址 | 通常是 Guest 虚拟地址 |
| 调用栈 | QEMU 的 C 调用路径 | Guest 程序调用路径 |

宿主 GDB 的 `x/4wx 0x80000000` 不等于查看 Guest RAM。不要因为数字相同就混用两个地址空间。

## 3. 第一次学习：从入口读到整机创建

按以下顺序阅读，每次只追踪与当前问题有关的调用：

| 源码 | 搜索入口 | 本次问题 |
| --- | --- | --- |
| [main.c](../../system/main.c) | `qemu_init` | 初始化从哪里进入？ |
| [vl.c](../../system/vl.c) | `qemu_init` | 参数如何进入 machine 创建流程？ |
| [virt.c](../../hw/riscv/virt.c) | `virt_machine_init` | RAM 与设备在哪里组织？ |
| [cpu.c](../../target/riscv/cpu.c) | `riscv_cpu_realize` | CPU 类型什么时候变成可运行实例？ |
| [runstate.c](../../system/runstate.c) | `qemu_main_loop` | 初始化之后由谁控制运行？ |

```bash
rg -n 'qemu_init\(|qemu_main_loop\(' system/
rg -n 'virt_machine_init|mc->init|type_init' hw/riscv/virt.c
rg -n 'riscv_cpu_realize|device_class_set_parent_realize' target/riscv/cpu.c
```

先认识“注册类型→创建实例→设置属性→realize”的概念。注册回调不等于此时执行回调；初始化函数也不必由 main 直接调用。画图时把回调箭头标出来。

## 4. 第二次学习：宿主 GDB 捕获初始化证据

```bash
gdb --args ./build-study/qemu-system-riscv64 \
  -machine virt -accel tcg,thread=single -smp 1 -m 128M \
  -bios none -display none -monitor none \
  -serial file:build-study/study-lab/host-debug-uart.log \
  -device loader,file=build-study/study-lab/program.elf,cpu-num=0
```

在宿主 GDB 执行：

```gdb
set pagination off
break qemu_init
break virt_machine_init
break riscv_cpu_realize
run
bt
info args
continue
```

后续每次停止先看当前函数，再决定检查什么。在 `virt_machine_init` 处尝试：

```gdb
p machine->ram_size
p machine->smp.cpus
bt
```

预期 RAM 大小是 `134217728` 字节、CPU 数量是 1。若符号被优化或字段有版本变化，先用 `ptype *machine` 和源码确认，不能直接判定初始化错误。

保存实际调用栈，不把本章阅读顺序当成调用顺序。结束后重新启动，将 `-m` 改为 `256M`，检查对应字段变为 `268435456`。这构成“命令行参数→内部状态”的证据。

## 5. 第三次学习：Guest GDB 查看指令

先结束上一轮 QEMU。终端 A：

```bash
./build-study/qemu-system-riscv64 \
  -machine virt -accel tcg,thread=single -smp 1 -m 128M \
  -bios none -display none -monitor none -serial stdio \
  -device loader,file=build-study/study-lab/program.elf,cpu-num=0 \
  -S -gdb tcp:127.0.0.1:1234
```

`-S` 在执行 Guest 前暂停；`-gdb` 提供调试连接。终端 B 使用支持 RISC-V 的 GDB，下面以 `gdb-multiarch` 为例：

```bash
gdb-multiarch build-study/study-lab/program.elf
```

```gdb
set pagination off
target remote 127.0.0.1:1234
info registers pc
x/8i $pc
display/i $pc
si
info registers t0 t1 t2
```

预期初始 PC 对应 `_start`。本实验使用 loader 直接设置入口，因此不会先观察到 OpenSBI。每次 `si` 前预测下一条指令的效果，再核对寄存器。

GDB stub 的系统模拟用法见 [官方文档](https://www.qemu.org/docs/master/system/gdb.html)。

## 6. 第四次学习：用断点验证结果

在 Guest GDB 中：

```gdb
break after_store
continue
info registers t0 t1 t2 t3
x/wx &result
break uart_write
continue
info registers t4 t5
x/i $pc
si
```

在 `after_store` 处预期 `t0=15`、`t1=6`、`result=0x0000000f`。在 `uart_write` 处预期 `t4=0x10000000`、`t5=75`；执行 `sb` 后终端 A 应出现 `K`。

确认“断点停在执行前”的意义：到达 `uart_write` 时字符尚未必输出。若重复运行需重启 QEMU，避免把前一轮寄存器和内存状态混入本轮。

## 7. 第五次学习：对照两个视角

先在 Guest 调试中找到 `uart_write`，再进行独立一轮宿主调试，对 `serial_mm_write` 设置断点。比较两份记录：Guest 侧看到 store 指令与物理设备地址；Host 侧看到回调参数和 C 栈。

同时使用两个 GDB 是进阶操作：宿主 GDB 暂停整个 QEMU 时，Guest GDB 可能等待响应。这不一定是桥接或网络故障，应先继续宿主进程。

## 8. 常见问题与验收

| 问题 | 处理 |
| --- | --- |
| gdb 不认识 RISC-V | 使用支持该架构的 GDB，核对 `show architecture` |
| 1234 已占用 | 结束旧实例或两端同时改端口 |
| `break qemu_init` 在 Guest GDB 无效 | 调试对象选错，应使用宿主 GDB |
| 断点地址不对应源码 | ELF 与运行镜像是否来自同一次构建？ |
| 宿主栈看不到 Guest 函数 | 两者本来就是不同调用体系 |

交付物：`boot-flow.md`、两份初始化调用栈、参数对照记录、Guest 寄存器与结果内存记录。

- [ ] 能分别说明两个 GDB 加载的文件和地址空间。
- [ ] 能证明 RAM 参数生效，并定位负责整机初始化的回调。
- [ ] 能在字符写出前停住，并核对数值与地址。
- [ ] 能说明主循环、vCPU 执行和 Guest 程序循环的区别。

自测：为何 `qemu_main_loop()` 不是每条 Guest 指令的解释器？为何宿主 GDB 暂停后，Guest GDB 也可能失去响应？回答应涉及线程和宿主进程对 Guest 执行的承载关系。
