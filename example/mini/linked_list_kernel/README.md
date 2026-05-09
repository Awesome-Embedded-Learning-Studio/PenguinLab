# linked_list_kernel — 内核侵入式链表（用户态实现）

用户态重新实现 Linux 内核的 `list_head` 侵入式链表，学习 `container_of` 模式。

## 构建

```bash
cd example/mini/linked_list_kernel
mkdir -p build && cd build
cmake ..
make
./penguin_example
```

## 测试覆盖

12 个测试用例：init & empty, add_head, add_tail, singular, first/last entry, del, del_init, for_each_prev, safe delete in loop, splice, splice_init, splice empty.
