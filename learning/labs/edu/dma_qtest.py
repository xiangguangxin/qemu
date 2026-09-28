#!/usr/bin/env python3
"""Personal local experiment: RISC-V virt EDU, no Guest CPU execution."""
import argparse
from pathlib import Path
import socket
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qemu', required=True, type=Path)
    args = parser.parse_args()
    qemu = args.qemu.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='qemu-edu-') as directory:
        sockpath = Path(directory) / 'qtest.sock'
        with tempfile.TemporaryFile(mode='w+b') as errors:
            proc = subprocess.Popen([
                str(qemu), '-machine', 'virt,aia=none', '-accel', 'qtest',
                '-m', '128M', '-smp', '1', '-bios', 'none',
                '-display', 'none', '-serial', 'none', '-monitor', 'none',
                '-device', 'edu,addr=1.0,dma_mask=0xffffffff',
                '-qtest', f'unix:{sockpath},server=on,wait=off',
                '-qtest-log', '/dev/null',
            ], stdout=subprocess.DEVNULL, stderr=errors)
            conn = socket.socket(socket.AF_UNIX)
            conn.settimeout(5)
            try:
                deadline = time.monotonic() + 10
                while True:
                    if proc.poll() is not None:
                        raise RuntimeError('QEMU exited during startup')
                    try:
                        conn.connect(str(sockpath))
                        break
                    except (FileNotFoundError, ConnectionRefusedError):
                        if time.monotonic() >= deadline:
                            raise TimeoutError('qtest socket startup timeout')
                        time.sleep(0.05)
                with conn.makefile('rwb', buffering=0) as stream:
                    def command(line):
                        stream.write((line + '\n').encode('ascii'))
                        reply = stream.readline().decode('ascii').strip()
                        if not (reply == 'OK' or reply.startswith('OK ')):
                            raise RuntimeError(f'{line}: {reply!r}')
                        print(f'{line} -> {reply}')
                        return reply.split()[1:]

                    def read(width, address):
                        return int(command(f'read{width} {address:#x}')[0], 0)

                    def write(width, address, value):
                        command(f'write{width} {address:#x} {value:#x}')

                    def expect(value, expected, label):
                        if value != expected:
                            raise AssertionError(f'{label}: {value:#x} != {expected:#x}')

                    # Bus 0, device 1, function 0: fixed by -device addr=1.0.
                    cfg, bar = 0x30008000, 0x40000000
                    expect(read('l', cfg), 0x11e81234, 'PCI vendor/device')
                    write('l', cfg + 0x10, bar)
                    write('w', cfg + 4, 6)  # Memory decode and bus mastering.
                    expect(read('l', cfg + 0x10) & ~15, bar, 'BAR0')
                    expect(read('w', cfg + 4) & 6, 6, 'PCI command')
                    write('l', bar + 4, 0x12345678)
                    expect(read('l', bar + 4), 0xedcba987, 'liveness')
                    write('l', bar + 0x60, 1)
                    expect(read('l', bar + 0x24), 1, 'IRQ status raised')
                    write('l', bar + 0x64, 1)
                    expect(read('l', bar + 0x24), 0, 'IRQ status cleared')
                    source, dest = 0x80010000, 0x80011000
                    words = [0x12345678, 0xa5a55a5a, 0, 0xffffffff]
                    for index, word in enumerate(words):
                        write('l', source + 4 * index, word)
                        write('l', dest + 4 * index, 0xcccccccc)

                    def transfer(src, dst, flags):
                        write('q', bar + 0x80, src)
                        write('q', bar + 0x88, dst)
                        write('q', bar + 0x90, 16)
                        write('q', bar + 0x98, flags)
                        expect(read('q', bar + 0x98) & 1, 1, 'DMA busy')
                        command('clock_step 100000000')
                        expect(read('q', bar + 0x98) & 1, 0, 'DMA complete')

                    transfer(source, 0x40000, 1)
                    expect(read('l', dest), 0xcccccccc, 'destination before output DMA')
                    transfer(0x40000, dest, 7)
                    for index, word in enumerate(words):
                        expect(read('l', dest + 4 * index), word, 'DMA data')
                    expect(read('l', bar + 0x24), 0x100, 'DMA IRQ status')
                    write('l', bar + 0x64, 0x100)
                    expect(read('l', bar + 0x24), 0, 'DMA IRQ acknowledgement')
                    print('PASS EDU: PCI, MMIO, two DMA directions, IRQ status')
            except Exception:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=5)
                errors.seek(0)
                print(errors.read().decode(errors='replace'))
                raise
            finally:
                conn.close()
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()


if __name__ == '__main__':
    main()
