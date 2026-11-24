#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/socket.h>
#include "fs/sockrestart.h"
#include "fs/fd.h"
#include "fs/sock.h"
#include "kernel/task.h"
#include "util/list.h"
extern const struct fd_ops socket_fdops;

static lock_t sockrestart_lock = LOCK_INITIALIZER;
static struct list listen_fds = LIST_INITIALIZER(listen_fds);

struct saved_socket {
    struct fd *sock;
    int type;
    int proto;
    union {
        char name[128];
        struct sockaddr name_addr;
    };
    socklen_t name_len;
    struct list saved;
};

static struct list saved_sockets = LIST_INITIALIZER(saved_sockets);
static struct list listen_tasks = LIST_INITIALIZER(listen_tasks);

static struct saved_socket *find_saved_locked(struct fd *sock) {
    struct saved_socket *saved;
    list_for_each_entry(&saved_sockets, saved, saved) {
        if (saved->sock == sock)
            return saved;
    }
    return NULL;
}

static void record_listener_locked(struct fd *sock) {
    if (find_saved_locked(sock) != NULL)
        return;
    int type = 0;
    socklen_t type_len = sizeof(type);
    if (getsockopt(sock->real_fd, SOL_SOCKET, SO_TYPE, &type, &type_len) < 0 || type_len != sizeof(type))
        return;
    struct saved_socket *saved = calloc(1, sizeof(struct saved_socket));
    if (saved == NULL)
        return;
    saved->name_len = sizeof(saved->name);
    if (getsockname(sock->real_fd, (struct sockaddr *) &saved->name, &saved->name_len) < 0 || saved->name_len == 0) {
        free(saved);
        return;
    }
    if (saved->name_addr.sa_family != AF_INET && saved->name_addr.sa_family != AF_INET6) {
        free(saved);
        return;
    }
    // Non-owning reference guarded by sockrestart_lock: sock_close() calls
    // sockrestart_end_listen(fd) before closing real_fd or freeing fd.
    // Retaining fd here would create a refcount cycle preventing sock_close().
    saved->sock = sock;
    saved->type = type;
    saved->proto = sock->socket.protocol;
    list_add(&saved_sockets, &saved->saved);
}

static bool rebind_saved_socket(struct saved_socket *saved) {
    int new_sock = socket(saved->name_addr.sa_family, saved->type, saved->proto);
    if (new_sock < 0) {
        printk("sockrestart: socket(%d, %d, %d) failed: %s\n",
                saved->name_addr.sa_family, saved->type, saved->proto, strerror(errno));
        return false;
    }
    int one = 1;
    (void) setsockopt(new_sock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
#ifdef SO_NOSIGPIPE
    (void) setsockopt(new_sock, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
    if (bind(new_sock, (struct sockaddr *) &saved->name, saved->name_len) < 0) {
        printk("sockrestart: bind failed: %s\n", strerror(errno));
        close(new_sock);
        return false;
    }
    if (saved->type == SOCK_STREAM && listen(new_sock, SOMAXCONN) < 0) {
        printk("sockrestart: listen failed: %s\n", strerror(errno));
        close(new_sock);
        return false;
    }
    if (dup2(new_sock, saved->sock->real_fd) < 0) {
        printk("sockrestart: dup2 failed: %s\n", strerror(errno));
        close(new_sock);
        return false;
    }
    close(new_sock);
    return true;
}

static void wake_listen_tasks_locked(void) {
    struct task *task;
    list_for_each_entry(&listen_tasks, task, sockrestart.listen) {
        task->sockrestart.punt = true;
        pthread_kill(task->thread, SIGUSR1);
    }
}

void sockrestart_begin_listen(struct fd *sock) {
    if (sock->ops != &socket_fdops)
        return;
    lock(&sockrestart_lock);
    list_remove_safe(&sock->sockrestart.listen);
    list_add(&listen_fds, &sock->sockrestart.listen);
    record_listener_locked(sock);
    unlock(&sockrestart_lock);
}

void sockrestart_end_listen(struct fd *sock) {
    if (sock->ops != &socket_fdops)
        return;
    lock(&sockrestart_lock);
    list_remove_safe(&sock->sockrestart.listen);
    struct saved_socket *saved = find_saved_locked(sock);
    if (saved != NULL) {
        list_remove(&saved->saved);
        free(saved);
    }
    unlock(&sockrestart_lock);
}

void sockrestart_begin_listen_wait(struct fd *sock) {
    if (sock->ops != &socket_fdops)
        return;
    lock(&sockrestart_lock);
    if (current->sockrestart.count == 0)
        list_add(&listen_tasks, &current->sockrestart.listen);
    current->sockrestart.count++;
    unlock(&sockrestart_lock);
}

void sockrestart_end_listen_wait(struct fd *sock) {
    if (sock->ops != &socket_fdops)
        return;
    lock(&sockrestart_lock);
    if (current->sockrestart.count > 0) {
        current->sockrestart.count--;
        if (current->sockrestart.count == 0)
            list_remove_safe(&current->sockrestart.listen);
    }
    unlock(&sockrestart_lock);
}

bool sockrestart_should_restart_listen_wait() {
    lock(&sockrestart_lock);
    bool punt = current->sockrestart.punt;
    current->sockrestart.punt = false;
    unlock(&sockrestart_lock);
    return punt;
}

void sockrestart_on_suspend() {
    lock(&sockrestart_lock);
    struct fd *sock;
    list_for_each_entry(&listen_fds, sock, sockrestart.listen) {
        record_listener_locked(sock);
    }
    unlock(&sockrestart_lock);
}

void sockrestart_recover_dead_listeners(void) {
    lock(&sockrestart_lock);
    bool recovered_any = false;
    struct saved_socket *saved;
    list_for_each_entry(&saved_sockets, saved, saved) {
        // Check whether XNU reclaimed the listening socket while suspended.
        int listening = 0;
        socklen_t len = sizeof(listening);
        bool dead = getsockopt(saved->sock->real_fd, SOL_SOCKET, SO_ACCEPTCONN, &listening, &len) < 0 || !listening;
        if (!dead) {
            struct sockaddr_storage probe;
            socklen_t probe_len = sizeof(probe);
            if (getsockname(saved->sock->real_fd, (struct sockaddr *) &probe, &probe_len) < 0)
                dead = true;
        }
        if (dead && rebind_saved_socket(saved))
            recovered_any = true;
    }
    if (recovered_any)
        wake_listen_tasks_locked();
    unlock(&sockrestart_lock);
}

void sockrestart_on_resume() {
    sockrestart_recover_dead_listeners();
}
