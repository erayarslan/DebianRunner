#include <sched.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/stat.h>
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "fs/path.h"
#include "fs/real.h"

#define MAX_FILESYSTEMS 10
static const struct fs_ops *filesystems[MAX_FILESYSTEMS] = {
    &realfs,
    &procfs,
    &devptsfs,
    &tmpfs,
};

void fs_register(const struct fs_ops *fs) {
    for (unsigned i = 0; i < MAX_FILESYSTEMS; i++) {
        if (filesystems[i] == NULL) {
            filesystems[i] = fs;
            return;
        }
    }
    assert(!"reached filesystem limit");
}

// === MOUNT CACHE: Lock-free TLS snapshot + sharded reader grace period ===
// Mounts rarely change after boot (typically "/", "/proc", "/dev/pts").
// Each thread caches a complete snapshot of the mount table (root + non-root
// mounts in descending length order) validated against mounts_generation.
// Even generation = quiescent; odd = mount_remove() in progress.
// Sharded per-slot reader counters let mount_remove() drain any in-flight
// fast-path readers before checking mount->refcount and freeing struct mount,
// eliminating global mounts_lock contention on both mount_find and mount_release.
#define MOUNT_CACHE_MAX 16
#define MOUNT_READER_SLOTS 16

struct mount_reader_slot {
    _Atomic uint32_t count;
    char pad[64 - sizeof(_Atomic uint32_t)];
};
static struct mount_reader_slot mount_readers[MOUNT_READER_SLOTS];
static _Atomic uint32_t next_reader_slot = 0;
static __thread int tls_reader_slot = -1;

// Always even when quiescent, odd while mount_remove() is draining/freeing.
static _Atomic uint64_t mounts_generation = 2;

struct mount_cache_entry {
    struct mount *mount;
    size_t point_len;
    char point[64];
};
struct mount_tls_cache {
    uint64_t generation;
    struct mount *root_mount;
    unsigned non_root_count;
    bool complete;
    struct mount_cache_entry non_root[MOUNT_CACHE_MAX];
};
static __thread struct mount_tls_cache tls_mount_cache;

static inline int mount_reader_slot_index(void) {
    int slot = tls_reader_slot;
    if (unlikely(slot < 0)) {
        slot = (int) (atomic_fetch_add_explicit(&next_reader_slot, 1, memory_order_relaxed) % MOUNT_READER_SLOTS);
        tls_reader_slot = slot;
    }
    return slot;
}

struct mount *mount_find(char *path) {
    assert(path_is_normalized(path));

    // === FAST PATH: Lock-free TLS mount table snapshot (including root "/") ===
    int slot = mount_reader_slot_index();
    atomic_fetch_add_explicit(&mount_readers[slot].count, 1, memory_order_seq_cst);
    uint64_t gen = atomic_load_explicit(&mounts_generation, memory_order_seq_cst);
    if (__builtin_expect((gen & 1) == 0 && tls_mount_cache.generation == gen && tls_mount_cache.complete, 1)) {
        struct mount *found = tls_mount_cache.root_mount;
        if (path[0] == '/') {
            for (unsigned i = 0; i < tls_mount_cache.non_root_count; i++) {
                const struct mount_cache_entry *e = &tls_mount_cache.non_root[i];
                size_t n = e->point_len;
                if (path[1] == e->point[1] &&
                        strncmp(path, e->point, n) == 0 &&
                        (path[n] == '/' || path[n] == '\0')) {
                    found = e->mount;
                    break;
                }
            }
        }
        if (__builtin_expect(found != NULL, 1)) {
            __atomic_fetch_add(&found->refcount, 1, __ATOMIC_RELAXED);
            atomic_fetch_sub_explicit(&mount_readers[slot].count, 1, memory_order_release);
            return found;
        }
    }
    atomic_fetch_sub_explicit(&mount_readers[slot].count, 1, memory_order_release);

    // === SLOW PATH: Full mount table search + refresh TLS snapshot ===
    lock(&mounts_lock);
    struct mount *mount = NULL;
    assert(!list_empty(&mounts)); // this would mean there's no root FS mounted
    struct mount_tls_cache next_cache = {0};
    next_cache.complete = true;
    struct mount *iter;
    list_for_each_entry(&mounts, iter, mounts) {
        size_t n = strlen(iter->point);
        if (mount == NULL && strncmp(path, iter->point, n) == 0 && (path[n] == '/' || path[n] == '\0')) {
            mount = iter;
        }
        if (n == 0) {
            if (next_cache.root_mount == NULL)
                next_cache.root_mount = iter;
        } else if (next_cache.non_root_count < MOUNT_CACHE_MAX && n < sizeof(next_cache.non_root[0].point)) {
            struct mount_cache_entry *e = &next_cache.non_root[next_cache.non_root_count++];
            e->mount = iter;
            e->point_len = n;
            memcpy(e->point, iter->point, n + 1);
        } else {
            next_cache.complete = false;
        }
    }
    assert(mount != NULL);
    __atomic_fetch_add(&mount->refcount, 1, __ATOMIC_RELAXED);

    next_cache.generation = atomic_load_explicit(&mounts_generation, memory_order_relaxed);
    if (next_cache.complete && next_cache.root_mount != NULL)
        tls_mount_cache = next_cache;
    else
        tls_mount_cache.generation = 0;

    unlock(&mounts_lock);
    return mount;
}

void mount_retain(struct mount *mount) {
    __atomic_fetch_add(&mount->refcount, 1, __ATOMIC_RELAXED);
}

void mount_release(struct mount *mount) {
    __atomic_fetch_sub(&mount->refcount, 1, __ATOMIC_RELEASE);
}

int do_mount(const struct fs_ops *fs, const char *source, const char *point, const char *info, int flags) {
    struct mount *new_mount = malloc(sizeof(struct mount));
    if (new_mount == NULL)
        return _ENOMEM;
    new_mount->point = strdup(point);
    new_mount->source = strdup(source);
    new_mount->info = strdup(info);
    new_mount->flags = flags;
    new_mount->fs = fs;
    new_mount->data = NULL;
    new_mount->refcount = 0;
    static _Atomic uint64_t next_mount_id = 1;
    new_mount->id = atomic_fetch_add(&next_mount_id, 1);
    if (fs->mount) {
        int err = fs->mount(new_mount);
        if (err < 0) {
            free((void *) new_mount->info);
            free((void *) new_mount->point);
            free((void *) new_mount->source);
            free(new_mount);
            return err;
        }
    }

    // the list must stay in descending order of mount point length
    struct mount *mount;
    list_for_each_entry(&mounts, mount, mounts) {
        if (strlen(mount->point) <= strlen(new_mount->point))
            break;
    }
    list_add_before(&mount->mounts, &new_mount->mounts);

    // Advance by 2 to keep mounts_generation even and invalidate all TLS caches.
    atomic_fetch_add_explicit(&mounts_generation, 2, memory_order_release);

    return 0;
}

int mount_remove(struct mount *mount) {
    // Flip mounts_generation odd so new fast-path readers fall back to mounts_lock.
    uint64_t gen = atomic_load_explicit(&mounts_generation, memory_order_relaxed);
    atomic_store_explicit(&mounts_generation, gen + 1, memory_order_seq_cst);

    // Drain any in-flight fast-path readers that observed the previous generation.
    for (unsigned i = 0; i < MOUNT_READER_SLOTS; i++) {
        while (atomic_load_explicit(&mount_readers[i].count, memory_order_seq_cst) != 0)
            sched_yield();
    }

    if (__atomic_load_n(&mount->refcount, __ATOMIC_ACQUIRE) != 0) {
        atomic_store_explicit(&mounts_generation, gen + 2, memory_order_release);
        return _EBUSY;
    }

    if (mount->fs->umount)
        mount->fs->umount(mount);
    list_remove(&mount->mounts);
    free((void *) mount->info);
    free((void *) mount->source);
    free((void *) mount->point);
    free(mount);

    // Publish next quiescent even generation, invalidating all TLS caches.
    atomic_store_explicit(&mounts_generation, gen + 2, memory_order_release);

    return 0;
}

int do_umount(const char *point) {
    struct mount *mount;
    bool found = false;
    list_for_each_entry(&mounts, mount, mounts) {
        if (strcmp(point, mount->point) == 0) {
            found = true;
            break;
        }
    }
    if (!found)
        return _EINVAL;
    return mount_remove(mount);
}

// Parse a comma-separated mount option list for an exact flag token.
bool mount_param_flag(const char *info, const char *flag) {
    size_t flag_len = strlen(flag);
    while (*info != '\0') {
        size_t token_len = strcspn(info, ",");
        if (token_len == flag_len && strncmp(info, flag, flag_len) == 0)
            return true;
        info += token_len;
        if (*info == ',')
            info++;
    }
    return false;
}

#define MS_SUPPORTED (MS_READONLY_|MS_NOSUID_|MS_NODEV_|MS_NOEXEC_|MS_SILENT_)
#define MS_FLAGS (MS_READONLY_|MS_NOSUID_|MS_NODEV_|MS_NOEXEC_)

dword_t sys_mount(addr_t source_addr, addr_t point_addr, addr_t type_addr, dword_t flags, addr_t data_addr) {
    char source[MAX_PATH];
    if (user_read_string(source_addr, source, sizeof(source)))
        return _EFAULT;
    char point_raw[MAX_PATH];
    if (user_read_string(point_addr, point_raw, sizeof(point_raw)))
        return _EFAULT;
    char data[MAX_PATH];
    if (data_addr != 0) {
        if (user_read_string(data_addr, data, sizeof(data)))
            return _EFAULT;
    }
    char type[100];
    if (user_read_string(type_addr, type, sizeof(type)))
        return _EFAULT;
    STRACE("mount(\"%s\", \"%s\", \"%s\", %#x, \"%s\")", source, point_raw, type, flags, data_addr != 0 ? data : NULL);

    if (flags & ~MS_SUPPORTED) {
        FIXME("missing mount flags %#x", flags & ~MS_SUPPORTED);
        return _EINVAL;
    }

    const struct fs_ops *fs = NULL;
    for (size_t i = 0; i < sizeof(filesystems)/sizeof(filesystems[0]); i++) {
        if (filesystems[i] && (strcmp(filesystems[i]->name, type) == 0)) {
            fs = filesystems[i];
            break;
        }
    }
    if (fs == NULL)
        return _EINVAL;

    struct statbuf stat;
    int err = generic_statat(AT_PWD, point_raw, &stat, true);
    if (err < 0)
        return err;
    if (!S_ISDIR(stat.mode))
        return _ENOTDIR;

    char point[MAX_PATH];
    err = path_normalize(AT_PWD, point_raw, point, N_SYMLINK_FOLLOW);
    if (err < 0)
        return err;

    lock(&mounts_lock);
    err = do_mount(fs, source, point, data, flags & MS_FLAGS);
    unlock(&mounts_lock);
    return err;
}

#define UMOUNT_NOFOLLOW_ 8

dword_t sys_umount2(addr_t target_addr, dword_t flags) {
    char target_raw[MAX_PATH];
    if (user_read_string(target_addr, target_raw, sizeof(target_raw)))
        return _EFAULT;
    char target[MAX_PATH];
    int err = path_normalize(AT_PWD, target_raw, target,
            flags & UMOUNT_NOFOLLOW_ ? N_SYMLINK_NOFOLLOW : N_SYMLINK_FOLLOW);
    if (err < 0)
        return err;

    lock(&mounts_lock);
    err = do_umount(target);
    unlock(&mounts_lock);
    return err;
}

struct list mounts = {&mounts, &mounts};
lock_t mounts_lock = LOCK_INITIALIZER;
