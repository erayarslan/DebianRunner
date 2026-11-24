#ifndef GUEST_PAGE_POOL_H
#define GUEST_PAGE_POOL_H
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

// Keep small guest pages in full host pages. Partially-used slabs live on
// guest_page_available; up to GUEST_PAGE_EMPTY_SLAB_CACHE_MAX completely empty
// slabs are retained on guest_page_empty so freeing the last slot in a 16 KiB
// host page doesn't churn host munmap/mmap. Host mmap/munmap run outside the
// pool lock.
#define GUEST_PAGE_EMPTY_SLAB_CACHE_MAX 32

struct guest_page_slab {
    void *base;
    size_t bytes, slot_bytes;
    uint64_t available, all, dirty;
    struct guest_page_slab *next, *previous;
};
static pthread_mutex_t guest_page_lock = PTHREAD_MUTEX_INITIALIZER;
static struct guest_page_slab *guest_page_available;
static struct guest_page_slab *guest_page_empty;
static unsigned guest_page_empty_count;

static void guest_page_unlink(struct guest_page_slab **head, struct guest_page_slab *slab) {
    if (slab->previous) slab->previous->next = slab->next;
    else *head = slab->next;
    if (slab->next) slab->next->previous = slab->previous;
    slab->next = slab->previous = NULL;
}
static void guest_page_link(struct guest_page_slab **head, struct guest_page_slab *slab) {
    slab->next = *head;
    slab->previous = NULL;
    if (slab->next) slab->next->previous = slab;
    *head = slab;
}
static void *guest_page_allocate_opts(size_t host_bytes, size_t guest_bytes,
        struct guest_page_slab **owner, bool zero_fill) {
    *owner = NULL;
    if (host_bytes <= guest_bytes)
        return mmap(NULL, guest_bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    size_t slots = host_bytes / guest_bytes;
    if (host_bytes % guest_bytes || slots > 64) { errno = EINVAL; return MAP_FAILED; }

    pthread_mutex_lock(&guest_page_lock);
    struct guest_page_slab *slab = guest_page_available;
    while (slab && (slab->bytes != host_bytes || slab->slot_bytes != guest_bytes))
        slab = slab->next;
    bool from_empty = false;
    if (!slab) {
        slab = guest_page_empty;
        while (slab && (slab->bytes != host_bytes || slab->slot_bytes != guest_bytes))
            slab = slab->next;
        if (slab) {
            guest_page_unlink(&guest_page_empty, slab);
            guest_page_empty_count--;
            from_empty = true;
        }
    }
    if (slab) {
        unsigned slot = (unsigned)__builtin_ctzll(slab->available);
        uint64_t bit = UINT64_C(1) << slot;
        bool was_dirty = (slab->dirty & bit) != 0;
        slab->available &= ~bit;
        slab->dirty |= bit;
        if (from_empty) {
            if (slab->available)
                guest_page_link(&guest_page_available, slab);
        } else if (!slab->available) {
            guest_page_unlink(&guest_page_available, slab);
        }
        pthread_mutex_unlock(&guest_page_lock);
        *owner = slab;
        void *page = (char *)slab->base + slot * guest_bytes;
        if (zero_fill && was_dirty)
            memset(page, 0, guest_bytes);
        return page;
    }
    pthread_mutex_unlock(&guest_page_lock);

    // No cached slab available: allocate a new host page outside guest_page_lock.
    struct guest_page_slab *new_slab = calloc(1, sizeof(*new_slab));
    if (!new_slab) return MAP_FAILED;
    void *base = mmap(NULL, host_bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) { free(new_slab); return MAP_FAILED; }
    new_slab->base = base;
    new_slab->bytes = host_bytes;
    new_slab->slot_bytes = guest_bytes;
    new_slab->all = slots == 64 ? UINT64_MAX : (UINT64_C(1) << slots) - 1;
    // Claim slot 0 for the caller; freshly mmap'd pages are already zeroed.
    new_slab->available = new_slab->all & ~UINT64_C(1);
    new_slab->dirty = UINT64_C(1);

    if (new_slab->available) {
        pthread_mutex_lock(&guest_page_lock);
        guest_page_link(&guest_page_available, new_slab);
        pthread_mutex_unlock(&guest_page_lock);
    }
    *owner = new_slab;
    return base;
}
static void *guest_page_allocate(size_t host_bytes, size_t guest_bytes, struct guest_page_slab **owner) {
    return guest_page_allocate_opts(host_bytes, guest_bytes, owner, true);
}
static void guest_page_release(struct guest_page_slab *slab, void *page, size_t bytes) {
    if (!slab) { munmap(page, bytes); return; }
    unsigned slot = (unsigned)(((char *)page - (char *)slab->base) / slab->slot_bytes);
    void *unmap_base = NULL;
    size_t unmap_bytes = 0;
    struct guest_page_slab *free_slab = NULL;

    pthread_mutex_lock(&guest_page_lock);
    bool was_full = (slab->available == 0);
    slab->available |= UINT64_C(1) << slot;
    if (slab->available == slab->all) {
        if (!was_full)
            guest_page_unlink(&guest_page_available, slab);
        if (guest_page_empty_count < GUEST_PAGE_EMPTY_SLAB_CACHE_MAX) {
            guest_page_link(&guest_page_empty, slab);
            guest_page_empty_count++;
        } else {
            unmap_base = slab->base;
            unmap_bytes = slab->bytes;
            free_slab = slab;
        }
    } else if (was_full) {
        guest_page_link(&guest_page_available, slab);
    }
    pthread_mutex_unlock(&guest_page_lock);

    if (free_slab) {
        munmap(unmap_base, unmap_bytes);
        free(free_slab);
    }
}
#endif
