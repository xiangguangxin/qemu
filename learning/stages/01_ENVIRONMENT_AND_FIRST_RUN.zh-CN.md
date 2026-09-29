# 阶段一：构建环境与第一次运行

[返回总路线](../QEMU_LEARNING_DESIGN.zh-CN.md) · [下一阶段：启动与调试](02_BOOT_AND_DEBUG.zh-CN.md)

## 1. 本阶段目标

**实验目标：** 独立构建 RISC-V 系统模拟器，编译并运行本章裸机 ELF，确认串口输出 `K`，保存可复现的构建与启动命令。

建议用 5 次学习、每次 1～2 小时完成；首次构建时间另计。最终产出是一个能反复启动的小实验，而不是记住所有启动参数。

必做：构建当前 QEMU，运行一个 RISC-V 裸机程序，看到字符 `K`。选做：启动 Linux 到 shell。后续阶段都使用本章裸机程序，因此没有 Linux 镜像也能继续。

本文用于个人本地实验，遵循 [代码来源政策](../../docs/devel/code-provenance.rst)，不用于上游贡献。命令默认从仓库根目录运行，只有明确注明时才切换目录。

## 2. 先建立五个概念

| 概念 | 本实验中的含义 |
| --- | --- |
| Host | 运行 QEMU 进程的 Linux 环境，可能是 x86-64 |
| Guest | QEMU 模拟的 RISC-V CPU、RAM 和外设 |
| Machine | `virt` 定义硬件组合、地址布局与设备连接 |
| TCG | 把 Guest 指令翻译为 Host 可执行代码的机制 |
| 裸机程序 | 自己提供入口，不依赖 Linux 系统调用与 C 运行时 |

`riscv64-softmmu` 是构建目标名，生成系统模拟器 `qemu-system-riscv64`。`qemu-riscv64` 则是用户态模拟器，两者的启动方式不同。这里的 `virt` 是虚拟平台，不是某块真实开发板的精确复刻。

读 [代码结构](../../docs/devel/codebase.rst) 的目录介绍，再看 [RISC-V virt](../../docs/system/riscv/virt.rst) 的平台与启动部分。第一次只建立目录地图，不逐行阅读实现。

## 3. 第一次学习：检查环境

```bash
pwd
git rev-parse HEAD
uname -a
cat /etc/os-release
cc --version
python3 --version
ninja --version
command -v riscv64-linux-gnu-gcc
command -v gdb-multiarch
```

逐项记录。缺少命令时先解决对应依赖；不要将一整段输出误认为所有工具都已可用。实际验证时需要先安装 GDB、Ninja 和宿主开发库，再构建本仓库 QEMU。阶段实验的状态统一列于[验证记录](../VALIDATION.zh-CN.md)。

Ubuntu/Debian 可以根据本机发行版准备编译器、Ninja、Python、GLib 开发包、pixman 开发包和 libfdt 开发包；具体依赖以 configure 的检查和 [构建环境文档](../../docs/devel/build-environment.rst) 为准。Guest 调试另需支持 RISC-V 的 GDB，Guest 汇编需要 RISC-V 工具链。

当前仓库的 configure 要求 Python **3.12 或更高版本**。Ubuntu 22.04 默认 Python 3.10 不满足要求，单独安装 `python3-venv` 不会升级 Python；应先提供符合要求的解释器，再检查 configure 实际选择了哪一个。本次验证环境已有 Python 3.13.11，未替换系统 Python。

若使用 WSL，记录 WSL 版本及源码所在文件系统。构建很慢时，可评估将工作副本放到 Linux 文件系统；这属于性能优化，不是运行实验的硬性前提。

## 4. 第二次学习：只构建一个目标

从仓库根目录开始：

```bash
mkdir -p build-study
cd build-study
../configure --target-list=riscv64-softmmu --enable-debug
ninja -j2
./qemu-system-riscv64 --version
./qemu-system-riscv64 -machine help
./qemu-system-riscv64 -cpu help
cd ..
```

每步成功后再执行下一步。`-j2` 是降低内存压力的起点，可按资源调整；`--enable-debug` 用于源码调试。目录已有其他配置时先检查，不要覆盖未知实验产物。

观察三个结果：目标二进制存在；输出版本与当前源码相符；机器列表包含 `virt`。了解构建过程的职责分工：configure 检查环境并组织配置，Meson 描述构建图，Ninja 执行构建。进一步阅读 [构建系统](../../docs/devel/build-system.rst)。

## 5. 第三次学习：准备贯穿六阶段的程序

创建 `build-study/study-lab/`，在其中保存下面两个文件。它们是本地实验材料，不需要修改 QEMU 源码。

```bash
mkdir -p build-study/study-lab
```

保存为 `build-study/study-lab/program.S`：

```asm
    .option norvc
    .option norelax
    .section .text
    .globl _start, sum_loop, after_store, uart_write, done
_start:
    li t0, 0
    li t1, 1
    li t2, 6
sum_loop:
    add t0, t0, t1
    addi t1, t1, 1
    bne t1, t2, sum_loop
    la t3, result
    sw t0, 0(t3)
after_store:
    li t4, 0x10000000
    li t5, 3
    sb t5, 3(t4)
uart_wait:
    lbu t5, 5(t4)
    andi t5, t5, 0x20
    beqz t5, uart_wait
    li t5, 75
uart_write:
    sb t5, 0(t4)
done:
    j done

    .section .data
    .balign 4
    .globl result
result:
    .word 0
```

保存为 `build-study/study-lab/program.ld`：

```ld
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
    . = 0x80000000;
    .text : { *(.text*) }
    . = ALIGN(8);
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) *(COMMON) }
}
```

程序求 `1+2+3+4+5`，将 15 写入 `result`，再向 UART 输出 ASCII 75，即 `K`，最后停在循环中。`K` 没有换行，这是预期行为。

当前 virt 的 RAM 起始地址为 `0x80000000`，UART0 基址为 `0x10000000`，可在 [virt.c](../../hw/riscv/virt.c) 的 `virt_memmap` 中核对。这里固定地址只适用于本实验平台，其他板不能照搬。

本程序没有函数调用、栈和中断处理，目的是减小阅读范围。UART 的偏移 3 用于设置线路控制，偏移 5 的 bit 5 用于等待发送保持寄存器空，偏移 0 写出字符；第五阶段再深入实现。

## 6. 第四次学习：编译、检查和启动

在仓库根目录编译：

```bash
riscv64-linux-gnu-gcc -g -march=rv64im -mabi=lp64 \
  -nostdlib -nostartfiles -static -fno-pie -no-pie \
  -Wl,--build-id=none -Wl,--no-relax \
  -T build-study/study-lab/program.ld \
  -o build-study/study-lab/program.elf build-study/study-lab/program.S
riscv64-linux-gnu-readelf -h -l build-study/study-lab/program.elf
riscv64-linux-gnu-objdump -d build-study/study-lab/program.elf
```

虽然工具链名字含 Linux，这里通过不链接运行时和库生成裸机 ELF。检查架构为 RISC-V，入口为 `0x80000000`，可加载段位于已配置 RAM 范围。链接器可能提示该简单布局存在 RWX 段；本实验合并代码数据用于观察，不能将其当成生产固件布局。

文档编写时已将以上两个代码块提取到临时目录，用本机 `riscv64-linux-gnu-gcc` 成功编译，并通过 readelf、objdump 检查。所得入口为 `0x80000000`，求和循环位于 `0x8000000c`，`result` 位于 `0x80000048`。这些地址用于说明检查结果；修改程序后应重新反汇编，不硬编码旧地址。尚未运行下述 QEMU 与 GDB 实验。

启动命令：

```bash
./build-study/qemu-system-riscv64 \
  -machine virt -accel tcg,thread=single -smp 1 -m 128M \
  -bios none -display none -monitor none -serial stdio \
  -device loader,file=build-study/study-lab/program.elf,cpu-num=0
```

这里使用 [Generic Loader](../../docs/system/generic-loader.rst) 加载 ELF 并设置 CPU0 的 PC。`-bios none` 关闭默认固件；本实验直接从 ELF 入口执行，不研究固件跳转。输出 `K` 后用 Ctrl-C 结束宿主 QEMU；程序自身的无限循环不会自动退出。

| 参数 | 作用 |
| --- | --- |
| `-machine virt` | 选择平台模型 |
| `-accel tcg,thread=single` | 使用单线程 TCG |
| `-smp 1 -m 128M` | 一个 vCPU、128 MiB RAM |
| `-display none` | 不创建图形显示窗口 |
| `-monitor none -serial stdio` | 将标准输入输出留给串口 |
| `loader ... cpu-num=0` | 加载 ELF 并设置启动 PC |

Generic Loader 的入口语义也见 [官方说明](https://www.qemu.org/docs/master/system/generic-loader.html)。

## 7. 第五次学习：做两个小变化

1. 把字符 75 改成 65，重新编译并启动，预期输出 `A`；然后恢复基线。
2. 将 RAM 改为 256M，观察程序仍能运行，并说明程序为何不依赖这次扩容。

保存基线的源码、ELF、反汇编和完整启动命令。后续实验修改汇编前复制一份，避免调试符号与实际程序不一致。

扩展 Linux 实验需要匹配的内核、OpenSBI 和 initramfs。使用明确带 `/init` 的 RISC-V initramfs 时，可以参考如下模板；所有 `/path/to/` 都需要换成真实文件，不能直接执行：

```bash
./build-study/qemu-system-riscv64 \
  -machine virt -accel tcg,thread=single -smp 1 -m 512M \
  -bios default -display none -monitor none -serial stdio \
  -kernel /path/to/Image -initrd /path/to/rootfs.cpio.gz \
  -append 'console=ttyS0 rdinit=/init'
```

不要把裸机的 `-bios none` 与 Linux 的默认启动流程混用。磁盘根文件系统则需要额外驱动、块设备参数与正确的 `root=`。平台支持情况见 [官方 virt 文档](https://www.qemu.org/docs/master/system/riscv/virt.html)。

## 8. 排错与验收

| 症状 | 优先检查 |
| --- | --- |
| configure 失败 | 第一条依赖错误及构建日志，不反复盲目 ninja |
| ELF 无法加载 | 路径、RISC-V 架构、段地址是否落在 RAM |
| 没有输出 | 是否加载正确 ELF；下一章用 GDB 检查 PC |
| 输出后不退出 | 程序故意停在 done，不是启动失败 |
| 运行到默认固件 | 是否漏掉 `-bios none` 或使用了另一条命令 |

验收清单：

- [ ] 保存工具版本和 QEMU 源码提交号。
- [ ] 自己构建的 QEMU 能运行本章程序并输出 `K`。
- [ ] 能解释每个启动参数及 ELF 入口地址。
- [ ] 说明 Host 二进制与 Guest ELF 的区别。
- [ ] 保存一次修改字符前后的实验记录。

自测：为什么普通 Linux hello-world ELF 不能直接替换这个裸机 ELF？为什么输出 `K` 不能证明求和结果是 15？提示：运行环境不同；字符输出没有读取 `result`，需要下一阶段的内存检查。
