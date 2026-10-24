/*
 * sim.c - run the real ml/700d module on the desktop.
 *
 *     sim700d <card dir> <expected FLM_ file from previewcheck>
 *
 * The card directory holds ML/FILM with the films and DCIM/100CANON
 * with one raw, IMG_0001.CR2, the way tools/sim700d.sh lays it out. The
 * driver loads the module, then plays the camera at it:
 *
 *   1. the module's own init: films found, the remembered film picked;
 *   2. a shot with auto on: the counter moves, the raw "appears" over
 *      two ticks, the watcher ripens it, the worker develops it, and the
 *      file is compared with the desktop's byte for byte;
 *   3. a burst of three with the counter moving at once: three queued;
 *   4. auto off, a shot: nothing queued; auto on again: still nothing,
 *      because the counter was followed while off;
 *   5. a raw that never finishes: given up after thirty ticks;
 *   6. the picker: SET opens, DOWN twice and SET picks the third film
 *      and saves its name's hash, TRASH cancels, DEVELOP LAST SHOT
 *      queues, the AUTO row flips and stays open, half-shutter closes
 *      and passes the key through, six idle ticks close it;
 *   7. power-off mid-frame: the worker stops within a row and the
 *      partial file is gone.
 *
 * Every fake is deliberately minimal and every check is a line of
 * output; the script greps for "FAIL". Exit status says the same.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <unistd.h>
#include <dirent.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <fcntl.h>

/* The module's view of Magic Lantern, which this file implements. */
#define SE700_SIM_DRIVER
#define FILE SIM_NO_FILE
#include "ml.h"
#undef FILE

/* what the module exports and the fakes above reach back for */
extern unsigned (*sim_module_init)(void), (*sim_module_deinit)(void);
extern unsigned (*sim_cbr_clock)(unsigned), (*sim_cbr_key)(unsigned);
extern int se_nstocks, se_stock_index, se_stock_id, se_auto, se_size;
extern volatile int se_busy, se_q_head, se_q_tail;
extern int se_q_count(void);
extern uint32_t se_name_id(const char *);
#include "stock.h"                 /* se_stocks[].name, for one check */
extern se_stock *se_stocks;

/* ------------------------------------------------------------- state */
static char  g_card[512];
static char  g_dcim[600];
static struct card_info g_ml_card = { "B", "SD" }, g_shoot_card = { "B", "SD" };
int ml_shutdown_requested;
int lv;
struct lens_info_sim lens_info;
static int g_menu_shown, g_display_on = 1, g_play_mode;
static int g_fails, g_checks;
static int g_draws, g_draw_errors, g_notify;
static long g_fio_used, g_fio_peak;
static int g_short_reads = 1;

#define FIO_POOL (3072L * 1024)       /* what the camera reported free */

static void check(int ok, const char *fmt, ...)
{
    va_list ap;
    g_checks++;
    if (!ok) g_fails++;
    printf("  %s ", ok ? "ok  " : "FAIL");
    va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    printf("\n");
}

/* B:/x/y -> <card>/x/y; a bare path is relative to the card */
static const char *host_path(const char *p, char *buf, size_t n)
{
    if (p[1] == ':') snprintf(buf, n, "%s/%s", g_card, p + 3);
    else             snprintf(buf, n, "%s/%s", g_card, p);
    return buf;
}

/* --------------------------------------------------------------- FIO */
struct sim_file { int fd; };
struct fio_file { struct file_info fi; };
struct fio_dirent { DIR *d; };

struct sim_file *FIO_OpenFile(const char *name, unsigned mode)
{
    char b[1024]; int fd = open(host_path(name, b, sizeof b), O_RDONLY);
    struct sim_file *f;
    if (fd < 0) return 0;
    f = calloc(1, sizeof *f); f->fd = fd; return f;
}
struct sim_file *FIO_CreateFile(const char *name)
{
    char b[1024]; const char *hp = host_path(name, b, sizeof b);
    const char *slash = strrchr(hp, '/');
    struct sim_file *f; int fd;
    /* DryOS is 8.3: refuse a name that is not, as the camera did */
    if (slash && strlen(slash + 1) > 12) return 0;
    fd = open(hp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return 0;
    f = calloc(1, sizeof *f); f->fd = fd; return f;
}
struct sim_file *FIO_CreateFileOrAppend(const char *name)
{
    char b[1024]; int fd = open(host_path(name, b, sizeof b), O_WRONLY | O_CREAT | O_APPEND, 0644);
    struct sim_file *f;
    if (fd < 0) return 0;
    f = calloc(1, sizeof *f); f->fd = fd; return f;
}
int FIO_ReadFile(struct sim_file *f, void *buf, size_t n)
{
    /* short reads: the card may return less than asked, and does */
    if (g_short_reads && n > 4096 && (rand() & 3) == 0) n = n / 2 + 1;
    return (int)read(f->fd, buf, n);
}
int FIO_WriteFile(struct sim_file *f, const void *buf, size_t n) { return (int)write(f->fd, buf, n); }
void FIO_CloseFile(struct sim_file *f) { if (f) { close(f->fd); free(f); } }
int FIO_GetFileSize(const char *name, uint32_t *size)
{
    char b[1024]; struct stat st;
    if (stat(host_path(name, b, sizeof b), &st) != 0) return -1;
    *size = (uint32_t)st.st_size; return 0;
}
uint32_t FIO_GetFileSize_direct(const char *name) { uint32_t s = 0; FIO_GetFileSize(name, &s); return s; }
int64_t FIO_SeekSkipFile(struct sim_file *f, int64_t pos, int whence) { return lseek(f->fd, pos, whence); }
int FIO_RemoveFile(const char *name) { char b[1024]; return unlink(host_path(name, b, sizeof b)); }
struct fio_dirent *FIO_FindFirstEx(const char *dir, struct fio_file *file)
{
    char b[1024]; DIR *d = opendir(host_path(dir, b, sizeof b));
    struct fio_dirent *r;
    if (!d) return (struct fio_dirent *)1;              /* IS_ERROR */
    r = calloc(1, sizeof *r); r->d = d;
    if (FIO_FindNextEx(r, file) != 0) { closedir(d); free(r); return (struct fio_dirent *)1; }
    return r;
}
int FIO_FindNextEx(struct fio_dirent *r, struct fio_file *file)
{
    struct dirent *e;
    while ((e = readdir(r->d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        memset(&file->fi, 0, sizeof file->fi);
        snprintf(file->fi.name, sizeof file->fi.name, "%s", e->d_name);
        file->fi.mode = e->d_type == DT_DIR ? ATTR_DIRECTORY : 0;
        return 0;
    }
    return -1;
}
void FIO_FindClose(struct fio_dirent *r) { if (!IS_ERROR(r)) { closedir(r->d); free(r); } }
struct fio_file *alloc_fio_file(void) { return calloc(1, sizeof(struct fio_file)); }
struct file_info convert_fio_file_info(struct fio_file *f) { return f->fi; }
struct card_info *get_ml_card(void) { return &g_ml_card; }
struct card_info *get_shooting_card(void) { return &g_shoot_card; }
const char *get_dcim_dir(void) { return g_dcim; }
char *get_file_prefix(void) { return (char *)"IMG_"; }

/* ------------------------------------------------------------ memory */
typedef struct { size_t n; } fio_hdr;
void *__mem_malloc(size_t n, unsigned flags, const char *file, unsigned line) { return malloc(n); }
void *fio_malloc(size_t n)
{
    fio_hdr *h;
    if (g_fio_used + (long)n > FIO_POOL) return 0;      /* the camera would refuse too */
    h = malloc(n + 64); if (!h) return 0;
    h->n = n; g_fio_used += (long)n;
    if (g_fio_used > g_fio_peak) g_fio_peak = g_fio_used;
    return (char *)h + 64;
}
void fio_free(void *p) { fio_hdr *h = (fio_hdr *)((char *)p - 64); g_fio_used -= (long)h->n; free(h); }
int GetFreeMemForMalloc(void) { return 137 * 1024; }
int GetFreeMemForAllocateMemory(void) { return (int)(FIO_POOL - g_fio_used); }

/* ------------------------------------------------------------- tasks */
void msleep(int ms) { usleep((useconds_t)ms * 1000); }
int get_ms_clock(void) { struct timeval t; gettimeofday(&t, 0); return (int)(t.tv_sec * 1000 + t.tv_usec / 1000); }
static void *thread_entry(void *arg) { void (*fn)(void *) = ((void **)arg)[0]; fn(((void **)arg)[1]); return 0; }
static pthread_t g_worker;
int task_create(const char *name, int prio, int stack, void (*entry)(void *), void *arg)
{
    void **pair = malloc(2 * sizeof(void *)); pair[0] = (void *)entry; pair[1] = arg;
    pthread_create(&g_worker, 0, thread_entry, pair);
    return 0;
}
static int g_powersave_held;
void powersave_prohibit(void) { g_powersave_held++; }
void powersave_permit(void)   { g_powersave_held--; }

/* ------------------------------------------------------------ screen */
int bmp_printf(uint32_t font, int x, int y, const char *fmt, ...)
{
    char s[256]; va_list ap;
    va_start(ap, fmt); vsnprintf(s, sizeof s, fmt, ap); va_end(ap);
    g_draws++;
    if (x < 0 || y < 0 || x >= 720 || y + 24 > 480) g_draw_errors++;
    return (int)strlen(s) * 10;
}
void bmp_fill(uint8_t color, int x, int y, int w, int h)
{
    g_draws++;
    if (x < 0 || y < 0 || x + w > 720 || y + h > 480) g_draw_errors++;
}
void bmp_draw_rect(int color, int x, int y, int w, int h) { bmp_fill((uint8_t)color, x, y, w, h); }
void NotifyBox(int timeout, char *fmt, ...) { g_notify++; }
int gui_menu_shown(void) { return g_menu_shown; }
int display_is_on(void) { return g_display_on; }
int is_play_mode(void) { return g_play_mode; }
void redraw(void) {}
void menu_add(const char *name, struct menu_entry *e, int count) {}
void menu_remove(const char *name, struct menu_entry *e, int count) {}
MENU_SELECT_FUNC(menu_open_submenu) {}

/* ------------------------------------------------------------ driver */
static void tick(int n) { while (n-- > 0) sim_cbr_clock(0); }

static void wait_idle(int max_s)
{
    int t = 0;
    while ((se_busy || se_q_count()) && t < max_s * 10) { usleep(100000); t++; }
}

static int exists(const char *rel) { char b[1024]; struct stat st; snprintf(b, sizeof b, "%s/%s", g_card, rel); return stat(b, &st) == 0; }

static int same_file(const char *a, const char *b)
{
    FILE *fa = fopen(a, "rb"), *fb = fopen(b, "rb"); int same = 1;
    if (!fa || !fb) return 0;
    for (;;) {
        unsigned char x[4096], y[4096]; size_t na = fread(x, 1, sizeof x, fa), nb = fread(y, 1, sizeof y, fb);
        if (na != nb || memcmp(x, y, na)) { same = 0; break; }
        if (!na) break;
    }
    fclose(fa); fclose(fb); return same;
}

/* "take a shot": the counter moves now; the raw appears `delay` ticks later */
static void shoot(int number, int delay_ticks, const char *from)
{
    char dst[1024];
    g_shoot_card.file_number = number;
    lens_info.job_state = 8;                               /* writing */
    snprintf(dst, sizeof dst, "%s/DCIM/100CANON/IMG_%04d.CR2", g_card, number);
    tick(delay_ticks);
    if (from) { char cmd[2200]; snprintf(cmd, sizeof cmd, "cp '%s' '%s'", from, dst); system(cmd); }
    lens_info.job_state = 0;
}

int main(int argc, char **argv)
{
    char sample[1024];
    const char *expect;
    if (argc < 3) { fprintf(stderr, "usage: sim700d <card dir> <expected FLM jpg>\n"); return 2; }
    snprintf(g_card, sizeof g_card, "%s", argv[1]);
    snprintf(g_dcim, sizeof g_dcim, "B:/DCIM/100CANON");
    snprintf(sample, sizeof sample, "%s/sample.CR2", g_card);
    expect = argv[2];
    if (getenv("SE_SIM_SHORT_READS")) g_short_reads = atoi(getenv("SE_SIM_SHORT_READS"));
    srand(1);

    printf("sim700d: card=%s short_reads=%s\n", g_card, g_short_reads ? "on" : "off");

    /* 1. init */
    g_shoot_card.file_number = 100; g_shoot_card.folder_number = 100;
    se_size = 2;                                           /* quarter, as the reference */
    check(sim_module_init() == 0, "module init");
    check(se_nstocks == 13, "13 films found (%d)", se_nstocks);
    tick(1);                                               /* the baseline tick */

    /* 2. one shot, auto on: developed, byte for byte */
    se_auto = 1;
    shoot(101, 1, sample);
    tick(3);                                               /* size seen twice, job idle */
    check(se_q_count() == 1 || se_busy, "shot 101 queued");
    wait_idle(120);
    check(exists("DCIM/100CANON/FLM_0101.JPG"), "FLM_0101.JPG written");
    { char b[1024]; snprintf(b, sizeof b, "%s/DCIM/100CANON/FLM_0101.JPG", g_card);
      check(same_file(b, expect), "FLM_0101.JPG is byte-identical to previewcheck's"); }
    check(g_powersave_held == 0, "power-off hold released after the frame (%d)", g_powersave_held);
    check(g_fio_peak <= FIO_POOL, "DMA memory peaked at %ld KB, pool %ld KB", g_fio_peak >> 10, FIO_POOL >> 10);

    /* 3. a burst: the counter jumps by three between ticks */
    { int i; for (i = 102; i <= 104; i++) { char d[1024]; char cmd[2200];
        snprintf(d, sizeof d, "%s/DCIM/100CANON/IMG_%04d.CR2", g_card, i);
        snprintf(cmd, sizeof cmd, "cp '%s' '%s'", sample, d); system(cmd); } }
    g_shoot_card.file_number = 104; lens_info.job_state = 0;
    tick(1);
    check(se_q_count() == 3, "burst of three queued (%d)", se_q_count());
    tick(2);
    wait_idle(300);
    check(exists("DCIM/100CANON/FLM_0102.JPG") && exists("DCIM/100CANON/FLM_0103.JPG") &&
          exists("DCIM/100CANON/FLM_0104.JPG"), "all three developed");

    /* 4. auto off: a shot is not queued, and not later either */
    se_auto = 0;
    shoot(105, 1, sample);
    tick(3);
    check(se_q_count() == 0 && !se_busy, "auto off: shot 105 not queued");
    se_auto = 1;
    tick(2);
    check(se_q_count() == 0 && !se_busy, "auto on again: 105 still not queued (counter was followed)");

    /* 5. a raw that never finishes */
    shoot(106, 1, NULL);
    tick(32);
    wait_idle(5);
    check(se_q_count() == 0, "a raw that never appears is given up (%d queued)", se_q_count());

    /* 6. the picker */
    { int k, before = se_stock_index;
      check(sim_cbr_key(MODULE_KEY_PRESS_SET) == 0, "SET in shooting mode opens the picker");
      sim_cbr_key(MODULE_KEY_PRESS_DOWN); sim_cbr_key(MODULE_KEY_PRESS_DOWN);
      sim_cbr_key(MODULE_KEY_PRESS_SET);
      check(se_stock_index == (before + 2) % se_nstocks, "DOWN DOWN SET picks the film two along (%d -> %d)", before, se_stock_index);
      check((int)se_name_id(se_stocks[se_stock_index].name) == se_stock_id, "and saves its name's hash");
      sim_cbr_key(MODULE_KEY_PRESS_SET);
      sim_cbr_key(MODULE_KEY_PRESS_UP); sim_cbr_key(MODULE_KEY_PRESS_UP); sim_cbr_key(MODULE_KEY_TRASH);
      check(se_stock_index == (before + 2) % se_nstocks, "TRASH cancels without changing the film");
      /* the picker opens on the current film; UP wraps past the top into
       * the two action rows, AUTO first and DEVELOP above it */
      sim_cbr_key(MODULE_KEY_PRESS_SET);
      for (k = 0; k < se_stock_index + 1; k++) sim_cbr_key(MODULE_KEY_PRESS_UP);
      { int a = se_auto; sim_cbr_key(MODULE_KEY_PRESS_SET);
        check(se_auto == !a, "the AUTO row flips auto develop (%d -> %d)", a, se_auto);
        check(sim_cbr_key(MODULE_KEY_PRESS_DOWN) == 0, "and the picker stayed open");
        sim_cbr_key(MODULE_KEY_TRASH); se_auto = 1; }
      sim_cbr_key(MODULE_KEY_PRESS_SET);
      check(sim_cbr_key(MODULE_KEY_PRESS_HALFSHUTTER) == 1, "half-shutter closes it and passes through");
      check(sim_cbr_key(MODULE_KEY_PRESS_DOWN) == 1, "closed: keys pass through again");
      sim_cbr_key(MODULE_KEY_PRESS_SET); tick(7);
      check(sim_cbr_key(MODULE_KEY_PRESS_DOWN) == 1, "six idle ticks close it");
      sim_cbr_key(MODULE_KEY_PRESS_SET);
      for (k = 0; k < se_stock_index + 2; k++) sim_cbr_key(MODULE_KEY_PRESS_UP);  /* the DEVELOP row */
      sim_cbr_key(MODULE_KEY_PRESS_SET);
      check(se_q_count() == 1 || se_busy, "DEVELOP LAST SHOT queues the newest raw");
      wait_idle(120);
      g_menu_shown = 1;
      check(sim_cbr_key(MODULE_KEY_PRESS_SET) == 1, "SET is left alone while Magic Lantern's menu is up");
      g_menu_shown = 0; lv = 1;
      check(sim_cbr_key(MODULE_KEY_PRESS_SET) == 1, "and in live view");
      lv = 0;
    }
    check(g_draw_errors == 0, "every draw stayed inside 720x480 (%d draws, %d outside)", g_draws, g_draw_errors);

    /* 7. power-off mid-frame */
    shoot(107, 1, sample);
    tick(3);
    { int t = 0; while (!se_busy && t < 30) { usleep(100000); t++; } }   /* the worker polls every 500 ms */
    check(se_busy, "a frame is in flight");
    ml_shutdown_requested = 1;
    { int t = 0; while (se_busy && t < 50) { usleep(100000); t++; }
      check(!se_busy, "the worker stopped within %d00 ms of shutdown", t); }
    check(!exists("DCIM/100CANON/FLM_0107.JPG"), "the partial FLM_0107.JPG was removed");
    pthread_join(g_worker, 0);
    check(g_powersave_held == 0, "power-off hold released on the way out (%d)", g_powersave_held);

    printf("sim700d: %d checks, %d failed\n", g_checks, g_fails);
    return g_fails ? 1 : 0;
}
