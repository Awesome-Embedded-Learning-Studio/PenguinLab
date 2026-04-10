# kernel_base_ds — 内核核心数据结构（用户态实现）

对应教程：`tutorial/03_内核核心数据结构.md`

## 说明

用户态重新实现 Linux 内核的侵入式链表（`list_head`），用于学习 `container_of` 模式和侵入式数据结构设计。所有 API 使用 `penguin_` 前缀，实现原理与内核完全一致。

## 包含的文件

| 文件 | 说明 |
|------|------|
| `penguin_list.h` | 侵入式链表完整实现：add、del、splice、迭代宏、`container_of` |
| `penguin_example.c` | 12 个测试用例，覆盖所有链表操作 |
| `CMakeLists.txt` | CMake 构建配置 |

## 构建与运行

```bash
cd example/kernel_base_ds
mkdir -p build && cd build
cmake ..
make
./penguin_example
```

预期输出：所有 12 个测试 PASS。

## 测试覆盖

| 测试 | 验证内容 |
|------|----------|
| `test_init_and_empty` | 链表初始化、判空 |
| `test_add_head` | 头插法（栈语义 LIFO） |
| `test_add_tail` | 尾插法（队列语义 FIFO） |
| `test_singular` | 单节点判断 |
| `test_first_last_entry` | first_entry / last_entry |
| `test_del` | 中间节点删除 |
| `test_del_init` | 删除并重新初始化 |
| `test_for_each_prev` | 反向遍历 |
| `test_safe_delete_in_loop` | 遍历时安全删除节点 |
| `test_splice` | 链表合并 |
| `test_splice_init` | 合并并重新初始化源链表 |
| `test_splice_empty` | 合并空链表（边界条件） |

## 对照内核源码

```bash
# 对比简化版与内核版链表实现
diff <(grep -E "static inline|define" penguin_list.h | head -30) \
     <(grep -E "static inline|define" ../../third_party/linux/include/linux/list.h | head -30)
```

主要差异：内核版使用 `WRITE_ONCE`/`READ_ONCE` 做内存屏障，`__builtin_types_compatible_p` 做类型检查。
