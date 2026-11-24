#include <stdlib.h>
#include "util/list.h"
#include "kernel/fs.h"
#include "fs/inode.h"
#include "debug.h"

lock_t inodes_lock = LOCK_INITIALIZER;
#define INODES_HASH_SIZE (1 << 10)
static struct list inodes_hash[INODES_HASH_SIZE];

int current_pid(void);

static struct inode_data *inode_get_data(struct mount *mount, ino_t ino) {
    int index = ino % INODES_HASH_SIZE;
    if (list_null(&inodes_hash[index]))
        list_init(&inodes_hash[index]);
    struct inode_data *inode;
    list_for_each_entry(&inodes_hash[index], inode, chain) {
        if (inode->mount == mount && inode->number == ino)
            return inode;
    }
    return NULL;
}

struct inode_data *inode_get_unlocked(struct mount *mount, ino_t ino) {
    struct inode_data *inode = inode_get_data(mount, ino);
    if (inode == NULL) {
        inode = malloc(sizeof(struct inode_data));
        if (inode == NULL)
            return NULL;
        inode->refcount = 0;
        inode->orphan_pending = false;
        inode->number = ino;
        mount_retain(mount);
        inode->mount = mount;
        inode->socket_id = 0;
        atomic_init(&inode->posix_lock_count, 0);
        cond_init(&inode->posix_unlock);
        list_init(&inode->posix_locks);
        list_init(&inode->chain);
        lock_init(&inode->lock);
        list_add(&inodes_hash[ino % INODES_HASH_SIZE], &inode->chain);
    }

    inode_retain(inode);
    return inode;
}

struct inode_data *inode_get(struct mount *mount, ino_t ino) {
    lock(&inodes_lock);
    struct inode_data *data = inode_get_unlocked(mount, ino);
    unlock(&inodes_lock);
    return data;
}

void inode_check_orphaned(struct mount *mount, ino_t ino) {
    if (ino == 0 || !mount->fs->inode_orphaned)
        return;
    bool call_orphaned = false;
    lock(&inodes_lock);
    struct inode_data *inode = inode_get_data(mount, ino);
    if (inode == NULL) {
        mount_retain(mount);
        call_orphaned = true;
    } else {
        inode->orphan_pending = true;
    }
    unlock(&inodes_lock);
    if (call_orphaned) {
        mount->fs->inode_orphaned(mount, ino);
        mount_release(mount);
    }
}

void inode_retain(struct inode_data *inode) {
    lock(&inode->lock);
    inode->refcount++;
    unlock(&inode->lock);
}

void inode_release(struct inode_data *inode) {
    lock(&inodes_lock);
    lock(&inode->lock);
    if (--inode->refcount == 0) {
        unlock(&inode->lock);
        list_remove(&inode->chain);
        bool call_orphaned = inode->orphan_pending && inode->mount->fs->inode_orphaned != NULL;
        struct mount *mount = inode->mount;
        ino_t number = inode->number;
        unlock(&inodes_lock);
        if (call_orphaned)
            mount->fs->inode_orphaned(mount, number);
        mount_release(mount);
        cond_destroy(&inode->posix_unlock);
        pthread_mutex_destroy(&inode->lock.m);
        free(inode);
    } else {
        unlock(&inode->lock);
        unlock(&inodes_lock);
    }
}
