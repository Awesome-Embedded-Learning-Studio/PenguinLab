/**
 * @file penguin_list.h
 * @author Charliechen114514 (chengh1922@mails.jlu.edu.cn)
 * @brief   Simplified user-space reimplementation of the Linux kernel's
 *          intrusive linked list (list_head). Designed for learning the
 *          container_of pattern and intrusive data structure design.
 * @version 0.1
 * @date 2026-04-08
 *
 * @copyright Copyright (c) 2026
 *
 */
#pragma once

#include <stddef.h>
#include <stdbool.h>

/**
 * @brief   Intrusive list node — embed this in your struct.
 * @note    Identical to kernel's struct list_head.
 */
typedef struct penguin_list penguin_list;

/**
 * @brief Node type alias for clarity.
 */
typedef penguin_list penguin_node;

struct penguin_list {
    penguin_node* prev;
    penguin_node* next;
};

#define INIT_PENGUIN_LIST(what_name) {.prev = &what_name, .next = &what_name}
#define MAKE_PENGUIN_LIST(what_name) penguin_list what_name = INIT_PENGUIN_LIST(what_name)

static inline void penguin_init_list_head(penguin_list* head) {
    head->prev = head;
    head->next = head;
}

/**
 * @brief Add a node after the head (stack / LIFO semantics).
 *
 * @param list
 * @param node
 */
static inline void penguin_list_add(penguin_list* list, penguin_node* node) {
    penguin_node* head = list;

    node->next = head->next;
    node->prev = head;

    head->next = node;
    node->next->prev = node;
}

static inline void penguin_list_add_tail(penguin_list* list, penguin_node* node) {
    penguin_node* head = list;

    node->next = head;
    node->prev = head->prev;

    head->prev->next = node;
    head->prev = node;
}

static inline void penguin_list_del(penguin_node* quit_one) {
    quit_one->prev->next = quit_one->next;
    quit_one->next->prev = quit_one->prev;
}

static inline void penguin_list_del_init(penguin_node* quit_one) {
    penguin_list_del(quit_one);
    quit_one->prev = quit_one;
    quit_one->next = quit_one;
}

static inline bool penguin_list_empty(penguin_list* list) {
    return list->next == list->prev && list->next == list;
}

static inline bool penguin_list_only_one(penguin_list* list) {
    return !penguin_list_empty(list) && list->next->next == list;
}

#ifndef PENGUIN_OFFSETOF
#    define PENGUIN_OFFSETOF(TYPE, MEMBER) ((size_t)&(((TYPE*)0)->MEMBER))
#endif

#ifndef PENGUIN_CONTAINER_OF
#    define PENGUIN_CONTAINER_OF(PTR, TYPE, MEMBER) \
        ((TYPE*)((char*)(PTR) - PENGUIN_OFFSETOF(TYPE, MEMBER)))
#endif

/* ── Entry access ─────────────────────────────────────────────────── */

#define penguin_list_entry(PTR, TYPE, MEMBER) PENGUIN_CONTAINER_OF(PTR, TYPE, MEMBER)

#define penguin_list_first_entry(HEAD, TYPE, MEMBER) penguin_list_entry((HEAD)->next, TYPE, MEMBER)

#define penguin_list_last_entry(HEAD, TYPE, MEMBER) penguin_list_entry((HEAD)->prev, TYPE, MEMBER)

/* ── Iteration ────────────────────────────────────────────────────── */

#define penguin_list_for_each(pos, head) for (pos = (head)->next; pos != (head); pos = pos->next)

#define penguin_list_for_each_prev(pos, head) \
    for (pos = (head)->prev; pos != (head); pos = pos->prev)

#define penguin_list_for_each_safe(pos, n, head) \
    for (pos = (head)->next, n = pos->next; pos != (head); pos = n, n = pos->next)

#define penguin_list_for_each_entry(pos, head, member)                                               \
    for (pos = penguin_list_entry((head)->next, __typeof__(*(pos)), member); &pos->member != (head); \
         pos = penguin_list_entry(pos->member.next, __typeof__(*(pos)), member))

#define penguin_list_for_each_entry_safe(pos, n, head, member)                \
    for (pos = penguin_list_entry((head)->next, __typeof__(*(pos)), member),  \
        n = penguin_list_entry(pos->member.next, __typeof__(*(pos)), member); \
         &pos->member != (head);                                              \
         pos = n, n = penguin_list_entry(n->member.next, __typeof__(*(n)), member))

/* ── Splice ───────────────────────────────────────────────────────── */

static inline void penguin_list_splice(penguin_list* list, penguin_list* head) {
    if (penguin_list_empty(list))
        return;

    penguin_node* first = list->next;
    penguin_node* last = list->prev;

    first->prev = head;
    last->next = head->next;
    head->next->prev = last;
    head->next = first;
}

static inline void penguin_list_splice_init(penguin_list* list, penguin_list* head) {
    penguin_list_splice(list, head);
    list->next = list;
    list->prev = list;
}
