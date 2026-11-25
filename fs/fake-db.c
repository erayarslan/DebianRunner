#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
#include "kernel/errno.h"
#include "debug.h"
#include "misc.h"
#include "fs/fake-db.h"

static void db_check_error(struct fakefs_db *fs) {
    int errcode = sqlite3_errcode(fs->db);
    switch (errcode) {
        case SQLITE_OK:
        case SQLITE_ROW:
        case SQLITE_DONE:
            break;

        default:
            die("sqlite error: %d %#x %s", errcode, sqlite3_extended_errcode(fs->db), sqlite3_errmsg(fs->db));
    }
}

// Retry-aware variants that handle SQLITE_BUSY/SQLITE_LOCKED instead of aborting.
// Exponential backoff from 250us up to 20ms avoids 20ms stalls on brief lock contention
// while preserving ~1s total retry budget for multi-process FileProvider contention.
#define DB_RETRY_MAX 60
#define DB_RETRY_INITIAL_US 250
#define DB_RETRY_MAX_US 20000

static void db_retry_sleep(int attempt) {
    unsigned delay = DB_RETRY_INITIAL_US;
    int shift = attempt < 8 ? attempt : 8;
    delay <<= shift;
    if (delay > DB_RETRY_MAX_US)
        delay = DB_RETRY_MAX_US;
    usleep(delay);
}

static bool db_exec_retry(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    for (int attempt = 0; attempt < DB_RETRY_MAX; attempt++) {
        int err = sqlite3_step(stmt);
        if (err == SQLITE_ROW || err == SQLITE_DONE || err == SQLITE_OK) {
            fs->last_exec_ok = true;
            return err == SQLITE_ROW;
        }
        int errcode = sqlite3_errcode(fs->db);
        if (errcode == SQLITE_BUSY || errcode == SQLITE_LOCKED) {
            sqlite3_reset(stmt);
            db_retry_sleep(attempt);
            continue;
        }
        db_check_error(fs);
        fs->last_exec_ok = false;
        return false;
    }
    printk("WARNING: db_exec_retry exhausted %d attempts, proceeding\n", DB_RETRY_MAX);
    fs->last_exec_ok = false;
    return false;
}

static void db_reset_retry(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    for (int attempt = 0; attempt < DB_RETRY_MAX; attempt++) {
        sqlite3_reset(stmt);
        int errcode = sqlite3_errcode(fs->db);
        if (errcode == SQLITE_OK || errcode == SQLITE_ROW || errcode == SQLITE_DONE)
            return;
        if (errcode == SQLITE_BUSY || errcode == SQLITE_LOCKED) {
            db_retry_sleep(attempt);
            continue;
        }
        db_check_error(fs);
        return;
    }
    printk("WARNING: db_reset_retry exhausted %d attempts\n", DB_RETRY_MAX);
}

// [T-fakefs-db-init-no-die] Init-phase variants that DO NOT abort the whole app
// on a SQLite error. fake_db_init() runs every time a fakefs mount is opened
// (incl. dynamic bind-mounts while the app is running); on iOS 27 betas these
// prepare/step calls were hitting SQLITE_BUSY/LOCKED/IOERR and the old
// db_check_error() → die() path killed the entire process (Abort trap 6 on a
// node-* thread, symbolicated to fake_db_init.cold.1). Instead: retry transient
// lock contention, log the full error, and return the SQLite error code so
// fake_db_init() can fail the mount gracefully (the caller already handles a
// negative return). Returns SQLITE_OK on success.
static int db_log_error(struct fakefs_db *fs, const char *what, const char *sql) {
    int errcode = sqlite3_errcode(fs->db);
    printk("fakefs db init error: %s%s%s — code=%d ext=%#x msg=%s\n",
           what, sql ? " sql=" : "", sql ? sql : "",
           errcode, sqlite3_extended_errcode(fs->db), sqlite3_errmsg(fs->db));
    return errcode;
}

// Prepare a statement, retrying transient BUSY/LOCKED. On terminal failure logs
// and returns the SQLite error code (caller must check); *out is set to the
// statement (NULL on failure).
static int db_prepare_checked(struct fakefs_db *fs, const char *sql, sqlite3_stmt **out) {
    for (int attempt = 0; attempt < DB_RETRY_MAX; attempt++) {
        sqlite3_stmt *stmt = NULL;
        int rc = sqlite3_prepare_v2(fs->db, sql, strlen(sql) + 1, &stmt, NULL);
        if (rc == SQLITE_OK) {
            *out = stmt;
            return SQLITE_OK;
        }
        if (rc == SQLITE_BUSY || rc == SQLITE_LOCKED) {
            if (stmt) sqlite3_finalize(stmt);
            db_retry_sleep(attempt);
            continue;
        }
        if (stmt) sqlite3_finalize(stmt);
        *out = NULL;
        return db_log_error(fs, "prepare", sql);
    }
    *out = NULL;
    printk("fakefs db init: prepare exhausted %d retries: %s\n", DB_RETRY_MAX, sql);
    return SQLITE_BUSY;
}

// Step a statement to completion, retrying transient BUSY/LOCKED. Returns
// SQLITE_DONE/SQLITE_ROW on success, or the error code on terminal failure.
static int db_step_checked(struct fakefs_db *fs, sqlite3_stmt *stmt, const char *sql) {
    for (int attempt = 0; attempt < DB_RETRY_MAX; attempt++) {
        int rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE || rc == SQLITE_ROW || rc == SQLITE_OK)
            return rc;
        if (rc == SQLITE_BUSY || rc == SQLITE_LOCKED) {
            sqlite3_reset(stmt);
            db_retry_sleep(attempt);
            continue;
        }
        return db_log_error(fs, "step", sql);
    }
    printk("fakefs db init: step exhausted %d retries: %s\n", DB_RETRY_MAX, sql);
    return SQLITE_BUSY;
}

// Convenience: prepare + step + finalize a one-shot statement (pragmas, etc.),
// retrying transient lock contention. Returns SQLITE_OK or the error code.
static int db_exec_oneshot(struct fakefs_db *fs, const char *sql) {
    sqlite3_stmt *stmt = NULL;
    int rc = db_prepare_checked(fs, sql, &stmt);
    if (rc != SQLITE_OK)
        return rc;
    rc = db_step_checked(fs, stmt, sql);
    sqlite3_finalize(stmt);
    return (rc == SQLITE_DONE || rc == SQLITE_ROW || rc == SQLITE_OK) ? SQLITE_OK : rc;
}

// ---- Metadata cache --------------------------------------------------------
// Application startup resolves thousands of paths, and path_normalize checks
// every component for a symlink, so a stat cost one SQLite read transaction
// per component (WAL shm fcntl locks and purgeable-cache pins: ~34 us/stat).
// path_cache maps path -> (exists, inode) ONLY; stat payloads live exclusively
// in inode_cache, so inode_write_stat updates every hard-linked path with zero
// staleness. Local point mutations update caches in place without bumping
// fs->generation; bulk subtree renames (path_rename), rolled-back writes, and
// external-process commits detected via meta.db-shm invalidate globally via
// fs->generation++. Entries are only used under fs->lock.
#define FAKEFS_CACHE_SLOTS 8192
#define FAKEFS_CACHE_PATH 240
struct fakefs_path_cache_entry {
    uint64_t generation;   // 0: empty
    bool exists;
    inode_t inode;
    uint16_t len;
    char path[FAKEFS_CACHE_PATH];
};
struct fakefs_inode_cache_entry {
    uint64_t generation;
    inode_t inode;
    bool exists;
    struct ish_stat stat;
};
static uint32_t cache_hash(const char *data, size_t len) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < len; i++) { h ^= (unsigned char) data[i]; h *= 16777619u; }
    return h;
}
static bool cache_ready(struct fakefs_db *fs) {
    if (fs->path_cache && fs->inode_cache) return true;
    if (!fs->path_cache) fs->path_cache = calloc(FAKEFS_CACHE_SLOTS, sizeof(*fs->path_cache));
    if (!fs->inode_cache) fs->inode_cache = calloc(FAKEFS_CACHE_SLOTS, sizeof(*fs->inode_cache));
    return fs->path_cache && fs->inode_cache;
}
static struct fakefs_inode_cache_entry *inode_cache_slot(struct fakefs_db *fs, inode_t inode) {
    uint64_t h = (uint64_t) inode * 11400714819323198485ULL;
    return &fs->inode_cache[(h >> (64 - 13)) & (FAKEFS_CACHE_SLOTS - 1)];
}
static void inode_cache_store(struct fakefs_db *fs, inode_t inode, bool exists, const struct ish_stat *stat) {
    if (!cache_ready(fs)) return;
    struct fakefs_inode_cache_entry *slot = inode_cache_slot(fs, inode);
    slot->generation = fs->generation;
    slot->inode = inode;
    slot->exists = exists;
    if (exists && stat) slot->stat = *stat;
    else memset(&slot->stat, 0, sizeof(slot->stat));
}
static void inode_cache_invalidate(struct fakefs_db *fs, inode_t inode) {
    if (!fs->inode_cache) return;
    struct fakefs_inode_cache_entry *slot = inode_cache_slot(fs, inode);
    if (slot->generation == fs->generation && slot->inode == inode)
        slot->generation = 0;
}
static struct fakefs_path_cache_entry *path_cache_find(struct fakefs_db *fs, const char *path) {
    size_t len = strlen(path);
    if (len >= FAKEFS_CACHE_PATH || !cache_ready(fs)) return NULL;
    struct fakefs_path_cache_entry *e = &fs->path_cache[cache_hash(path, len) & (FAKEFS_CACHE_SLOTS - 1)];
    if (e->generation == fs->generation && e->len == len && memcmp(e->path, path, len) == 0) { fs->cache_hits++; return e; }
    fs->cache_misses++;
    return NULL;
}
static void path_cache_store(struct fakefs_db *fs, const char *path, bool exists, inode_t inode) {
    size_t len = strlen(path);
    if (len >= FAKEFS_CACHE_PATH || !cache_ready(fs)) return;
    struct fakefs_path_cache_entry *e = &fs->path_cache[cache_hash(path, len) & (FAKEFS_CACHE_SLOTS - 1)];
    e->generation = fs->generation;
    e->exists = exists;
    e->inode = inode;
    e->len = (uint16_t) len;
    memcpy(e->path, path, len);
}

static bool db_is_transaction_stmt(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    return stmt == fs->stmt.begin_deferred || stmt == fs->stmt.begin_immediate ||
           stmt == fs->stmt.commit || stmt == fs->stmt.rollback;
}
static bool db_is_targeted_write_stmt(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    return stmt == fs->stmt.path_create_stat ||
           stmt == fs->stmt.path_create_path ||
           stmt == fs->stmt.inode_write_stat ||
           stmt == fs->stmt.path_link ||
           stmt == fs->stmt.path_unlink;
}

bool db_exec(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    if (!db_is_transaction_stmt(fs, stmt)) {
        // A deferred read transaction starts with its first real query.
        if (fs->read_pending && !fs->in_txn) {
            db_exec_retry(fs, fs->stmt.begin_deferred);
            db_reset_retry(fs, fs->stmt.begin_deferred);
            fs->in_txn = true;
        }
        if (!sqlite3_stmt_readonly(stmt)) {
            fs->read_pending = false;
            // Point mutations maintain path_cache/inode_cache in place; bulk
            // renames (path_rename) and uncategorized writes invalidate globally.
            if (!db_is_targeted_write_stmt(fs, stmt))
                fs->generation++;
        }
    }
    return db_exec_retry(fs, stmt);
}
void db_reset(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    db_reset_retry(fs, stmt);
}
void db_exec_reset(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    db_exec(fs, stmt);
    db_reset(fs, stmt);
}

// Detect commits by other connections (other processes) since our last look.
// Preferred: the WAL-index header in "<db>-shm" (SQLite file format, section
// "WAL-Index Format": iChange at byte 8, mxFrame at 16, aSalt at 32; duplicate
// copy at byte +48), which every committing connection updates and maps;
// reading it costs no system call. Fallback: size and mtime of db and WAL.
static bool cache_read_shm_token(const volatile uint32_t *hdr, uint32_t out[4]) {
    // SQLite writes WAL-index header copy 1, issues a barrier, then writes copy 2.
    // On weakly-ordered ARM64, read copy 2 first, then acquire-fence, then copy 1,
    // and require isInit (byte 12 of each 48-byte copy) to be non-zero.
    uint32_t init2 = hdr[15] & 0xffu;
    uint32_t token2[4] = {hdr[14], hdr[16], hdr[20], hdr[21]};
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    uint32_t init1 = hdr[3] & 0xffu;
    uint32_t token1[4] = {hdr[2], hdr[4], hdr[8], hdr[9]};
    if (!init1 || !init2 || memcmp(token1, token2, sizeof token1) != 0)
        return false;
    memcpy(out, token1, sizeof token1);
    return true;
}

static bool cache_check_shm(struct fakefs_db *fs) {
    if (!fs->shm_header && fs->db_path) {
        char shm[4096];
        snprintf(shm, sizeof shm, "%s-shm", fs->db_path);
        int fd = open(shm, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            struct stat st;
            if (fstat(fd, &st) == 0 && st.st_size >= 136) {
                void *map = mmap(NULL, 136, PROT_READ, MAP_SHARED, fd, 0);
                if (map != MAP_FAILED) fs->shm_header = map;
            }
            close(fd);
        }
    }
    if (!fs->shm_header) return false;
    uint32_t token[4];
    if (!cache_read_shm_token(fs->shm_header, token)) {
        // Another connection is mid-update (or uninitialized) in the WAL-index
        // header: invalidate conservatively and clear shm_token to resync next look.
        fs->generation++;
        memset(fs->shm_token, 0, sizeof fs->shm_token);
        return true;
    }
    if (memcmp(token, fs->shm_token, sizeof token) != 0) {
        fs->generation++;
        memcpy(fs->shm_token, token, sizeof token);
    }
    return true;
}
static void cache_check_external_writes(struct fakefs_db *fs) {
    if (!fs->db_path) { fs->generation++; return; }   // cannot tell: no caching
    if (cache_check_shm(fs)) return;
    if (fs->db_fd < 0) fs->db_fd = open(fs->db_path, O_RDONLY | O_CLOEXEC);
    char wal[4096];
    snprintf(wal, sizeof wal, "%s-wal", fs->db_path);
    struct stat db_st = {0}, wal_st = {0};
    bool ok = fs->db_fd >= 0 && fstat(fs->db_fd, &db_st) == 0;
    // stat() the WAL path on each fallback check so a WAL unlink/recreate
    // after checkpoint never leaves a cached fd pinned to an unlinked inode.
    if (stat(wal, &wal_st) != 0 && errno != ENOENT) ok = false;
#ifdef __APPLE__
    int64_t db_mtime = (int64_t) db_st.st_mtimespec.tv_sec * 1000000000 + db_st.st_mtimespec.tv_nsec;
    int64_t wal_mtime = (int64_t) wal_st.st_mtimespec.tv_sec * 1000000000 + wal_st.st_mtimespec.tv_nsec;
#else
    int64_t db_mtime = (int64_t) db_st.st_mtim.tv_sec * 1000000000 + db_st.st_mtim.tv_nsec;
    int64_t wal_mtime = (int64_t) wal_st.st_mtim.tv_sec * 1000000000 + wal_st.st_mtim.tv_nsec;
#endif
    if (!ok || db_st.st_size != fs->file_token.db_size || db_mtime != fs->file_token.db_mtime ||
            wal_st.st_size != fs->file_token.wal_size || wal_mtime != fs->file_token.wal_mtime) {
        fs->generation++;
        fs->file_token.db_size = db_st.st_size; fs->file_token.db_mtime = db_mtime;
        fs->file_token.wal_size = wal_st.st_size; fs->file_token.wal_mtime = wal_mtime;
    }
}
// Advance shm_token after our own COMMIT (still under fs->lock)
// so our commit does not trigger a spurious external-write invalidation.
static void cache_record_own_commit(struct fakefs_db *fs) {
    if (!fs->db_path) return;
    bool wrote = sqlite3_total_changes(fs->db) != fs->write_pre_changes;
    if (fs->shm_header) {
        uint32_t token[4];
        // Require the exact expected iChange delta: +0 if our write transaction
        // modified no rows, +1 if it actually wrote. That prevents a concurrent
        // external commit immediately after a no-op write txn from being absorbed.
        uint32_t expected_change = wrote ? (uint32_t)(fs->shm_token[0] + 1) : fs->shm_token[0];
        if (cache_read_shm_token(fs->shm_header, token) &&
                token[2] == fs->shm_token[2] && token[3] == fs->shm_token[3] &&
                token[0] == expected_change) {
            memcpy(fs->shm_token, token, sizeof token);
        }
        return;
    }
    // Without shm_header we cannot atomically distinguish our commit from a
    // concurrent external commit after releasing the WAL lock; invalidate on write.
    if (wrote)
        fs->generation++;
}

void db_begin_read(struct fakefs_db *fs) {
    sqlite3_mutex_enter(fs->lock);
    cache_check_external_writes(fs);
    fs->read_pending = true;   // BEGIN is issued only if a query misses the caches
    fs->in_txn = false;
}
void db_begin_write(struct fakefs_db *fs) {
    sqlite3_mutex_enter(fs->lock);
    fs->read_pending = false;
    db_exec_reset(fs, fs->stmt.begin_immediate);
    fs->in_txn = true;
    // Check AFTER acquiring SQLite's write lock so any external commit that
    // raced ahead of BEGIN IMMEDIATE is observed and shm_token records the
    // exact pre-commit state.
    cache_check_external_writes(fs);
    fs->write_pre_changes = sqlite3_total_changes(fs->db);
}
static void db_end(struct fakefs_db *fs, sqlite3_stmt *end) {
    bool was_write = fs->in_txn && !fs->read_pending;
    if (fs->in_txn) db_exec_reset(fs, end);
    if (was_write) {
        if (end == fs->stmt.commit)
            cache_record_own_commit(fs);
        else
            // Rolling back a write transaction may have left uncommitted
            // targeted updates in the caches.
            fs->generation++;
    }
    fs->in_txn = false;
    fs->read_pending = false;
    sqlite3_mutex_leave(fs->lock);
}
void db_commit(struct fakefs_db *fs) { db_end(fs, fs->stmt.commit); }
void db_rollback(struct fakefs_db *fs) { db_end(fs, fs->stmt.rollback); }

// Callers keep the bound buffer alive past db_reset(), so SQLITE_STATIC avoids
// per-bind malloc/memcpy inside SQLite.
static void bind_path(sqlite3_stmt *stmt, int i, const char *path) {
    sqlite3_bind_blob(stmt, i, path, strlen(path), SQLITE_STATIC);
}

inode_t path_get_inode(struct fakefs_db *fs, const char *path) {
    struct fakefs_path_cache_entry *hit = path_cache_find(fs, path);
    if (hit) return hit->exists ? hit->inode : 0;
    // select inode from paths where path = ?
    bind_path(fs->stmt.path_get_inode, 1, path);
    inode_t inode = 0;
    if (db_exec(fs, fs->stmt.path_get_inode))
        inode = sqlite3_column_int64(fs->stmt.path_get_inode, 0);
    bool exec_ok = fs->last_exec_ok;
    db_reset(fs, fs->stmt.path_get_inode);
    if (exec_ok)
        path_cache_store(fs, path, inode != 0, inode);
    return inode;
}
bool path_read_stat(struct fakefs_db *fs, const char *path, struct ish_stat *stat, inode_t *inode) {
    struct fakefs_path_cache_entry *hit = path_cache_find(fs, path);
    if (hit) {
        if (!hit->exists)
            return false;
        if (stat) {
            if (!inode_read_stat_if_exist(fs, hit->inode, stat))
                return false;
        }
        if (inode)
            *inode = hit->inode;
        return true;
    }
    // select inode, stat from stats natural join paths where path = ?
    bind_path(fs->stmt.path_read_stat, 1, path);
    bool exists = db_exec(fs, fs->stmt.path_read_stat);
    bool exec_ok = fs->last_exec_ok;
    inode_t found_inode = 0; struct ish_stat found_stat = {0};
    if (exists) {
        found_inode = sqlite3_column_int64(fs->stmt.path_read_stat, 0);
        found_stat = *(struct ish_stat *) sqlite3_column_blob(fs->stmt.path_read_stat, 1);
        if (inode) *inode = found_inode;
        if (stat) *stat = found_stat;
    }
    db_reset(fs, fs->stmt.path_read_stat);
    if (exec_ok) {
        path_cache_store(fs, path, exists, found_inode);
        if (exists)
            inode_cache_store(fs, found_inode, true, &found_stat);
    }
    return exists;
}
inode_t path_create(struct fakefs_db *fs, const char *path, struct ish_stat *stat) {
    // insert into stats (stat) values (?)
    sqlite3_bind_blob(fs->stmt.path_create_stat, 1, stat, sizeof(*stat), SQLITE_STATIC);
    db_exec_reset(fs, fs->stmt.path_create_stat);
    inode_t inode = sqlite3_last_insert_rowid(fs->db);
    // insert or replace into paths values (?, last_insert_rowid())
    bind_path(fs->stmt.path_create_path, 1, path);
    db_exec_reset(fs, fs->stmt.path_create_path);
    path_cache_store(fs, path, true, inode);
    inode_cache_store(fs, inode, true, stat);
    return inode;
}

void inode_read_stat_or_die(struct fakefs_db *fs, inode_t inode, struct ish_stat *stat) {
    if (!inode_read_stat_if_exist(fs, inode, stat))
        die("inode_read_stat(%llu): missing inode", (unsigned long long) inode);
}
bool inode_read_stat_if_exist(struct fakefs_db *fs, inode_t inode, struct ish_stat *stat) {
    struct fakefs_inode_cache_entry *slot = NULL;
    if (cache_ready(fs)) {
        slot = inode_cache_slot(fs, inode);
        if (slot->generation == fs->generation && slot->inode == inode) {
            fs->cache_hits++;
            if (slot->exists) *stat = slot->stat;
            return slot->exists;
        }
        fs->cache_misses++;
    }
    // select stat from stats where inode = ?
    sqlite3_bind_int64(fs->stmt.inode_read_stat, 1, inode);
    bool exist = db_exec(fs, fs->stmt.inode_read_stat);
    bool exec_ok = fs->last_exec_ok;
    struct ish_stat found = {0};
    if (exist) {
        found = *(struct ish_stat *) sqlite3_column_blob(fs->stmt.inode_read_stat, 0);
        *stat = found;
    }
    db_reset(fs, fs->stmt.inode_read_stat);
    if (exec_ok)
        inode_cache_store(fs, inode, exist, exist ? &found : NULL);
    return exist;
}
void inode_write_stat(struct fakefs_db *fs, inode_t inode, struct ish_stat *stat) {
    // update stats set stat = ? where inode = ?
    sqlite3_bind_blob(fs->stmt.inode_write_stat, 1, stat, sizeof(*stat), SQLITE_STATIC);
    sqlite3_bind_int64(fs->stmt.inode_write_stat, 2, inode);
    db_exec_reset(fs, fs->stmt.inode_write_stat);
    if (sqlite3_changes(fs->db) > 0)
        inode_cache_store(fs, inode, true, stat);
    else
        inode_cache_invalidate(fs, inode);
}
void inode_try_cleanup(struct fakefs_db *fs, inode_t inode) {
    // delete from stats where inode = ? and not exists (select 1 from paths where inode = stats.inode)
    sqlite3_bind_int64(fs->stmt.try_cleanup_inode, 1, inode);
    if (fs->read_pending && !fs->in_txn) {
        db_exec_retry(fs, fs->stmt.begin_deferred);
        db_reset_retry(fs, fs->stmt.begin_deferred);
        fs->in_txn = true;
    }
    fs->read_pending = false;
    db_exec_retry(fs, fs->stmt.try_cleanup_inode);
    int deleted = sqlite3_changes(fs->db);
    db_reset(fs, fs->stmt.try_cleanup_inode);
    if (deleted > 0)
        inode_cache_store(fs, inode, false, NULL);
}

void path_link(struct fakefs_db *fs, const char *src, const char *dst) {
    inode_t inode = path_get_inode(fs, src);
    if (inode == 0)
        die("fakefs link(%s, %s): nonexistent src path", src, dst);
    // insert or replace into paths (path, inode) values (?, ?)
    bind_path(fs->stmt.path_link, 1, dst);
    sqlite3_bind_int64(fs->stmt.path_link, 2, inode);
    db_exec_reset(fs, fs->stmt.path_link);
    path_cache_store(fs, dst, true, inode);
}
inode_t path_unlink(struct fakefs_db *fs, const char *path) {
    inode_t inode = path_get_inode(fs, path);
    if (inode == 0)
        return 0;  // Path not in meta.db — already gone or never tracked
    // delete from paths where path = ?
    bind_path(fs->stmt.path_unlink, 1, path);
    db_exec_reset(fs, fs->stmt.path_unlink);
    path_cache_store(fs, path, false, 0);
    return inode;
}
void path_rename(struct fakefs_db *fs, const char *src, const char *dst) {
    // update or replace paths set path = change_prefix(path, ? [len(src)], ? [dst])
    //  where (path >= ? [src plus /] and path < [src plus 0]) or path = ? [src]
    // arguments:
    // 1. length of src
    // 2. dst
    // 3. src plus /
    // 4. src plus 0
    // 5. src
    size_t src_len = strlen(src);
    sqlite3_bind_int64(fs->stmt.path_rename, 1, src_len);
    bind_path(fs->stmt.path_rename, 2, dst);
    char src_slash[src_len + 1];
    char src_zero[src_len + 1];
    memcpy(src_slash, src, src_len);
    src_slash[src_len] = '/';
    memcpy(src_zero, src, src_len);
    src_zero[src_len] = '0';
    sqlite3_bind_blob(fs->stmt.path_rename, 3, src_slash, src_len + 1, SQLITE_STATIC);
    sqlite3_bind_blob(fs->stmt.path_rename, 4, src_zero, src_len + 1, SQLITE_STATIC);
    sqlite3_bind_blob(fs->stmt.path_rename, 5, src, src_len, SQLITE_STATIC);
    db_exec_reset(fs, fs->stmt.path_rename);
}

#if DEBUG_sql
static int trace_callback(unsigned UNUSED(why), void *UNUSED(fuck), void *stmt, void *_sql) {
    char *sql = _sql;
    printk("%d sql trace: %s %s\n", current ? current->pid : -1, sqlite3_expanded_sql(stmt), sql[0] == '-' ? sql : "");
    return 0;
}
#endif

static void sqlite_func_change_prefix(sqlite3_context *context, int argc, sqlite3_value **args) {
    assert(argc == 3);
    const void *in_blob = sqlite3_value_blob(args[0]);
    size_t in_size = sqlite3_value_bytes(args[0]);
    size_t start = sqlite3_value_int64(args[1]);
    const void *replacement = sqlite3_value_blob(args[2]);
    size_t replacement_size = sqlite3_value_bytes(args[2]);
    size_t out_size = in_size - start + replacement_size;
    char *out_blob = sqlite3_malloc(out_size);
    memcpy(out_blob, replacement, replacement_size);
    memcpy(out_blob + replacement_size, in_blob + start, in_size - start);
    sqlite3_result_blob(context, out_blob, out_size, sqlite3_free);
}

extern int fakefs_rebuild(struct fakefs_db *fs, int root_fd);
extern int fakefs_migrate(struct fakefs_db *fs, int root_fd);

int fake_db_init(struct fakefs_db *fs, const char *db_path, int root_fd) {
    fs->db = NULL;
    memset(&fs->stmt, 0, sizeof(fs->stmt));
    fs->lock = NULL;
    fs->read_pending = fs->in_txn = false;
    fs->last_exec_ok = false;
    fs->write_pre_changes = 0;
    fs->generation = 1;
    fs->path_cache = NULL; fs->inode_cache = NULL;
    fs->cache_hits = fs->cache_misses = 0;
    fs->db_path = strdup(db_path);
    fs->db_fd = -1;   // opened only if the WAL index is unavailable
    memset(&fs->file_token, 0, sizeof(fs->file_token));
    fs->shm_header = NULL;
    memset(fs->shm_token, 0, sizeof(fs->shm_token));
    int fail_ret = _EIO;
    // fs->lock serializes every access to fs->db, so SQLITE_OPEN_NOMUTEX avoids
    // redundant per-connection mutex overhead while preserving multi-process WAL
    // locking with iSHFileProvider.appex (never use locking_mode=EXCLUSIVE).
    int err = sqlite3_open_v2(db_path, &fs->db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL);
    if (err != SQLITE_OK) {
        printk("error opening database: %s\n", sqlite3_errmsg(fs->db));
        fail_ret = _EINVAL;
        goto init_fail;
    }
    sqlite3_busy_timeout(fs->db, 5000);
    sqlite3_create_function(fs->db, "change_prefix", 3, SQLITE_UTF8 | SQLITE_DETERMINISTIC, NULL, sqlite_func_change_prefix, NULL, NULL);

    // [T-fakefs-db-init-no-die] Every prepare/step below now fails the mount
    // (return _EIO) instead of die()-ing the whole app on a SQLite error. The
    // caller (fakefs mount) already handles a negative return gracefully.
    if (db_exec_oneshot(fs, "pragma journal_mode=wal") != SQLITE_OK) goto init_fail;
    if (db_exec_oneshot(fs, "pragma foreign_keys=true") != SQLITE_OK) goto init_fail;

    // N18: Apple-friendly sqlite tuning. The fakefs db is read-mostly
    // during normal use (writes happen for chmod / chown / mknod / new
    // files). N17 signpost data showed 78K db_exec calls totaling
    // 122ms = 8% of npm --version user CPU. Three knobs help on macOS:
    //
    //  - PRAGMA mmap_size: lets sqlite read pages directly through
    //    mmap instead of read() syscalls. The OS's unified buffer
    //    cache then serves repeated reads at memcpy speed.
    //  - PRAGMA cache_size (negative => KB of in-process page cache):
    //    sqlite default is 2 MB; bump to 64 MB so the working set fits.
    //  - PRAGMA synchronous=NORMAL: WAL with NORMAL is durable across
    //    process crashes (like FULL) but skips an fsync per commit,
    //    cheap when fakefs writes are infrequent.
    //  - PRAGMA temp_store=MEMORY: keeps sort/temp tables off disk.
    //  - PRAGMA wal_autocheckpoint=8000 / journal_size_limit=64MB: batch WAL
    //    checkpoints during heavy write bursts (dpkg/npm) while bounding disk usage.
#ifdef ISH_FILE_PROVIDER
    // Stay well within iOS File Provider extension Jetsam memory limits.
    static const char *tuning[] = {
        "pragma mmap_size=0",
        "pragma cache_size=-2048",      // 2 MB in-process page cache
        "pragma synchronous=NORMAL",
        "pragma temp_store=MEMORY",
        "pragma wal_autocheckpoint=8000",
        "pragma journal_size_limit=67108864",
    };
#elif defined(__APPLE__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR
    // Keep SQLite memory bounded inside iOS app Jetsam headroom while still
    // fitting Debian minimal's meta.db (~10-15 MB) completely in cache.
    static const char *tuning[] = {
        "pragma mmap_size=67108864",    // 64 MB
        "pragma cache_size=-16384",     // 16 MB in-process page cache
        "pragma synchronous=NORMAL",
        "pragma temp_store=MEMORY",
        "pragma wal_autocheckpoint=8000",
        "pragma journal_size_limit=67108864",
    };
#else
    static const char *tuning[] = {
        "pragma mmap_size=268435456",   // 256 MB
        "pragma cache_size=-65536",     // 64 MB in-process page cache
        "pragma synchronous=NORMAL",
        "pragma temp_store=MEMORY",
        "pragma wal_autocheckpoint=8000",
        "pragma journal_size_limit=67108864",
    };
#endif
    for (size_t ti = 0; ti < sizeof(tuning)/sizeof(tuning[0]); ti++) {
        // Tuning pragmas are best-effort: a failure here only loses a perf knob,
        // not correctness, so log and continue rather than fail the mount.
        if (db_exec_oneshot(fs, tuning[ti]) != SQLITE_OK)
            printk("fakefs db init: tuning pragma failed (continuing): %s\n", tuning[ti]);
    }

#if DEBUG_sql
    sqlite3_trace_v2(mount->db, SQLITE_TRACE_STMT, trace_callback, NULL);
#endif

    err = fakefs_migrate(fs, root_fd);
    if (err < 0) {
        fail_ret = err;
        goto init_fail;
    }

    // after the filesystem is compressed, transmitted, and uncompressed, the
    // inode numbers will be different. to detect this, the inode of the
    // database file is stored inside the database and compared with the actual
    // database file inode, and if they're different we rebuild the database.
    struct stat statbuf;
    if (stat(db_path, &statbuf) < 0) ERRNO_DIE("stat database");
    ino_t db_inode = statbuf.st_ino;
    sqlite3_stmt *statement = NULL;
    if (db_prepare_checked(fs, "select db_inode from meta", &statement) != SQLITE_OK) goto init_fail;
    int sel_rc = db_step_checked(fs, statement, "select db_inode from meta");
    if (sel_rc == SQLITE_ROW) {
        if ((uint64_t) sqlite3_column_int64(statement, 0) != db_inode) {
            sqlite3_finalize(statement);
            statement = NULL;
            err = fakefs_rebuild(fs, root_fd);
            if (err < 0) {
                fail_ret = err;
                goto init_fail;
            }
        }
    } else if (sel_rc != SQLITE_DONE) {
        sqlite3_finalize(statement);
        goto init_fail;
    }
    if (statement != NULL)
        sqlite3_finalize(statement);

    // save current inode
    if (db_prepare_checked(fs, "update meta set db_inode = ?", &statement) != SQLITE_OK) goto init_fail;
    sqlite3_bind_int64(statement, 1, (int64_t) db_inode);
    int meta_rc = db_step_checked(fs, statement, "update meta set db_inode = ?");
    if (meta_rc != SQLITE_DONE && meta_rc != SQLITE_ROW && meta_rc != SQLITE_OK) {
        sqlite3_finalize(statement);
        goto init_fail;
    }
    sqlite3_finalize(statement);

    // delete orphaned stats
    if (db_exec_oneshot(fs, "delete from stats where not exists (select 1 from paths where inode = stats.inode)") != SQLITE_OK)
        goto init_fail;

    fs->lock = sqlite3_mutex_alloc(SQLITE_MUTEX_FAST);
    // [T-fakefs-db-init-no-die] Each cached statement must prepare successfully;
    // a NULL would crash later at runtime. On any failure, fail the mount.
#define PREPARE_OR_FAIL(field, sql) \
    if (db_prepare_checked(fs, (sql), &fs->stmt.field) != SQLITE_OK) goto init_fail
    PREPARE_OR_FAIL(begin_deferred, "begin deferred");
    PREPARE_OR_FAIL(begin_immediate, "begin immediate");
    PREPARE_OR_FAIL(commit, "commit");
    PREPARE_OR_FAIL(rollback, "rollback");
    PREPARE_OR_FAIL(path_get_inode, "select inode from paths where path = ?");
    PREPARE_OR_FAIL(path_read_stat, "select inode, stat from stats natural join paths where path = ?");
    PREPARE_OR_FAIL(path_create_stat, "insert into stats (stat) values (?)");
    PREPARE_OR_FAIL(path_create_path, "insert or replace into paths values (?, last_insert_rowid())");
    PREPARE_OR_FAIL(inode_read_stat, "select stat from stats where inode = ?");
    PREPARE_OR_FAIL(inode_write_stat, "update stats set stat = ? where inode = ?");
    PREPARE_OR_FAIL(path_link, "insert or replace into paths (path, inode) values (?, ?)");
    PREPARE_OR_FAIL(path_unlink, "delete from paths where path = ?");
    PREPARE_OR_FAIL(path_rename, "update or replace paths set path = change_prefix(path, ?, ?) "
            "where (path >= ? and path < ?) or path = ?");
    PREPARE_OR_FAIL(path_from_inode, "select path from paths where inode = ?");
    PREPARE_OR_FAIL(try_cleanup_inode, "delete from stats where inode = ? and not exists (select 1 from paths where inode = stats.inode)");
#undef PREPARE_OR_FAIL
    return 0;

init_fail:
    // [T-fakefs-db-init-no-die] A SQLite error during init no longer aborts the
    // whole app. Finalize any prepared statements, close the half-open db, and
    // free auxiliary resources so the fakefs mount fails cleanly without leaks.
    printk("fakefs db init: FAILED for %s — mount aborted (app kept alive)\n", db_path);
    fake_db_deinit(fs);
    return fail_ret;
}

int fake_db_deinit(struct fakefs_db *fs) {
    free(fs->path_cache); fs->path_cache = NULL;
    free(fs->inode_cache); fs->inode_cache = NULL;
    if (fs->db_fd >= 0) close(fs->db_fd);
    fs->db_fd = -1;
    free(fs->db_path); fs->db_path = NULL;
    if (fs->shm_header) { munmap((void *) fs->shm_header, 136); fs->shm_header = NULL; }
    if (fs->lock) { sqlite3_mutex_free(fs->lock); fs->lock = NULL; }
    int rc = SQLITE_OK;
    if (fs->db) {
        sqlite3_finalize(fs->stmt.begin_deferred);
        sqlite3_finalize(fs->stmt.begin_immediate);
        sqlite3_finalize(fs->stmt.commit);
        sqlite3_finalize(fs->stmt.rollback);
        sqlite3_finalize(fs->stmt.path_get_inode);
        sqlite3_finalize(fs->stmt.path_read_stat);
        sqlite3_finalize(fs->stmt.path_create_stat);
        sqlite3_finalize(fs->stmt.path_create_path);
        sqlite3_finalize(fs->stmt.inode_read_stat);
        sqlite3_finalize(fs->stmt.inode_write_stat);
        sqlite3_finalize(fs->stmt.path_link);
        sqlite3_finalize(fs->stmt.path_unlink);
        sqlite3_finalize(fs->stmt.path_rename);
        sqlite3_finalize(fs->stmt.path_from_inode);
        sqlite3_finalize(fs->stmt.try_cleanup_inode);
        memset(&fs->stmt, 0, sizeof(fs->stmt));
        rc = sqlite3_close(fs->db);
        fs->db = NULL;
    }
    return rc;
}
