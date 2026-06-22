#!/usr/bin/env python3
"""PenguinLab example/mini 多架构内核模块编译 smoke。

发现 example/mini/*/Makefile,对给定 ARCH 编译(借 example/common/Makefile.arch 的
`make -C $(KDIR) M=$(CURDIR) modules`),校验每个 .ko 产物存在 + ELF 机器类型匹配架构。

用法:
    python3 scripts/build_examples.py <arch> [cross_compile_prefix]
    arch: arm64 / riscv / arm / x86_64
    cross_compile_prefix: 如 aarch64-linux-gnu-(留空则让 Makefile.arch 自选)

前置:内核树 out/build_latest_<arch> 必须已 modules_prepare(由 CI workflow 保证,
本地则要先编过内核或跑 modules_prepare)。

工程模式照 TAMCPP build_examples.py:发现 + 并行 + 失败聚合(error 行提取) + ::group::。
"""
import os
import sys
import subprocess
import pathlib
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXAMPLE_ROOT = ROOT / 'example' / 'mini'
CI = os.environ.get('GITHUB_ACTIONS') == 'true' or os.environ.get('CI') == 'true'

# ARCH → readelf -h 的 Machine 字段里应出现的关键字(小写匹配)。
# 用 readelf 不用 file:file 对 arm64 输出 "ARM aarch64",容易和大写 AArch64 匹配失败。
ELF_MACHINE = {
    'arm64': 'aarch64',
    'arm': 'arm',
    'riscv': 'risc-v',
    'x86_64': 'x86-64',
}


def discover():
    """发现 example/mini/<name>/Makefile(单层,排除 common)。"""
    if not EXAMPLE_ROOT.exists():
        return []
    return sorted(
        d for d in EXAMPLE_ROOT.iterdir()
        if d.is_dir() and (d / 'Makefile').exists()
    )


def run(cmd, env, timeout=300):
    if CI:
        print(f"::group::{' '.join(cmd)}")
    try:
        return subprocess.run(
            cmd, env=env, timeout=timeout,
            text=True, capture_output=True,
        )
    finally:
        if CI:
            print("::endgroup::")


def build_one(arch, cc, directory):
    name = directory.name
    env = os.environ.copy()
    env['ARCH'] = arch
    if cc:
        env['CROSS_COMPILE'] = cc

    # 先 clean(清掉上次的 .ko/.mod 等)
    run(['make', '-C', str(directory), 'clean'], env, timeout=60)

    # 编译:Makefile.arch 的 all 目标会 make -C $(KDIR) M=$(CURDIR) modules
    r = run(['make', '-C', str(directory)], env, timeout=300)
    if r.returncode != 0:
        errs = [
            l for l in (r.stderr + r.stdout).splitlines()
            if 'error:' in l.lower() or 'Error' in l
        ]
        tail = errs[:20] if errs else (r.stderr or r.stdout).splitlines()[-20:]
        return (name, False, 'make 失败\n    ' + '\n    '.join(tail))

    # 校验 .ko 产物
    kos = list(directory.glob('*.ko'))
    if not kos:
        return (name, False, '编译通过但无 .ko 产物')

    # 校验 ELF 机器类型匹配架构(readelf -h 的 Machine 字段)
    expected = ELF_MACHINE.get(arch)
    if expected:
        for ko in kos:
            rr = subprocess.run(['readelf', '-h', str(ko)], capture_output=True, text=True)
            machine = [l for l in rr.stdout.splitlines() if 'Machine:' in l]
            got = machine[0].lower() if machine else ''
            if expected not in got:
                return (name, False, f'{ko.name} 架构不匹配: {machine[0].strip() if machine else "无 Machine 字段"}')

    return (name, True, f'OK ({len(kos)} .ko)')


def main():
    if len(sys.argv) < 2:
        print('用法: build_examples.py <arch> [cross_compile_prefix]', file=sys.stderr)
        return 2
    arch = sys.argv[1]
    cc = sys.argv[2] if len(sys.argv) > 2 else ''

    dirs = discover()
    if not dirs:
        print('未发现 example/mini/*/Makefile(当前无示例可 smoke)')
        return 0

    print(f'ARCH={arch}  CROSS_COMPILE={cc or "(Makefile.arch 自选)"}')
    print(f'发现 {len(dirs)} 个示例: {[d.name for d in dirs]}')

    results = []
    workers = min(len(dirs), os.cpu_count() or 1)
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(build_one, arch, cc, d): d.name for d in dirs}
        for i, fut in enumerate(as_completed(futs), 1):
            name, ok, msg = fut.result()
            results.append((name, ok, msg))
            mark = '✓' if ok else '✗'
            print(f'[{i}/{len(dirs)}] {mark} {name} — {msg}')

    failed = [r for r in results if not r[1]]
    print(f'\nTotal {len(results)}, Passed {len(results) - len(failed)}, Failed {len(failed)}')
    for name, _, msg in failed:
        print(f'  FAILED: {name}: {msg}')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
