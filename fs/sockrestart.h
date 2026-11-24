// Work around iOS reclaiming listening sockets when an app is suspended
// (Apple Technical Note TN2277). Keep track of listening sockets and any
// threads blocked waiting on them; if iOS reclaims a listening socket while
// suspended, recreate, bind, listen, dup2 it back onto the original host fd,
// and wake threads waiting in accept/poll.
#ifndef FS_SOCKRESTART_H
#define FS_SOCKRESTART_H
#include <stdbool.h>
#include "util/list.h"
struct fd;

void sockrestart_begin_listen(struct fd *sock);
void sockrestart_end_listen(struct fd *sock);
void sockrestart_begin_listen_wait(struct fd *sock);
void sockrestart_end_listen_wait(struct fd *sock);
bool sockrestart_should_restart_listen_wait(void);
void sockrestart_on_suspend(void);
void sockrestart_on_resume(void);
void sockrestart_recover_dead_listeners(void);

struct fd_sockrestart {
    struct list listen;
};

struct task_sockrestart {
    int count;
    bool punt;
    struct list listen;
};

#endif
