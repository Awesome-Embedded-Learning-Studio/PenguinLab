# 04-mmap — 把一页内核 RAM 映射进用户进程

> 配套教程：[mmap：把设备内存搬进用户进程](../../../document/tutorials/drivers/04-drv-mmap.md)
> 对应进度节点：`drv-mmap`（layer-2）
> 前置示例：[01-chardev_basic](../01-chardev_basic/)

## 这个示例做什么

`read`/`write` 是逐字节搬运；`mmap` 直接把内核内存搬进用户地址空间，用户拿普通指针读写，MMU 直奔物理页，内核不插手。本篇演示把**一页内核 RAM**映射出去：

- `init` 里 `alloc_page` 一页，填上魔数（`0xDEADBEEF` 起递增）
- `.mmap` 用 **`vm_insert_page`** 把这页映射出去（RAM 页的现代做法，吃 `struct page`，不用手算 pfn）
- 用户读魔数（映射建立）→ 写新值 → `release` 时内核读回（共享映射，写直达物理页）→ 验证双向连通
- 注释里给出等价的 `remap_pfn_range(... page_to_pfn(page) ...)` 传统写法

## 文件

| 文件 | 说明 |
|------|------|
| `mmap.c` | 内核模块：`alloc_page` + `.mmap`（vm_insert_page）+ `.release`（读回验证） |
| `mmap_user.c` | 用户态：`mmap` 后读魔数 + 写新值，`close` 触发内核读回 |
| `Makefile` | `make` 出模块，`make user` 出用户态程序 |

## 编译

```bash
cd example/mini/04-mmap
make             # mmap.ko（默认 arm64）
make user        # mmap_user（静态链接）
```

## 亲测（QEMU ARM64，2026-06-27 实测）

```bash
insmod mmap.ko
./mmap_user
dmesg | tail

# 进阶: 看 VMA 标志(remap_pfn_range 路径会打 VM_IO|VM_PFNMAP)
# cat /proc/$(pidof mmap_user)/smaps | grep -A1 llkd_mmapdev
rmmod mmap
```

实测输出（2026-06-27）：

```
# ./mmap_user
kernel magic: page[0]=0xdeadbeef page[1]=0xdeadbef0
OK: mapping established, kernel magic visible
user wrote:   page[0]=0xcafebabe page[1]=0x12345678

# dmesg
[  XX.XXXXXX] llkd_mmapdev: release, page[0]=0xcafebabe page[1]=0x12345678 (did user write?)
```

> 内核 `release` 时读回了用户写的新值 → 共享映射双向连通验证通过。
> 踩坑预警（教程已点）：若改映射设备寄存器，务必在 `remap_pfn_range` **之前** `pgprot_noncached(vma->vm_page_prot)`，否则缓存会让写入"消失"。
