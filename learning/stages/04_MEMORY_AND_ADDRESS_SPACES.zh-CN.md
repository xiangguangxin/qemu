# 阶段四：地址空间、RAM 与 MMIO

[返回总路线](../QEMU_LEARNING_DESIGN.zh-CN.md) · [上一阶段](03_TCG_AND_INSTRUCTIONS.zh-CN.md) · [下一阶段](05_DEVICES_AND_INTERRUPTS.zh-CN.md)

## 1. 目标与准备

**本阶段目标：**用 Guest GDB 观察一次 RAM 写入，用 Host GDB 观察 UART 的 MMIO 回调，并能说明 GVA、GPA、HVA、HPA、AddressSpace、MemoryRegion 和软件 TLB 的关系。

准备第一阶段的 `program.S`、`program.ld`、`program.elf` 和带调试信息的 QEMU。以下命令均从仓库根目录运行。本文是个人本地实验；最小裸机程序没有建立页表，因此本章观察的是直连的物理地址访问。分页场景另见[支线十三](13_MMU_AND_LINUX.zh-CN.md)。

先确认文件和基线值：

```bash
grep -n -E 'sw t0|0x10000000|sb t5|li t5, 75' build-study/study-lab/program.S
```

`li t5, 75` 对应输出 `K`。如果刚改过源文件，重新生成 ELF；编译 QEMU 的 `ninja` 不会自动重新编译这个独立汇编程序：

```bash
riscv64-linux-gnu-gcc -g -march=rv64im -mabi=lp64 \
  -nostdlib -nostartfiles -static -fno-pie -no-pie \
  -Wl,--build-id=none -Wl,--no-relax \
  -T build-study/study-lab/program.ld \
  -o build-study/study-lab/program.elf \
  build-study/study-lab/program.S
```

确认 ELF 入口及关键指令：

```bash
riscv64-linux-gnu-readelf -h build-study/study-lab/program.elf
riscv64-linux-gnu-objdump -d build-study/study-lab/program.elf
```

每次实验开始前先结束旧 QEMU，避免旧进程占用 GDB 端口或让你误读上一轮的串口日志。

## 2. 术语和地址流向

| 术语 | 英文全称 | 本章里的意思 |
| --- | --- | --- |
| GVA | Guest Virtual Address | Guest 软件或指令使用的虚拟地址；只有当前架构状态启用地址转换时，才经 Guest 页表转换。 |
| GPA | Guest Physical Address | Guest 物理地址。虚拟机平台把 RAM、UART 等区域映射在这个地址空间。 |
| HVA | Host Virtual Address | 宿主进程中的虚拟地址。TCG 访问 QEMU RAM backing 时可通过 HVA 读写它。 |
| HPA | Host Physical Address | 宿主硬件的物理地址，由宿主内核和硬件虚拟化机制管理；它不是 QEMU 回调里普通的 C 指针。 |
| MMIO | Memory-Mapped Input/Output | 内存映射 I/O。设备寄存器占用 GPA 地址范围，Guest 对这些地址的读写会被设备模型处理。 |
| AddressSpace | 地址空间视图 | QEMU 从 CPU 或设备的视角看到的 GPA 映射。访问在此视图中被路由到 RAM、MMIO 或其他区域。 |
| MemoryRegion | 内存区域 | QEMU 对一段 RAM、MMIO、ROM、容器或别名区域的描述。MMIO 区域可注册读写回调。 |
| TLB | Translation Lookaside Buffer | 地址转换缓存。命中时复用近期的转换与访问属性，减少再次查转换结构的开销。 |
| 软件 TLB | Software TLB | QEMU TCG 维护的软件缓存，记录 Guest 地址到可访问内存或设备访问路径的映射信息；不是 Guest RAM，也不是宿主 CPU 的硬件 TLB。 |
| 区域内偏移 | region-relative offset | MMIO 回调收到的地址通常相对于设备区域起点。例如 UART GPA `0x10000003` 对应偏移 `3`。 |

地址处理要分层理解：

```text
Guest load/store 使用的地址
  │
  ├─ Guest 当前模式启用了地址转换：Guest 页表和权限检查将 GVA 转成 GPA
  └─ 未启用地址转换：按当前架构规则直接使用/形成 GPA
       │
       └─ QEMU 的 Guest 物理 AddressSpace 按 GPA 查映射
            ├─ RAM：访问 RAM backing
            └─ MMIO：调用设备 MemoryRegionOps 回调
```

本练习的程序从 M-mode 裸机运行，没有设置页表，也没有启用 `MPRV` 等改变数据访存特权级的机制，所以这里把汇编里的地址按 GPA 观察。不要把此结论推广到启用分页的 Linux Guest。

本例中 `0x80000000` 是 `virt` 板上 RAM 的起始 GPA；它不是 QEMU 进程地址空间里的指针。Guest GPA 到 QEMU 的 RAM backing（TCG 下可访问的 HVA）是 QEMU/TCG 的映射和访问路径；HPA 则是宿主物理内存层面的地址，二者不能混称。

### TCG 与 KVM 地址转换的区别

- **TCG：**QEMU 用软件模拟 Guest 的地址转换和权限检查，并维护软件 TLB。命中时 RAM 读写通常走快速路径；MMIO 访问走设备模拟路径。这个过程不使用 EPT/NPT。
- **KVM：**Guest 页表仍负责 GVA→GPA（当 Guest 分页启用时）。在支持二阶段转换的主机上，硬件可用 Intel EPT 或 AMD NPT 完成 GPA→HPA。KVM 将 Guest RAM 区域与 QEMU 提供的 backing 关联起来；RAM 访问可由硬件直接执行，MMIO 访问通常退出到 KVM/QEMU 进行模拟。

**记忆要点：**GVA→GPA 是 Guest 自己的地址转换；GPA→RAM/MMIO 是虚拟机平台的地址映射；KVM 下的 GPA→HPA 是硬件二阶段转换。它们属于不同层次。

## 3. 步骤一：检查 virt 板的 RAM 与 UART 映射

### 3.1 查看源码中的映射

在仓库根目录搜索板级映射和 UART 注册位置：

```bash
grep -n -E 'VIRT_UART0|VIRT_DRAM' hw/riscv/virt.c
grep -n -A4 -B2 'serial_mm_init' hw/riscv/virt.c
grep -n -A20 -B3 'serial_mm_write' hw/char/serial-mm.c
```

当前 `virt` 板把 UART0 映射在 `0x10000000`，RAM 从 `0x80000000` 开始；具体 RAM 长度由 `-m` 等机器配置决定。`serial_mm_write` 的参数包括区域内地址 `addr`、写入值 `value` 和访问宽度 `size`。

### 3.2 用 QEMU Monitor 查看运行时映射

启动一轮 QEMU，把 Monitor 接到终端、把 Guest 串口输出写入文件：

```bash
./build-study/qemu-system-riscv64 \
  -machine virt -accel tcg,thread=single -smp 1 -m 128M \
  -bios none -display none -monitor stdio \
  -serial file:build-study/study-lab/memory-uart.log \
  -device loader,file=build-study/study-lab/program.elf,cpu-num=0
```

出现 `(qemu)` 提示符后输入：

```text
info mtree
```

在输出中找到 `system` 地址空间里的 RAM 与 UART 区域，记录基址和范围。Monitor 命令是在 `(qemu)` 提示符下执行的，不是在 Bash 里执行。查看完输入 `quit` 结束 QEMU。区域名称和输出格式会随版本变化，重点核对地址范围。

## 4. 步骤二：观察普通 RAM 写入

本程序执行 `sw t0, 0(t3)`，把 `t0` 的 32 位结果写到 `result`。`after_store` 标签在这条 store 之后，因此断在此处时写入已经发生。

### 4.1 暂停 Guest 并开放 GDB 连接

终端 A 从仓库根目录启动：

```bash
./build-study/qemu-system-riscv64 \
  -machine virt -accel tcg,thread=single -smp 1 -m 128M \
  -bios none -display none -monitor none \
  -serial file:build-study/study-lab/ram-uart.log \
  -device loader,file=build-study/study-lab/program.elf,cpu-num=0 \
  -S -gdb tcp:127.0.0.1:1234
```

`-S` 让 Guest CPU 启动后先暂停；`-gdb` 开放本机 TCP 调试端口。终端 A 保持运行。

### 4.2 用 Guest GDB 检查结果

终端 B 运行：

```bash
gdb-multiarch build-study/study-lab/program.elf
```

在 Guest GDB 中输入：

```gdb
set pagination off
target remote 127.0.0.1:1234
break after_store
continue
info registers t0 t3
p/x &result
x/4bx $t3
x/wx $t3
```

预期 `t0=15`、`t3=0x80000048`；`x/4bx` 显示小端字节 `0f 00 00 00`，`x/wx` 显示 32 位值 `0x0000000f`。这证明 Guest 程序已把 15 写到 `result`。它观察的是 Guest 地址和 Guest 内存；不能据此把 `$t3` 当成宿主 HVA。

### 4.3 可选：改变数据验证写入来源

把 `program.S` 中累加器初值从 `li t0, 0` 改为 `li t0, 1`，重新编译 ELF，再重复本节。预期 `result=16`，字节为 `10 00 00 00`。结束后恢复源码基线并重新编译。

## 5. 步骤三：观察 UART MMIO 写入

UART 在本例中是 MMIO 设备，不是普通 RAM。Guest 写 GPA `0x10000003` 设置线路控制寄存器；写 GPA `0x10000000` 则向发送数据寄存器写入字符。设备回调收到相对设备区域的偏移。

### 5.1 用 Guest GDB 看 store 执行前后的寄存器

可以沿用上一节启动的 QEMU/GDB 会话。在 Guest GDB 中，先从 `after_store` 继续，到 UART 输出指令前停住：

```gdb
break uart_write
continue
info registers t4 t5 pc
x/i $pc
```

预期 `t4=0x10000000`、`t5=75`，当前指令是 `sb t5,0(t4)`。此时 store 尚未执行。输入：

```gdb
si
```

Guest 执行这条 store 后，UART 后端应收到 ASCII `K`。本次 QEMU 使用 `-serial file:...`，所以字符写入 `build-study/study-lab/ram-uart.log`。之后程序会进入 `done` 无限循环。查看完毕后在终端 A 按 `Ctrl+C` 停止 QEMU。

### 5.2 用 Host GDB 检查设备回调参数

重新启动一轮独立实验。Host GDB 调试的是 QEMU 进程，不是 Guest CPU：

```bash
gdb --args ./build-study/qemu-system-riscv64 \
  -machine virt -accel tcg,thread=single -smp 1 -m 128M \
  -bios none -display none -monitor none \
  -serial file:build-study/study-lab/host-uart.log \
  -device loader,file=build-study/study-lab/program.elf,cpu-num=0
```

在 Host GDB 中输入：

```gdb
set pagination off
break serial_mm_write
run
info args
p/x addr
p/x value
p size
bt
continue
info args
p/x addr
p/x value
p size
bt
```

第一次命中通常是程序写线路控制寄存器：`addr=3`、`value=3`、`size=1`。继续运行后，字符写入通常再次命中：`addr=0`、`value=75`（`0x4b`，ASCII `K`）、`size=1`。`addr` 是 UART 区域内偏移；完整 Guest GPA 等于 UART 基址 `0x10000000` 加上 `addr`。

如果 `info args` 无法显示参数，确认当前运行的是带调试信息的 QEMU，或在 `serial_mm_write` 的源码行设断点。`bt` 用于查看调用路径；具体中间函数会随版本和优化变化。结束时输入 `quit`，必要时确认终止被调试的 QEMU。

## 6. 步骤四：理解软件 TLB 与 RAM/MMIO 快慢路径

### 6.1 术语解释

- **TLB 命中：**缓存中已有这次访存所需的翻译与权限信息，可以直接使用缓存结果。
- **TLB 未命中：**缓存里没有可用条目，QEMU 需要执行填充路径，进行地址翻译/权限检查并建立缓存条目；失败时转为 Guest 架构异常。
- **RAM 快速路径：**TCG 软件 TLB 命中后，普通 RAM 访问可直接读写 RAM backing，不必每条指令都走通用 `AddressSpace` 派发。
- **MMIO 路径：**访问命中设备区域时，QEMU 调用设备注册的 `MemoryRegionOps`。设备回调按偏移、值和宽度解释寄存器操作。
- **RAM backing：**实际保存 Guest RAM 内容的宿主内存映射。它在 QEMU 中有 HVA，但这不代表该 HVA 是 Guest 可见地址。

不要预期每次 Guest RAM store 都会命中 `address_space_rw()` 或 `memory_region_dispatch_write()`；TCG 软件 TLB 快速路径可能绕过这些慢路径。GDB 的 `x` 命令是调试器读取内存，也不能当成 Guest load/store 执行路径证据。

### 6.2 阅读并可选地断在 TLB 填充入口

先定位本版本实现：

```bash
grep -n -E 'riscv_cpu_tlb_fill|get_physical_address' target/riscv/tcg/cpu_helper.c
grep -n -E 'memory_region_dispatch_write|address_space_translate' system/memory.c
grep -n -E 'tlb_fill|io_read|io_write' accel/tcg/cputlb.c
```

如果想在 Host GDB 观察数据地址对应的填充过程，使用新的 GDB 会话启动 QEMU，并设置条件断点：

```gdb
break riscv_cpu_tlb_fill if address == 0x80000048
run
info args
bt
```

断点可能因编译优化或符号信息而无法命中；地址转换结果也可能已缓存。不能命中时先读函数和调用路径，不要据此断定 Guest 没有访问该地址。`get_physical_address` 负责地址翻译/权限检查，但本章裸机 M-mode 样例不走普通页表遍历；要实际观察 Sv39 页表遍历，使用[支线十三](13_MMU_AND_LINUX.zh-CN.md)的受控实验。

## 7. 交付、排错与验收

记录一张小表，区分 Guest 侧和 Host 侧观测：

| 访问 | Guest GPA | Guest 写入 | Host 侧观察 |
| --- | --- | --- | --- |
| `sw t0,0(t3)` | `0x80000048` | 32 位 `15`，字节 `0f 00 00 00` | RAM backing；TCG 快速路径未必进入通用写回调 |
| `sb t5,3(t4)` | `0x10000003` | 1 字节 `3` | UART 回调偏移 `3`，值 `3` |
| `sb t5,0(t4)` | `0x10000000` | 1 字节 `75` / `0x4b` | UART 回调偏移 `0`，值 `75`，串口输出 `K` |

- [ ] 能说明 GVA→GPA 与 GPA→RAM/MMIO 是不同层次。
- [ ] 能解释 HVA 与 HPA 的区别，以及 TCG 与 KVM/EPT/NPT 的不同。
- [ ] 能用 Guest GDB 证明 RAM 写入结果和字节序。
- [ ] 能用 Host GDB 证明 UART 回调收到的是区域偏移、值和访问宽度。
- [ ] 知道 GDB 内存查看不能证明 Guest TLB 或访存慢路径被执行。

常见情况：UART 回调参数只有 `0` 或 `3`，因为它收到区域内偏移；RAM 写断点不命中，可能因为选择了慢路径而实际访问走了 TCG 快速路径；宿主 GDB 不能用 `0x80000048` 直接读取 Guest RAM，因为 GPA 不是 HVA。

自测：设备 DMA 通常使用设备地址空间中的地址，可能再经 IOMMU 转换；为什么不能把 Guest 用户虚拟地址或 QEMU HVA 直接当成 DMA 地址？
