/**
 * @file penguin_example.c
 * @brief User-space test suite for penguin_list.h
 */

#include "penguin_list.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

/* ── Sample payload struct ─────────────────────────────────────────── */

typedef struct {
    int            value;
    penguin_list   node;
} int_node;

static int_node* make_node(int val) {
    int_node* n = malloc(sizeof(*n));
    assert(n);
    n->value = val;
    penguin_init_list_head(&n->node);
    return n;
}

/* ── Helpers ───────────────────────────────────────────────────────── */

static void assert_order(penguin_list* head, const int* expected, int count) {
    int_node* pos;
    int       i = 0;
    penguin_list_for_each_entry(pos, head, node) {
        assert(i < count);
        assert(pos->value == expected[i]);
        i++;
    }
    assert(i == count);
}

static void free_all(penguin_list* head) {
    int_node* pos;
    int_node* n;
    penguin_list_for_each_entry_safe(pos, n, head, node) {
        free(pos);
    }
}

/* ── Test cases ────────────────────────────────────────────────────── */

static void test_init_and_empty(void) {
    MAKE_PENGUIN_LIST(list);
    assert(penguin_list_empty(&list));
    assert(!penguin_list_only_one(&list));
    printf("  PASS: init & empty\n");
}

static void test_add_head(void) {
    MAKE_PENGUIN_LIST(list);

    int_node* a = make_node(1);
    int_node* b = make_node(2);
    int_node* c = make_node(3);

    penguin_list_add(&list, &a->node);
    penguin_list_add(&list, &b->node);
    penguin_list_add(&list, &c->node);

    /* Stack order: 3 -> 2 -> 1 */
    int expected[] = {3, 2, 1};
    assert_order(&list, expected, 3);

    free_all(&list);
    printf("  PASS: add_head\n");
}

static void test_add_tail(void) {
    MAKE_PENGUIN_LIST(list);

    int_node* a = make_node(1);
    int_node* b = make_node(2);
    int_node* c = make_node(3);

    penguin_list_add_tail(&list, &a->node);
    penguin_list_add_tail(&list, &b->node);
    penguin_list_add_tail(&list, &c->node);

    /* Queue order: 1 -> 2 -> 3 */
    int expected[] = {1, 2, 3};
    assert_order(&list, expected, 3);

    free_all(&list);
    printf("  PASS: add_tail\n");
}

static void test_singular(void) {
    MAKE_PENGUIN_LIST(list);
    assert(!penguin_list_only_one(&list));

    int_node* a = make_node(42);
    penguin_list_add(&list, &a->node);

    assert(!penguin_list_empty(&list));
    assert(penguin_list_only_one(&list));

    free_all(&list);
    printf("  PASS: singular\n");
}

static void test_first_last_entry(void) {
    MAKE_PENGUIN_LIST(list);

    int_node* a = make_node(10);
    int_node* b = make_node(20);

    penguin_list_add_tail(&list, &a->node);
    penguin_list_add_tail(&list, &b->node);

    int_node* first = penguin_list_first_entry(&list, int_node, node);
    int_node* last  = penguin_list_last_entry(&list, int_node, node);

    assert(first->value == 10);
    assert(last->value == 20);

    free_all(&list);
    printf("  PASS: first/last entry\n");
}

static void test_del(void) {
    MAKE_PENGUIN_LIST(list);

    int_node* a = make_node(1);
    int_node* b = make_node(2);
    int_node* c = make_node(3);

    penguin_list_add_tail(&list, &a->node);
    penguin_list_add_tail(&list, &b->node);
    penguin_list_add_tail(&list, &c->node);

    /* Remove middle node */
    penguin_list_del(&b->node);
    free(b);

    int expected[] = {1, 3};
    assert_order(&list, expected, 2);

    free_all(&list);
    printf("  PASS: del\n");
}

static void test_del_init(void) {
    MAKE_PENGUIN_LIST(list);
    int_node* a = make_node(5);
    penguin_list_add(&list, &a->node);

    penguin_list_del_init(&a->node);
    assert(penguin_list_empty(&a->node));
    assert(penguin_list_empty(&list));

    free(a);
    printf("  PASS: del_init\n");
}

static void test_for_each_prev(void) {
    MAKE_PENGUIN_LIST(list);

    int_node* a = make_node(1);
    int_node* b = make_node(2);
    int_node* c = make_node(3);

    penguin_list_add_tail(&list, &a->node);
    penguin_list_add_tail(&list, &b->node);
    penguin_list_add_tail(&list, &c->node);

    /* Reverse iteration: 3 -> 2 -> 1 */
    int        expected[] = {3, 2, 1};
    int_node*  pos;
    int        i = 0;
    penguin_list_for_each_entry(pos, &list, node) {
        /* Forward, just to cross-check */
    }
    /* Now use raw prev traversal on penguin_list pointers */
    penguin_node* p;
    penguin_list_for_each_prev(p, &list) {
        int_node* entry = penguin_list_entry(p, int_node, node);
        assert(entry->value == expected[i++]);
    }
    assert(i == 3);

    free_all(&list);
    printf("  PASS: for_each_prev\n");
}

static void test_safe_delete_in_loop(void) {
    MAKE_PENGUIN_LIST(list);

    for (int i = 0; i < 5; i++)
        penguin_list_add_tail(&list, &make_node(i)->node);

    /* Delete all even-valued nodes during traversal */
    int_node* pos;
    int_node* n;
    penguin_list_for_each_entry_safe(pos, n, &list, node) {
        if (pos->value % 2 == 0) {
            penguin_list_del(&pos->node);
            free(pos);
        }
    }

    /* Remaining: 1, 3 */
    int expected[] = {1, 3};
    assert_order(&list, expected, 2);

    free_all(&list);
    printf("  PASS: safe delete in loop\n");
}

static void test_splice(void) {
    MAKE_PENGUIN_LIST(list1);
    MAKE_PENGUIN_LIST(list2);

    penguin_list_add_tail(&list1, &make_node(1)->node);
    penguin_list_add_tail(&list1, &make_node(2)->node);

    penguin_list_add_tail(&list2, &make_node(3)->node);
    penguin_list_add_tail(&list2, &make_node(4)->node);

    penguin_list_splice(&list2, &list1);

    /* list1: 3 -> 4 -> 1 -> 2 (list2 inserted after head of list1) */
    int expected[] = {3, 4, 1, 2};
    assert_order(&list1, expected, 4);

    free_all(&list1);
    printf("  PASS: splice\n");
}

static void test_splice_init(void) {
    MAKE_PENGUIN_LIST(list1);
    MAKE_PENGUIN_LIST(list2);

    penguin_list_add_tail(&list1, &make_node(10)->node);

    penguin_list_add_tail(&list2, &make_node(20)->node);
    penguin_list_add_tail(&list2, &make_node(30)->node);

    penguin_list_splice_init(&list2, &list1);

    /* list2 inserted after head: 20 -> 30 -> 10 */
    int expected[] = {20, 30, 10};
    assert_order(&list1, expected, 3);
    assert(penguin_list_empty(&list2));

    free_all(&list1);
    printf("  PASS: splice_init\n");
}

static void test_splice_empty(void) {
    MAKE_PENGUIN_LIST(list1);
    MAKE_PENGUIN_LIST(list2);

    penguin_list_add_tail(&list1, &make_node(1)->node);

    /* Splicing an empty list should be a no-op */
    penguin_list_splice(&list2, &list1);

    int expected[] = {1};
    assert_order(&list1, expected, 1);

    free_all(&list1);
    printf("  PASS: splice empty\n");
}

/* ── Main ──────────────────────────────────────────────────────────── */

int main(int argc, char* argv[]) {
    (void)argc;
    (void)argv;

    printf("Running penguin_list tests...\n\n");

    test_init_and_empty();
    test_add_head();
    test_add_tail();
    test_singular();
    test_first_last_entry();
    test_del();
    test_del_init();
    test_for_each_prev();
    test_safe_delete_in_loop();
    test_splice();
    test_splice_init();
    test_splice_empty();

    printf("\nAll tests passed!\n");
    return 0;
}
