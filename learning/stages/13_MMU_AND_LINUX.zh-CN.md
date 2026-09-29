# 进阶支线：Sv39、权限异常与 Linux 启动

[总路线](../QEMU_LEARNING_DESIGN.zh-CN.md) · [内存基础](04_MEMORY_AND_ADDRESS_SPACES.zh-CN.md) · [异常基础](07_TRAPS_INTERRUPTS_AND_TIMERS.zh-CN.md)

## 1. 范围

**实验目标：** 运行 Sv39 裸机实验，验证指定虚拟地址到物理地址的映射及只读页写入触发的 page fault；准备好 Linux 镜像后，再验证启动到 shell 和设备树与驱动的对应关系。

建议 5 次学习。阶段七之后可进入，与 SystemC 基础可独立安排。仅用于个人本地实验，状态见[验证记录](../VALIDATION.zh-CN.md)。

先用自包含的 Sv39 实验验证一次地址翻译和权限异常，再进入 Linux。无需把准备 Linux 镜像作为理解最小页表的唯一入口。

## 2. 第一次：理解受控页表实验

配套 [paging.S](../labs/interrupts/paging.S) 使用 M-mode 执行代码，以 `MPRV=1, MPP=S` 让数据访存使用 S-mode 翻译；没有切换到完整 S-mode 操作系统。设置 PMP 允许实验 RAM 访问，否则可能先触发物理保护错误。

Sv39 根表 index 1 建立一个 1 GiB 叶子映射：VA `0x40000000`→PA `0x80000000`。观察地址 VA `0x40010000` 应访问 PA `0x80010000`。初始 PTE 为 `0x200000c7`，包含 V/R/W/A/D；之后清 W，变为 `0x200000c3`，执行 sfence.vma，再尝试写入。

MPRV 的有效特权语义见 [Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)，Sv39 PTE 与权限检查见 [Supervisor-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)。

该映射按 1 GiB 对齐，未演示三个层级都访问的 4 KiB 页表遍历，也不演示 U-mode、ASID、多 hart TLB shootdown。不要把单个大页实验称为完整 MMU 验收。

## 3. 第二次：编译、运行和检查

```bash
mkdir -p build-study/study-lab/advanced
riscv64-linux-gnu-gcc -g -march=rv64im_zicsr -mabi=lp64 \
  -nostdlib -nostartfiles -static -fno-pie -no-pie \
  -Wl,--build-id=none -Wl,--no-relax \
  -T learning/labs/interrupts/link.ld \
  -o build-study/study-lab/advanced/paging.elf learning/labs/interrupts/paging.S
./build-study/qemu-system-riscv64 \
  -machine virt -accel tcg,thread=single -smp 1 -m 128M \
  -bios none -display none -monitor none -serial null \
  -device loader,file=build-study/study-lab/advanced/paging.elf,cpu-num=0 \
  -S -gdb tcp:127.0.0.1:1234
```

在另一个终端执行 `gdb-multiarch build-study/study-lab/advanced/paging.elf`：

```gdb
target remote 127.0.0.1:1234
break paging_done
break paging_unexpected
continue
x/gx &translated_value
x/gx &physical_after
x/gd &page_cause
x/gx &page_tval
x/gx &page_epc
p/x &faulting_store
```

预期停在 paging_done，前两个值均为 `0x12345678`，cause=15（store page fault）、tval=`0x40010000`，epc 对应 faulting_store。处理器只跳过这一条确定的 4 字节测试写指令，不能泛化到任意异常恢复。

若停在 paging_unexpected，先记录原因；不要修改预期值把 access fault 也当 page fault。程序使用的物理测试区从 RAM+64 KiB 开始，扩展 ELF 后必须检查其加载段不占用该区域。

## 4. 第三次：对照软件 TLB 与页表

在宿主 GDB 的独立一轮中观察 `riscv_cpu_tlb_fill`、`get_physical_address`（先搜索当前源码符号），记录有效特权、satp、VA、PTE 和所得 PA。

建立表：VPN[2]=1、VPN[1]=0、VPN[0]=16、页内偏移=0；因为根表已经命中大页，低 VPN 参与大页内偏移。把清 W 前后的路径对比，解释 sfence.vma 的目的。

不通过 GDB 内存查看次数推断 Guest TLB miss 次数。若要扩展 4 KiB 页，增加二级/三级表，并保留相同 VA/PA 与权限测试作为回归。

## 5. 第四次：准备 Linux 启动材料

Linux 支线需要自行准备匹配的 RISC-V Image、OpenSBI 与带 `/init` 的 initramfs。固定来源、版本、配置和 SHA256。阶段一的 `/path/to` 模板仍是模板，当前仓库不随教材分发可启动镜像。

可以从已验证的本机镜像开始，或构建一个内核与 BusyBox initramfs；构建时至少核对串口、initramfs、目标架构和根文件系统所需驱动。使用磁盘根文件系统时，还要有对应 VirtIO/块驱动与正确 root 参数。

启动后保存 `uname -a`、`cat /proc/cmdline`、`cat /proc/interrupts` 与完整串口日志。将 OpenSBI、内核早期启动、init、shell 分成四个检查点；只看到固件输出不算 Linux 启动完成。

## 6. 第五次：设备树与驱动衔接

启动一个独立实例，使用 `-machine virt,dumpdtb=build-study/study-lab/advanced/virt.dtb` 导出平台描述，再用本机 dtc 反编译：

```bash
dtc -I dtb -O dts -o build-study/study-lab/advanced/virt.dts \
  build-study/study-lab/advanced/virt.dtb
```

导出命令仍需搭配完整 QEMU 路径及所需平台参数。核对 UART 的 reg、interrupt-parent、interrupts、时钟与 compatible；设备树中的中断编码不直接等于 `/proc/interrupts` 左列的 Linux IRQ 编号。

未来接入代理设备时同时检查：板级实例、MMIO 映射、IRQ 接线、设备树、驱动匹配、ioremap 与 DMA API。用户虚拟地址不能直接作为 DMA 地址传给设备。

交付：Sv39 成功与权限失败证据、PTE 解码图；Linux 镜像清单与启动日志、设备树到驱动的对应关系。没有镜像时单列 Linux 未完成，不影响前面的自包含 Sv39 实验。
