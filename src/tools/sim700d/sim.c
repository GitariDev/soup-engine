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
 *   6. the picker: SET is left alone; INFO on the shooting screen
 *      opens it, DOWN twice and SET picks the third film and saves its
 *      name's hash, the wheel moves it, INFO again closes it and goes
 *      on to Canon, TRASH cancels, DEVELOP LAST SHOT queues, the AUTO
 *      row flips and stays open, half-shutter closes and passes the key
 *      through, six idle ticks close it, and none of it happens in
 *      Magic Lantern's menu, live view, Canon's menu, a Canon dialog
 *      such as the Q screen, or with the display off; while it is open
 *      every named button is the picker's, with the releases of what it
 *      took, and Canon's own events pass -- delivered as Magic Lantern
 *      delivers them, the translated key first and then the raw event;
 *      and the progress text carries the count with no %% near it;
 *   7. the film screen, on a card with the pack: the palette goes in and
 *      comes back exactly, Canon is kept off the screen and let back on,
 *      its memory is returned, every key does what the sample does, each
 *      frame is written out for looking at (SE_SIM_DUMP=<dir>), and with no
 *      memory the plain list opens instead;
 *   8. the queue the screen shows: a frame keeps the film and size it was
 *      shot on, and a burst longer than the queue is not lost;
 *   9. the roll: what the module appended to ML/DATA/SOUPROLL.TXT is read
 *      back from the card, parsed, and held to what was shot;
 *  10. power-off mid-frame: the worker stops within a row, the partial
 *      file is gone, and the roll is not touched any more.
 *
 * Every fake is deliberately minimal and every check is a line of
 * output; the script greps for "FAIL". Exit status says the same.
 */
#define _GNU_SOURCE
#include <time.h>
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
extern int se_nstocks, se_stock_index, se_stock_id, se_auto, se_size, se_waiting;
extern int se_pct; extern const char *se_stage;
extern int se_progress_text(char *buf, size_t cap);
extern volatile int se_busy, se_q_head, se_q_tail;
extern int se_q_count(void), se_pending(void);
extern uint32_t se_name_id(const char *);
extern int se_ui_avail, se_ui_count(void), se_ui_stock(int), se_ui_pos(int);
extern volatile int se_ui_state, se_ui_quit;
typedef struct { char path[FIO_MAX_PATH_LENGTH]; uint32_t size; int stable, age, ready, force, stock, size_; } sim_job;
extern sim_job se_q[8];
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
struct sim_file { int fd, roll; };

/* The roll's way to the card, watched: the name it asked for, how often it
 * opened, and a switch for the card going bad (1 no open, 2 half a line). */
static char g_roll_name[64];
static int  g_roll_opens, g_roll_bad_card, g_mkdir_data;
struct fio_file { struct file_info fi; };
struct fio_dirent { DIR *d; };

struct sim_file *FIO_OpenFile(const char *name, unsigned mode)
{
    char b[1024]; const char *hp = host_path(name, b, sizeof b);
    const char *slash = strrchr(hp, '/');
    int writing = (mode & 3) == O_RDWR, roll = writing && strstr(name, "SOUPROLL") != 0, fd;
    struct sim_file *f;
    if (roll) {
        g_roll_opens++;
        snprintf(g_roll_name, sizeof g_roll_name, "%s", slash ? slash + 1 : hp);
        if (g_roll_bad_card == 1) return 0;
    }
    fd = open(hp, writing ? O_RDWR : O_RDONLY);
    if (fd < 0) return 0;
    f = calloc(1, sizeof *f); f->fd = fd; f->roll = roll; return f;
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
    char b[1024]; const char *hp = host_path(name, b, sizeof b);
    const char *slash = strrchr(hp, '/');
    struct sim_file *f; int fd;
    if (slash && strlen(slash + 1) > 12) return 0;      /* 8.3, as above */
    fd = open(hp, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return 0;
    f = calloc(1, sizeof *f); f->fd = fd; return f;
}
int FIO_ReadFile(struct sim_file *f, void *buf, size_t n)
{
    /* short reads: the card may return less than asked, and does */
    if (g_short_reads && n > 4096 && (rand() & 3) == 0) n = n / 2 + 1;
    return (int)read(f->fd, buf, n);
}
int FIO_WriteFile(struct sim_file *f, const void *buf, size_t n)
{
    if (f->roll && g_roll_bad_card == 2) n /= 2;
    return (int)write(f->fd, buf, n);
}
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
/* Everything the screen allocates has to come back, so count what is out.
 * A "no memory" switch for the path where the plain list has to take over. */
static int g_mem_out, g_mem_deny;
void *__mem_malloc(size_t n, unsigned flags, const char *file, unsigned line)
{
    if (g_mem_deny && n > 300 * 1024) return 0;
    if (n > 300 * 1024 && n != 1536 * 1024) __sync_fetch_and_add(&g_mem_out, 1);
    return malloc(n);
}
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
static int g_ms_fixed;                            /* set: the clock is look()'s, exact */
int get_ms_clock(void)
{
    struct timeval t;
    if (g_ms_fixed) return g_ms_fixed;
    gettimeofday(&t, 0); return (int)(t.tv_sec * 1000 + t.tv_usec / 1000);
}
static pthread_t g_ui_thread;
static void *thread_entry(void *arg) { void (*fn)(void *) = ((void **)arg)[0]; fn(((void **)arg)[1]); return 0; }
static pthread_t g_worker;
int task_create(const char *name, int prio, int stack, void (*entry)(void *), void *arg)
{
    void **pair = malloc(2 * sizeof(void *)); pair[0] = (void *)entry; pair[1] = arg;
    pthread_create(strcmp(name, "soup_dev") == 0 ? &g_worker : &g_ui_thread, 0, thread_entry, pair);
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
    if (font & FONT_ALIGN_RIGHT) x -= (int)strlen(s) * 10;    /* anchored on the right */
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
static int g_redraw_count;
void redraw(void) { g_redraw_count++; }
int gui_state;                                   /* 0: Canon idle */
static int g_gui_mode;                           /* 0: no Canon dialog */
int get_gui_mode(void) { return g_gui_mode; }
static int g_bracket;
int is_hdr_bracketing_enabled(void) { return g_bracket; }

void menu_add(const char *name, struct menu_entry *e, int count) {}
void menu_remove(const char *name, struct menu_entry *e, int count) {}
MENU_SELECT_FUNC(menu_open_submenu) {}

/* The bitmap layer: 960x540 in memory, with the visible 720x480 inside it,
 * and guard bytes around the whole so an overrun is seen. */
#define SIM_PAL_BASE 0xC0F14400u
#define SIM_GUARD    4096
static uint8_t  g_vram_mem[960 * 540 + 2 * SIM_GUARD];
static uint32_t g_pal[256], g_pal2[256], g_pal_orig[256];
uint32_t LCD_Palette[3 * 0x400];
static int g_front_off;
static void sim_pal_init(void)
{
    int i;
    memset(g_vram_mem, 0xA5, sizeof g_vram_mem);
    for (i = 0; i < 256; i++) {
        uint32_t v = i == 1 ? 0x03EB0000u : i == 2 ? 0x03100000u : 0x03400000u + (uint32_t)i;
        LCD_Palette[3 * i] = SIM_PAL_BASE + (uint32_t)i * 4;
        LCD_Palette[3 * i + 1] = 0;
        LCD_Palette[3 * i + 2] = v;
        LCD_Palette[3 * i + 0x300] = SIM_PAL_BASE + 0x400 + (uint32_t)i * 4;
        g_pal[i] = g_pal2[i] = g_pal_orig[i] = v;
    }
}
void EngDrvOut(uint32_t reg, uint32_t value)
{
    if (reg >= SIM_PAL_BASE + 0x400) g_pal2[(reg - SIM_PAL_BASE - 0x400) / 4] = value;
    else g_pal[(reg - SIM_PAL_BASE) / 4] = value;
}
uint32_t shamem_read(uint32_t addr) { return g_pal[(addr - SIM_PAL_BASE) / 4]; }
uint8_t *bmp_vram_real(void) { return g_vram_mem + SIM_GUARD + 30 * 960 + 120; }
const char *lens_format_aperture(int raw) { return "f/5.6"; }
const char *lens_format_shutter(int raw) { return "1/125"; }
const char *lens_format_iso(int raw) { return "400"; }
static int g_faked;
void fake_simple_button(int code) { g_faked = code; }
int FIO_CreateDirectory(const char *name)
{
    char b[1024]; host_path(name, b, sizeof b);
    if (strcmp(name, "ML/DATA") == 0) g_mkdir_data = 1;
    return mkdir(b, 0777);
}
static int g_idle_flag;
void bmp_draw_to_idle(int value) { g_idle_flag = value; }
void canon_gui_disable_front_buffer(void) { g_front_off = 1; }
void canon_gui_enable_front_buffer(int also_redraw) { g_front_off = 0; }
/* Field by field: the module's struct tm is shorter than this file's. */
static int g_rtc_reads, g_rtc_sec = 5;
void LoadCalendarFromRTC(struct tm *tm)
{
    tm->tm_year = 126; tm->tm_mon = 10; tm->tm_mday = 1;   /* 1 November 2026 */
    tm->tm_hour = 16; tm->tm_min = 47; tm->tm_sec = g_rtc_sec;
    g_rtc_reads++;
}

/* the screen as a viewer would see it, through the palette */
static void dump(const char *name)
{
    const char *dir = getenv("SE_SIM_DUMP");
    uint8_t *v = bmp_vram_real();
    char path[1024]; FILE *f; int x, y;
    if (!dir) return;
    snprintf(path, sizeof path, "%s/%s.ppm", dir, name);
    f = fopen(path, "wb"); if (!f) return;
    fprintf(f, "P6\n720 480\n255\n");
    for (y = 0; y < 480; y++) for (x = 0; x < 720; x++) {
        uint32_t p = g_pal[v[y * 960 + x]];
        int Y = (p >> 16) & 255, U = (int8_t)(p >> 8), V = (int8_t)p;
        int r = Y + (V * 1436 >> 10), g = Y - (U * 352 >> 10) - (V * 731 >> 10), b = Y + (U * 1814 >> 10);
        fputc(r < 0 ? 0 : r > 255 ? 255 : r, f); fputc(g < 0 ? 0 : g > 255 ? 255 : g, f); fputc(b < 0 ? 0 : b > 255 ? 255 : b, f);
    }
    fclose(f);
}

/* ------------------------------------------------------------ driver */
static void tick(int n) { while (n-- > 0) sim_cbr_clock(0); }

/*
 * One raw button event, delivered the way Magic Lantern's
 * handle_module_keys delivers it on the 700D: translated to a module key
 * (0 when there is no translation -- the arrow releases, the zoom-out
 * button, Canon's own notifications) for the key callback, and if that
 * lets it through, the raw event for the raw callback. 0 means taken.
 */
extern unsigned (*sim_cbr_raw)(se_ctx_t);
extern int se_pv_info(int no, char *film, size_t cap, int *size);
static int ev(int code)
{
    static const int xlat[][2] = {
        { BGMT_WHEEL_UP, MODULE_KEY_WHEEL_UP }, { BGMT_WHEEL_DOWN, MODULE_KEY_WHEEL_DOWN },
        { BGMT_PRESS_SET, MODULE_KEY_PRESS_SET }, { BGMT_UNPRESS_SET, MODULE_KEY_UNPRESS_SET },
        { BGMT_MENU, MODULE_KEY_MENU }, { BGMT_INFO, MODULE_KEY_INFO }, { BGMT_PLAY, MODULE_KEY_PLAY },
        { BGMT_TRASH, MODULE_KEY_TRASH }, { BGMT_LV, MODULE_KEY_REC }, { BGMT_PRESS_ZOOM_IN, MODULE_KEY_PRESS_ZOOMIN },
        { BGMT_PRESS_UP, MODULE_KEY_PRESS_UP }, { BGMT_PRESS_DOWN, MODULE_KEY_PRESS_DOWN },
        { BGMT_PRESS_LEFT, MODULE_KEY_PRESS_LEFT }, { BGMT_PRESS_RIGHT, MODULE_KEY_PRESS_RIGHT },
        { BGMT_PRESS_HALFSHUTTER, MODULE_KEY_PRESS_HALFSHUTTER },
        { BGMT_TOUCH_1_FINGER, MODULE_KEY_TOUCH_1_FINGER }, { BGMT_UNTOUCH_1_FINGER, MODULE_KEY_UNTOUCH_1_FINGER },
        { BGMT_TOUCH_2_FINGER, MODULE_KEY_TOUCH_2_FINGER }, { BGMT_UNTOUCH_2_FINGER, MODULE_KEY_UNTOUCH_2_FINGER },
        { BGMT_Q, MODULE_KEY_Q },
    };
    struct event e = { 0, code, 0, 0 };
    int i, key = 0;
    for (i = 0; i < (int)(sizeof xlat / sizeof xlat[0]); i++)
        if (xlat[i][0] == code) { key = xlat[i][1]; break; }
    if (sim_cbr_key(key) == 0) return 0;
    return sim_cbr_raw((se_ctx_t)&e);
}

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

/* ---------------------------------------------------------- the roll */
typedef struct {
    int roll, from_folder, from_no, to_folder, to_no, count, Y, M, D, h, mi, s, span;
    unsigned id;
    char film[32];
} sim_rec;

#define SIM_RECS 128
static sim_rec g_rec[SIM_RECS];
static int     g_rec_bad;                  /* lines that were not a whole record */

static long roll_size(void)
{
    char b[1024]; struct stat st;
    snprintf(b, sizeof b, "%s/ML/DATA/SOUPROLL.TXT", g_card);
    return stat(b, &st) == 0 ? (long)st.st_size : 0;
}

/* What was appended since `from`, parsed into g_rec: the number of records. */
static int roll_read(long from)
{
    char b[1024], line[256];
    FILE *f;
    int n = 0;
    g_rec_bad = 0;
    snprintf(b, sizeof b, "%s/ML/DATA/SOUPROLL.TXT", g_card);
    f = fopen(b, "rb");
    if (!f) return 0;
    fseek(f, from, SEEK_SET);
    while (fgets(line, sizeof line, f)) {
        sim_rec r; int len = (int)strlen(line), at = 0;
        memset(&r, 0, sizeof r);
        if (len < 2 || line[len - 1] != '\n' ||
            sscanf(line, "R1 %d %d %d %d %d %d %d %d %d %d %d %d %d %x %n", &r.roll, &r.from_folder, &r.from_no,
                   &r.to_folder, &r.to_no, &r.count, &r.Y, &r.M, &r.D, &r.h, &r.mi, &r.s, &r.span, &r.id, &at) != 14 ||
            !at || at >= len - 1 || len - 1 - at >= (int)sizeof r.film) { g_rec_bad++; continue; }
        memcpy(r.film, line + at, (size_t)(len - 1 - at));
        if (se_name_id(r.film) != r.id) { g_rec_bad++; continue; }
        if (n < SIM_RECS) g_rec[n] = r;
        n++;
    }
    fclose(f);
    return n;
}

/* a look, a second after the last one */
static void look(void) { g_ms_fixed += 1000; g_rtc_sec = (g_rtc_sec + 1) % 60; tick(1); }
static void counter(int folder, int number) { g_shoot_card.folder_number = folder; g_shoot_card.file_number = number; }
/* frames that will never appear: the queue gives each up after thirty looks */
static void drain(void) { int t = 0; while ((se_pending() || se_busy) && t++ < 3000) { tick(1); usleep(2000); } }

int main(int argc, char **argv)
{
    char sample[1024];
    const char *expect;
    long roll_start;
    if (argc < 3) { fprintf(stderr, "usage: sim700d <card dir> <expected FLM jpg>\n"); return 2; }
    snprintf(g_card, sizeof g_card, "%s", argv[1]);
    snprintf(g_dcim, sizeof g_dcim, "B:/DCIM/100CANON");
    snprintf(sample, sizeof sample, "%s/sample.CR2", g_card);
    expect = argv[2];
    if (getenv("SE_SIM_SHORT_READS")) g_short_reads = atoi(getenv("SE_SIM_SHORT_READS"));
    srand(1);
    sim_pal_init();

    printf("sim700d: card=%s short_reads=%s\n", g_card, g_short_reads ? "on" : "off");
    roll_start = roll_size();                              /* a second run shares the card */

    /* 1. init -- with a frame the power cut off last time: its raw is
     * there and its output is empty */
    { char cmd[2200], e[1100];
      snprintf(cmd, sizeof cmd, "cp '%s' '%s/DCIM/100CANON/IMG_0100.CR2'", sample, g_card); system(cmd);
      snprintf(e, sizeof e, "%s/DCIM/100CANON/FLM_0100.JPG", g_card); fclose(fopen(e, "wb")); }
    g_shoot_card.file_number = 100; g_shoot_card.folder_number = 100;
    se_size = 2;                                           /* quarter, as the reference */
    check(sim_module_init() == 0, "module init");
    check(se_nstocks == 13, "13 films found (%d)", se_nstocks);
    check(se_q_count() == 1, "the cut-off frame was queued at power-on (%d)", se_q_count());
    check(se_ui_avail == 1, "the pack on the card turns the film screen on");
    se_ui_avail = 0;                                       /* steps 2-6: the plain list */
    wait_idle(120);
    { char b[1024]; snprintf(b, sizeof b, "%s/DCIM/100CANON/FLM_0100.JPG", g_card);
      check(same_file(b, expect), "and developed, byte-identical"); }
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
    /* a desktop frame is a fifth of a second, so sample the count the
     * whole time the burst drains and keep the most it showed */
    { int maxw = 0, t = 0;
      while ((se_busy || se_q_count()) && t < 3000) { if (se_waiting > maxw) maxw = se_waiting; usleep(1000); t++; }
      check(maxw == 2, "the first frame showed two waiting behind it (most seen: %d)", maxw); }
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
      check(ev(BGMT_PRESS_SET) == 1 && ev(BGMT_UNPRESS_SET) == 1, "SET is left alone on the shooting screen");
      check(ev(BGMT_PRESS_DOWN) == 1, "and it opened nothing");
      check(ev(BGMT_INFO) == 0, "INFO on the shooting screen opens the picker");
      check(ev(BGMT_PRESS_DOWN) == 0, "which takes the arrows");
      ev(BGMT_PRESS_DOWN);
      check(ev(BGMT_PRESS_SET) == 0, "SET chooses");
      check(se_stock_index == (before + 2) % se_nstocks, "DOWN DOWN SET picks the film two along (%d -> %d)", before, se_stock_index);
      check((int)se_name_id(se_stocks[se_stock_index].name) == se_stock_id, "and saves its name's hash");
      check(ev(BGMT_UNPRESS_SET) == 0, "the release of a choosing press is taken with it");
      check(ev(BGMT_UNPRESS_SET) == 1, "a later SET release is Canon's");
      before = se_stock_index;
      ev(BGMT_INFO); ev(BGMT_WHEEL_DOWN); ev(BGMT_WHEEL_DOWN); ev(BGMT_WHEEL_DOWN); ev(BGMT_PRESS_SET); ev(BGMT_UNPRESS_SET);
      check(se_stock_index == (before + 3) % se_nstocks, "the wheel moves it: three clicks and SET (%d -> %d)", before, se_stock_index);
      ev(BGMT_INFO); ev(BGMT_PRESS_UP);
      check(ev(BGMT_INFO) == 1, "INFO while open closes the picker and passes on to Canon's next screen");
      check(se_stock_index == (before + 3) % se_nstocks, "without changing the film");
      check(ev(BGMT_PRESS_DOWN) == 1, "and it is closed");
      ev(BGMT_INFO); ev(BGMT_PRESS_UP); ev(BGMT_PRESS_UP);
      check(ev(BGMT_TRASH) == 0 && se_stock_index == (before + 3) % se_nstocks, "TRASH cancels without changing the film");
      /* the picker opens on the current film; UP wraps past the top into
       * the two action rows, AUTO first and DEVELOP above it */
      ev(BGMT_INFO);
      for (k = 0; k < se_stock_index + 1; k++) ev(BGMT_PRESS_UP);
      { int a = se_auto; ev(BGMT_PRESS_SET); ev(BGMT_UNPRESS_SET);
        check(se_auto == !a, "the AUTO row flips auto develop (%d -> %d)", a, se_auto);
        check(ev(BGMT_PRESS_DOWN) == 0, "and the picker stayed open");
        ev(BGMT_TRASH); se_auto = 1; }
      ev(BGMT_INFO);
      check(ev(BGMT_PRESS_HALFSHUTTER) == 1, "half-shutter closes it and passes through");
      check(ev(BGMT_PRESS_DOWN) == 1, "closed: keys pass through again");
      ev(BGMT_INFO); tick(7);
      check(ev(BGMT_PRESS_DOWN) == 1, "six idle ticks close it");
      ev(BGMT_INFO);
      for (k = 0; k < se_stock_index + 2; k++) ev(BGMT_PRESS_UP);  /* the DEVELOP row */
      ev(BGMT_PRESS_SET); ev(BGMT_UNPRESS_SET);
      check(se_q_count() == 1 || se_busy, "DEVELOP LAST SHOT queues the newest raw");
      { int before = se_q_tail;
        ev(BGMT_INFO);
        for (k = 0; k < se_stock_index + 2; k++) ev(BGMT_PRESS_UP);
        ev(BGMT_PRESS_SET); ev(BGMT_UNPRESS_SET);
        check(se_q_tail == before, "pressing it again does not queue the same frame twice"); }
      wait_idle(120);
      /* nowhere but the bare shooting screen */
      g_menu_shown = 1;
      check(ev(BGMT_INFO) == 1 && ev(BGMT_PRESS_SET) == 1 && ev(BGMT_UNPRESS_SET) == 1 && ev(BGMT_PRESS_DOWN) == 1,
            "INFO is left alone while Magic Lantern's menu is up, and SET with it");
      g_menu_shown = 0; lv = 1;
      check(ev(BGMT_INFO) == 1 && ev(BGMT_PRESS_SET) == 1 && ev(BGMT_UNPRESS_SET) == 1 && ev(BGMT_PRESS_DOWN) == 1, "and in live view");
      lv = 0; gui_state = 9;                      /* Canon's Q screen */
      check(ev(BGMT_INFO) == 1 && ev(BGMT_PRESS_SET) == 1 && ev(BGMT_UNPRESS_SET) == 1 && ev(BGMT_PRESS_DOWN) == 1,
            "and in Canon's Q screen, where SET is how Canon opens things");
      gui_state = 0; g_gui_mode = 2;              /* Canon's menu */
      check(ev(BGMT_INFO) == 1 && ev(BGMT_PRESS_SET) == 1 && ev(BGMT_UNPRESS_SET) == 1, "and in Canon's menu, where SET confirms");
      g_gui_mode = 0; g_display_on = 0;           /* the dark end of Canon's INFO cycle */
      check(ev(BGMT_INFO) == 1 && ev(BGMT_PRESS_SET) == 1 && ev(BGMT_UNPRESS_SET) == 1, "with the display off both are Canon's: INFO turns the display back on");
      g_display_on = 1;
      /* the bracket warning is drawn with the label */
      { int d = g_draws; g_bracket = 1; tick(1); g_bracket = 0;
        check(g_draws - d == 2, "the label warns when ML's Advanced Bracket is on (%d draws)", g_draws - d); }
      /* while it is open, nothing underneath: every named button is the
       * picker's, and the releases of what it took are taken too */
      { int idx = se_stock_index;
        ev(BGMT_INFO);
        check(ev(BGMT_PRESS_UP) == 0, "open: an arrow press is the picker's, not Canon's ISO");
        check(ev(BGMT_UNPRESS_UP) == 0, "and so is its release, which ML does not translate");
        check(ev(GMT_OLC_INFO_CHANGED) == 1, "Canon's own notifications pass");
        check(ev(BGMT_LV) == 0, "LV closes the picker and goes no further");
        check(ev(BGMT_UNPRESS_UP) == 1, "closed: an arrow release the picker did not take passes");
        check(ev(BGMT_LV) == 1, "closed: LV is Canon's again");
        ev(BGMT_INFO);
        check(ev(BGMT_PRESS_ZOOM_OUT) == 0, "AE lock, which ML does not translate, is taken while open and closes it");
        check(ev(BGMT_UNPRESS_ZOOM_OUT) == 0, "with its release");
        check(ev(BGMT_PRESS_ZOOM_OUT) == 1 && ev(BGMT_UNPRESS_ZOOM_OUT) == 1, "and passes once closed");
        ev(BGMT_INFO);
        check(ev(BGMT_PRESS_ZOOM_IN) == 0 && ev(BGMT_UNPRESS_ZOOM_IN) == 0, "AF point selection: press and release both taken");
        ev(BGMT_INFO);
        check(ev(BGMT_TOUCH_1_FINGER) == 0 && ev(BGMT_UNTOUCH_1_FINGER) == 0, "a touch: taken with its release");
        check(ev(BGMT_UNTOUCH_1_FINGER) == 1, "a later untouch passes");
        ev(BGMT_INFO);
        check(ev(BGMT_PRESS_HALFSHUTTER) == 1 && ev(BGMT_PRESS_DOWN) == 1, "the half-press is the exception: it closes and still fires");
        check(se_stock_index == idx, "none of that changed the film");
      }
      /* the progress text: the count is there, and no %% is anywhere near it */
      { char t[48]; se_stage = "stream"; se_pct = 45; se_waiting = 3;
        se_progress_text(t, sizeof t);
        check(strcmp(t, "stream 45%, 3 waiting") == 0, "progress text reads \"%s\"", t);
        se_waiting = 0; se_progress_text(t, sizeof t);
        check(strcmp(t, "stream 45%") == 0, "and with nothing queued, \"%s\"", t); }
    }
    check(g_draw_errors == 0, "every draw stayed inside 720x480 (%d draws, %d outside)", g_draws, g_draw_errors);

    /* 7. the film screen */
    {
      #define UI_WAIT(cond) do { int w_ = 0; while (!(cond) && w_ < 4000) { usleep(1000); w_++; } } while (0)
      #define UI_OPEN()  do { check(ev(BGMT_INFO) == 0, "INFO opens the film screen"); UI_WAIT(se_ui_state == 2); usleep(60000); } while (0)
      #define UI_CLOSED() UI_WAIT(se_ui_state == 0)
      #define UI_SHOT()  usleep(120000)
      int i, orig, redraws, name_was;
      const char *pos_name;
      char dname[32];
      extern int se_pick_sel;
      se_ui_avail = 1;
      se_auto = 1; se_size = 0;
      /* start from a known film, so the shelves below read the same each run */
      { int n; for (n = 0; n < se_nstocks; n++) if (strcmp(se_stocks[n].name, "ETERNA") == 0) se_stock_index = n; }
      orig = se_stock_index;
      UI_OPEN();
      check(g_front_off == 1, "Canon is kept off the screen");
      check(g_idle_flag == 1, "and Magic Lantern's overlay is pointed away from it");
      check(g_pal[100] != g_pal_orig[100], "the screen's palette is in");
      check(g_pal[100] == g_pal2[100], "in both banks");
      check(g_pal[1] == g_pal_orig[1] && g_pal[2] == g_pal_orig[2] && g_pal[0] == g_pal_orig[0] && g_pal[3] == g_pal_orig[3]
            && g_pal[4] == g_pal_orig[4] && g_pal[20] == g_pal_orig[20] && g_pal[255] == g_pal_orig[255],
            "white, black, the transparent entries, the zebra grid and ClearScreen are left alone");
      check(se_ui_count() == 13, "all 13 films are on it (%d)", se_ui_count());
      check(se_pick_sel == se_ui_pos(se_stock_index), "it opens on the film in the camera");
      check((g_pal[100] >> 24) == 3, "a palette entry is as opaque as Canon's white");
      dump("film0");
      /* walk the whole row, a frame of each */
      for (i = 0; i < 13; i++) {
        snprintf(dname, sizeof dname, "pos%02d", se_pick_sel); dump(dname);
        check(ev(BGMT_PRESS_RIGHT) == 0 && ev(BGMT_UNPRESS_RIGHT) == 0, "right is ours, press and release");
        UI_SHOT();
      }
      check(se_stock_index == orig, "moving along the row loads nothing");
      check(se_pick_sel == se_ui_pos(orig), "thirteen rights come back round");
      /* the shelves */
      { int s, want[4]; const char *names[4] = { "PORTRA", "PROVIA", "ACROS", "ETERNA" };
        for (s = 0; s < 4; s++) { int n; want[s] = -1; for (n = 0; n < se_nstocks; n++) if (strcmp(se_stocks[n].name, names[s]) == 0) want[s] = n; }
        ev(BGMT_PRESS_DOWN); ev(BGMT_UNPRESS_DOWN);       /* CINE wraps to COLOUR */
        check(se_ui_stock(se_pick_sel) == want[0], "down from CINE wraps to the first COLOUR film");
        ev(BGMT_PRESS_DOWN); ev(BGMT_UNPRESS_DOWN);
        check(se_ui_stock(se_pick_sel) == want[1], "down again is SLIDE");
        ev(BGMT_PRESS_DOWN); ev(BGMT_UNPRESS_DOWN);
        check(se_ui_stock(se_pick_sel) == want[2], "then B&W");
        ev(BGMT_PRESS_UP); ev(BGMT_UNPRESS_UP);
        check(se_ui_stock(se_pick_sel) == want[1], "up goes back"); }
      UI_SHOT();
      /* the toggles: left button, right button, no closing */
      { int a = se_auto;
        check(ev(BGMT_PLAY) == 0, "PLAY is ours, not Canon's playback");
        check(se_auto == !a, "and flips Auto develop");
        UI_SHOT(); dump("auto_off");
        ev(BGMT_PLAY);
        check(se_auto == a, "and back"); }
      { int seq[4], k, taken = 1; for (k = 0; k < 4; k++) { taken &= ev(BGMT_TRASH) == 0; seq[k] = se_size; }
        check(taken, "Trash is ours, not Magic Lantern's menu");
        check(seq[0] == 1 && seq[1] == 2 && seq[2] == 0 && seq[3] == 1, "and steps Quality: half, full, quarter, half (%d %d %d %d)", seq[0], seq[1], seq[2], seq[3]);
        ev(BGMT_TRASH); ev(BGMT_TRASH); }
      check(se_ui_state == 2, "neither toggle closed it");
      /* the buttons Canon keeps: anything they do send goes past untouched */
      check(ev(0x52) == 1, "an unnamed button event passes, and is logged");
      check(ev(GMT_OLC_INFO_CHANGED) == 1, "Canon's own notifications pass");
      /* Q: the last shot, with the screen still up */
      check(ev(BGMT_Q) == 0, "Q is ours");
      check(se_q_count() >= 1 || se_busy, "and queues the last shot");
      UI_SHOT(); dump("after_q");
      wait_idle(60);
      /* SET: the Loaded moment, then Canon */
      { int target = se_ui_stock(se_pick_sel); redraws = g_redraw_count;
        check(target != orig, "the row is on a different film");
        check(ev(BGMT_PRESS_SET) == 0, "SET is ours");
        check(se_stock_index == target, "SET loads the film");
        check((int)se_name_id(se_stocks[target].name) == se_stock_id, "and saves its name's hash");
        usleep(250000); dump("loaded");
        check(ev(BGMT_UNPRESS_SET) == 0, "its release is ours too");
        UI_CLOSED();
        check(se_ui_state == 0, "the Loaded moment ends by itself");
        check(g_redraw_count > redraws, "Canon is asked to paint its screen back"); }
      for (i = 0; i < 256; i++) if (g_pal[i] != g_pal_orig[i] || g_pal2[i] != g_pal_orig[i]) break;
      check(i == 256, "every palette entry is back as it was, both banks (first wrong: %d)", i);
      check(g_front_off == 0, "Canon has the screen again");
      check(g_idle_flag == 0, "and Magic Lantern draws on it again, or the label would vanish");
      check(g_mem_out == 2, "pack and frame were allocated once each (%d)", g_mem_out);
      /* every way out */
      { static const struct { int code, passes; const char *what; } out[] = {
          { BGMT_LV, 0, "LV" },
          { BGMT_INFO, 1, "INFO, on to Canon's next screen" },
          { BGMT_PRESS_HALFSHUTTER, 1, "the half-press, and it still fires" } };
        int k, film = se_stock_index;
        for (k = 0; k < 3; k++) {
          UI_OPEN();
          ev(BGMT_PRESS_LEFT); ev(BGMT_UNPRESS_LEFT);
          check(ev(out[k].code) == out[k].passes, "%s closes it", out[k].what);
          UI_CLOSED();
          check(se_ui_state == 0 && !g_front_off, "and the screen is Canon's");
          check(se_stock_index == film, "and the film has not changed");
        } }
      /* the keys of an arrow pressed while open but released after */
      UI_OPEN(); ev(BGMT_PRESS_RIGHT); ev(BGMT_PRESS_HALFSHUTTER); UI_CLOSED();
      check(ev(BGMT_UNPRESS_RIGHT) == 0, "the release of a press it took is taken even after it closed");
      check(ev(BGMT_UNPRESS_RIGHT) == 1, "and only that one");
      /* it opens nowhere else, and leaves when the screen changes under it */
      lv = 1; check(ev(BGMT_INFO) == 1, "not in live view"); lv = 0;
      UI_OPEN(); g_gui_mode = 2; tick(1); UI_CLOSED();
      check(se_ui_state == 0, "a dialog of Canon's behind it closes it, front buffer back on"); g_gui_mode = 0;
      UI_OPEN(); g_display_on = 0; tick(1); UI_CLOSED();
      check(se_ui_state == 0, "and so does the display going off"); g_display_on = 1;
      UI_OPEN(); tick(21); UI_CLOSED();
      check(se_ui_state == 0, "twenty idle seconds close it");
      /* a palette Canon reloaded goes back in */
      UI_OPEN();
      { int w = 0; g_pal[100] = g_pal_orig[100]; while (g_pal[100] == g_pal_orig[100] && w < 1500) { usleep(1000); w++; }
        check(g_pal[100] != g_pal_orig[100], "a palette Canon reloaded is put back within a second or so (%d ms)", w); }
      /* something drew on the layer */
      { uint8_t *v = bmp_vram_real(), was = v[100 * 960 + 100]; int w = 0;
        v[100 * 960 + 100] = 0x55; while (v[100 * 960 + 100] == 0x55 && w < 600) { usleep(1000); w++; }
        check(v[100 * 960 + 100] == was, "a scribble on the layer is painted over (%d ms)", w); }
      ev(BGMT_LV); UI_CLOSED();
      /* a film the pack has never heard of */
      name_was = 0;
      { se_stock *s = &se_stocks[0]; char keep[32]; memcpy(keep, s->name, sizeof keep);
        snprintf(s->name, sizeof s->name, "HOME BREW 1"); se_stock_index = 0;
        UI_OPEN();
        { int w = 0; g_idle_flag = 0; while (!g_idle_flag && w < 200) { usleep(1000); w++; }
          check(g_idle_flag == 1, "something else clearing the back-buffer switch is undone (%d ms)", w); }
        check(se_ui_pos(0) == 12, "a film not in the pack goes on the end of the row (%d)", se_ui_pos(0));
        dump("unknown"); ev(BGMT_LV); UI_CLOSED();
        memcpy(s->name, keep, sizeof keep); name_was = 1; }
      check(name_was, "and has a can");
      /* no memory: the plain list, not nothing */
      g_mem_deny = 1;
      check(ev(BGMT_INFO) == 0, "INFO with no memory for the pack");
      UI_WAIT(se_ui_state == 0);
      check(ev(BGMT_PRESS_DOWN) == 0 && ev(BGMT_UNPRESS_DOWN) == 0, "the plain list took over");
      ev(BGMT_TRASH);
      g_mem_deny = 0;
      /* a half-press before it has even loaded */
      check(ev(BGMT_INFO) == 0 && ev(BGMT_PRESS_HALFSHUTTER) == 1, "a half-press while it opens still fires");
      UI_CLOSED();
      check(se_ui_state == 0 && !g_front_off, "and it never takes the screen");
      /* the pages behind Home */
      {
        extern int se_home_sel, se_dark_sel, se_print_sel, se_sys_sel, se_roll_on, se_roll_no, se_roll_shot, se_ui_colour, se_ui_idle, se_nprints, se_nraws;
        extern unsigned short se_prints[];
        #define KEY(k) do { ev(k); usleep(100000); } while (0)
        char cmd[2400], a[1024]; uint32_t art100; int film, no, np;
        snprintf(lens_info.name, sizeof lens_info.name, "EF-S 18-135mm f/3.5-5.6 IS STM"); lens_info.focal_len = 35;
        snprintf(cmd, sizeof cmd, "cp '%s' '%s/DCIM/100CANON/IMG_0300.CR2'", sample, g_card); system(cmd);
        se_size = 2; se_auto = 1;
        UI_OPEN();
        art100 = g_pal[100];
        check(ev(BGMT_MENU) == 0, "MENU on the film screen is ours");
        usleep(150000);
        check(se_ui_state == 2, "and opens Home, not Canon");
        dump("home");
        /* the Darkroom: the raw with no print is on the list */
        se_home_sel = 1; KEY(BGMT_PRESS_SET); KEY(BGMT_UNPRESS_SET);
        check(se_nraws >= 1, "the walk finds raws with no print (%d)", se_nraws);
        dump("darkroom");
        { int i, found = -1; extern int se_ui_dark_raw(int), se_ui_dark_count(void);
          for (i = 0; i < se_ui_dark_count(); i++) if (se_ui_dark_raw(i) == 300) found = i;
          check(found >= 0, "IMG_0300 is on the Darkroom's list");
          se_dark_sel = found; KEY(BGMT_PRESS_SET); KEY(BGMT_UNPRESS_SET); }
        /* the worker empties the queue a moment before it says it is busy */
        { int w = 0; while (!se_q_count() && !se_busy && !exists("DCIM/100CANON/FLM_0300.JPG") && w++ < 200) usleep(1000);
          check(w < 200, "SET queues it"); }
        dump("darkroom_busy");
        wait_idle(60); usleep(200000);
        check(exists("DCIM/100CANON/FLM_0300.JPG"), "and it develops");
        check(exists("ML/PRINTS/FLM_0300.SPV"), "with a preview saved as it did");
        { struct stat st; char b[1024]; snprintf(b, sizeof b, "%s/ML/PRINTS/FLM_0300.SPV", g_card);
          check(stat(b, &st) == 0 && st.st_size == 64 + 216 * 144 + 648 * 432, "of the right size (%lld)", (long long)st.st_size); }
        /* Prints: the cube goes in */
        KEY(BGMT_MENU); se_home_sel = 2; KEY(BGMT_PRESS_SET); KEY(BGMT_UNPRESS_SET);
        usleep(200000);
        check(g_pal[100] != art100, "Prints loads the photo palette");
        check(se_nprints >= 2, "and finds the prints (%d)", se_nprints);
        check(se_prints[0] == 300, "newest first (%d)", se_prints[0]);
        dump("prints");
        /* an old print, no preview: the worker makes one */
        snprintf(a, sizeof a, "%s/ML/PRINTS/FLM_%04d.SPV", g_card, se_prints[1]); unlink(a);
        KEY(BGMT_PRESS_RIGHT); KEY(BGMT_UNPRESS_RIGHT);
        check(se_print_sel == 1, "right moves along the prints");
        KEY(BGMT_PRESS_SET); KEY(BGMT_UNPRESS_SET);
        { int w = 0; while (access(a, 0) != 0 && w < 5000) { usleep(1000); w++; }
          check(access(a, 0) == 0, "a print with no preview gets one from the worker (%d ms)", w); }
        usleep(300000);
        /* a card from the build with the ordered dither: it must not show */
        { FILE *h = fopen(a, "r+b"); char fl[32]; int z;
          fwrite("SPV1", 1, 4, h); fclose(h);
          check(se_pv_info(se_prints[se_print_sel], fl, sizeof fl, &z) != 0, "a preview in the old format is not used");
          h = fopen(a, "r+b"); fwrite("SPV2", 1, 4, h); fclose(h);
          check(se_pv_info(se_prints[se_print_sel], fl, sizeof fl, &z) == 0, "and this one is"); }
        dump("viewer");
        no = se_prints[se_print_sel]; np = se_nprints;
        KEY(BGMT_PRESS_LEFT); KEY(BGMT_UNPRESS_LEFT);
        check(se_print_sel == 0, "left flips to the next print"); usleep(200000);
        KEY(BGMT_PRESS_RIGHT); KEY(BGMT_UNPRESS_RIGHT); usleep(200000);
        ev(BGMT_TRASH); usleep(120000); dump("sheet");
        KEY(BGMT_MENU);
        snprintf(cmd, sizeof cmd, "DCIM/100CANON/FLM_%04d.JPG", no);
        check(exists(cmd), "Trash asks first, and MENU keeps the print");
        ev(BGMT_TRASH); usleep(50000); KEY(BGMT_PRESS_SET); KEY(BGMT_UNPRESS_SET); usleep(150000);
        check(!exists(cmd), "SET deletes it");
        check(access(a, 0) != 0, "and its preview");
        snprintf(cmd, sizeof cmd, "DCIM/100CANON/IMG_%04d.CR2", no);
        check(exists(cmd), "the raw stays");
        check(se_nprints == np - 1, "and the list shrinks");
        /* back out: the art palette returns */
        KEY(BGMT_MENU); KEY(BGMT_MENU); usleep(150000);
        check(g_pal[100] == art100, "leaving Prints puts the art palette back");
        /* Roll: no size, a new film starts a new one */
        se_home_sel = 3; se_roll_on = 0; KEY(BGMT_PRESS_SET); KEY(BGMT_UNPRESS_SET);
        check(se_roll_on == 1 && se_ui_state == 2, "SET on Roll switches it on and stays");
        dump("home_roll");
        /* Lens, System */
        se_home_sel = 4; KEY(BGMT_PRESS_SET); KEY(BGMT_UNPRESS_SET); dump("lens"); KEY(BGMT_MENU);
        se_home_sel = 5; KEY(BGMT_PRESS_SET); KEY(BGMT_UNPRESS_SET); dump("system");
        se_sys_sel = 0; { int c = se_ui_colour; KEY(BGMT_PRESS_SET); KEY(BGMT_UNPRESS_SET); usleep(100000);
          check(se_ui_colour == (c + 1) % 3, "SET on Screen colour steps it"); dump("system_ember");
          se_ui_colour = c; }
        se_sys_sel = 1; { int t = se_ui_idle; KEY(BGMT_PRESS_SET); KEY(BGMT_UNPRESS_SET); check(se_ui_idle != t, "Closes after steps"); se_ui_idle = 20; }
        se_sys_sel = 3; KEY(BGMT_PRESS_SET); KEY(BGMT_UNPRESS_SET); UI_CLOSED();
        check(se_ui_state == 0 && g_faked == BGMT_MENU, "Canon menu closes this and presses MENU");
        /* MENU on Home closes */
        UI_OPEN(); KEY(BGMT_MENU); KEY(BGMT_MENU); UI_CLOSED();
        check(se_ui_state == 0, "MENU on Home closes");
        for (film = 0; film < 256; film++) if (g_pal[film] != g_pal_orig[film]) break;
        check(film == 256, "the palette is Canon's again after all of that (%d)", film);
        /* a roll: runs past 36 and starts again on a new film */
        se_auto = 0; se_roll_shot = 40; g_shoot_card.file_number += 2; tick(1); se_auto = 1;
        check(se_roll_shot == 42, "shots count past 36 (%d)", se_roll_shot);
        { int n = se_roll_no; UI_OPEN(); KEY(BGMT_PRESS_RIGHT); KEY(BGMT_UNPRESS_RIGHT); ev(BGMT_PRESS_SET); ev(BGMT_UNPRESS_SET); UI_CLOSED();
          check(se_roll_no == n + 1 && se_roll_shot == 0, "a new film starts a new roll"); }
        se_roll_on = 0; wait_idle(30);
      }
      /* power-off with it open */
      check(g_vram_mem[SIM_GUARD - 1] == 0xA5 && g_vram_mem[sizeof g_vram_mem - SIM_GUARD] == 0xA5, "nothing wrote outside the layer");
      se_ui_avail = 0;
      pos_name = 0; (void)pos_name;
    }

    /* 8. the queue behind the counter */
    {
      int i, film_a = 3, film_b = 5; char cmd[2400];
      se_auto = 1; se_size = 2; se_stock_index = film_a;
      wait_idle(60);
      g_shoot_card.file_number = 200; tick(1);
      /* a frame keeps what it was shot on */
      shoot(201, 1, sample);
      check(se_q_count() == 1, "a frame queued");
      check(se_q[(se_q_tail - 1) % 8].stock == film_a && se_q[(se_q_tail - 1) % 8].size_ == 2, "with the film and size it was shot on");
      se_stock_index = film_b; se_size = 0;
      check(se_q[(se_q_tail - 1) % 8].stock == film_a, "changing the film does not change the frame");
      tick(3); wait_idle(60);
      { char b[1024]; snprintf(b, sizeof b, "%s/DCIM/100CANON/FLM_0201.JPG", g_card);
        struct stat st; check(stat(b, &st) == 0 && st.st_size > 0, "and it develops");
      }
      se_stock_index = film_a; se_size = 2;
      /* a burst longer than the queue */
      for (i = 202; i <= 213; i++) { snprintf(cmd, sizeof cmd, "cp '%s' '%s/DCIM/100CANON/IMG_%04d.CR2'", sample, g_card, i); system(cmd); }
      g_shoot_card.file_number = 213; lens_info.job_state = 0;
      tick(1);
      check(se_q_count() == 8, "a burst of twelve fills the queue (%d)", se_q_count());
      check(se_pending() == 12, "and the counter says twelve (%d)", se_pending());
      { int t = 0; while ((se_pending() || se_busy) && t < 40000) { tick(1); usleep(50000); t += 50; } }
      for (i = 202; i <= 213; i++) { char n[64]; snprintf(n, sizeof n, "DCIM/100CANON/FLM_%04d.JPG", i);
        if (!exists(n)) break; }
      check(i == 214, "and all twelve develop (first missing: %d)", i);
      /* a counter that jumped is not a burst */
      g_shoot_card.file_number = 7000; tick(1);
      check(se_q_count() == 0 && se_pending() == 0, "a counter that jumped queues nothing");
      g_shoot_card.file_number = 106; tick(1);
      check(se_pending() == 0, "nor one that went backwards");
    }

    /* 9. the roll */
    {
      extern int se_roll_on, se_roll_no, se_roll_shot;
      extern void se_log_flush(void);
      const char *dot;
      long mark, torn;
      int n, reads, opens, base, shots, stocks = se_nstocks, film_a = 3, film_b = 5;

      #define ROLL_FROM(m) do { n = roll_read(m); check(g_rec_bad == 0, "every line appended is a whole record"); } while (0)
      #define FILM_IS(i, st) (strcmp(g_rec[i].film, se_stocks[st].name) == 0 && g_rec[i].id == se_name_id(se_stocks[st].name))

      /* the frame on the card at power-on was the baseline, not a shot */
      ROLL_FROM(roll_start);
      check(n >= 1 && g_rec[0].from_no == 101 && g_rec[0].to_no == 101 && g_rec[0].count == 1,
            "the first look was the baseline: the first line is frame 101 (%d %d)", g_rec[0].from_no, g_rec[0].to_no);

      wait_idle(60); se_auto = 0; se_stock_index = film_a; g_ms_fixed = 1000;
      counter(100, 500); look();

      /* the name, and that it holds on the card */
      check(exists("ML/DATA/SOUPROLL.TXT"), "the roll is at ML/DATA/SOUPROLL.TXT");
      check(g_mkdir_data, "and init makes sure of ML/DATA");
      dot = strchr(g_roll_name, '.');
      { const char *c; int upper = 1;
        for (c = g_roll_name; *c; c++) if ((*c >= 'a' && *c <= 'z') || *c == ' ') upper = 0;
        check(dot && dot - g_roll_name >= 1 && dot - g_roll_name <= 8 && strlen(dot + 1) <= 3 && strchr(dot + 1, '.') == 0 && upper,
              "%s is an 8.3 name", g_roll_name); }

      /* an ordinary look costs nothing */
      mark = roll_size(); reads = g_rtc_reads; opens = g_roll_opens;
      look(); look(); look();
      check(roll_size() == mark && g_roll_opens == opens, "a look with no frame writes nothing");
      check(g_rtc_reads == reads, "and does not ask the RTC (%d)", g_rtc_reads - reads);

      /* a single shot, every field */
      counter(100, 501); look();
      ROLL_FROM(mark);
      check(n == 1, "a single shot is one line (%d)", n);
      check(g_rec[0].roll == 0 && g_rec[0].from_folder == 100 && g_rec[0].from_no == 501 && g_rec[0].to_folder == 100 &&
            g_rec[0].to_no == 501 && g_rec[0].count == 1, "with the right frame, roll 0 with the roll off");
      check(g_rec[0].Y == 2026 && g_rec[0].M == 11 && g_rec[0].D == 1 && g_rec[0].h == 16 && g_rec[0].mi == 47 && g_rec[0].s == g_rtc_sec,
            "and the clock: %d-%d-%d %d:%d:%d", g_rec[0].Y, g_rec[0].M, g_rec[0].D, g_rec[0].h, g_rec[0].mi, g_rec[0].s);
      check(g_rec[0].span == 1, "span is the one look (%d)", g_rec[0].span);
      check(FILM_IS(0, film_a), "and the film, %s, by name and by hash", g_rec[0].film);

      /* auto on and off, the roll on */
      mark = roll_size(); se_auto = 1; se_roll_on = 1; se_roll_no = 7; shots = se_roll_shot;
      counter(100, 502); look();
      ROLL_FROM(mark);
      check(n == 1 && g_rec[0].from_no == 502 && g_rec[0].roll == 7, "auto on: one line, on roll 7");
      check(se_q_count() == 1 && se_roll_shot == shots + 1, "and the queue and the roll's count go on as before");
      drain();
      mark = roll_size(); se_auto = 0;
      counter(100, 503); look();
      ROLL_FROM(mark);
      check(n == 1 && g_rec[0].from_no == 503 && g_rec[0].roll == 7 && se_q_count() == 0, "auto off: one line, nothing queued");
      se_roll_on = 0; se_roll_shot = shots; se_auto = 1;

      /* over SE_BURST, which the queue will not touch */
      mark = roll_size();
      counter(100, 573); look();
      ROLL_FROM(mark);
      check(n == 1 && g_rec[0].count == 70 && g_rec[0].from_no == 504 && g_rec[0].to_no == 573,
            "a burst of 70 in one look is one line, count 70 (%d)", g_rec[0].count);
      check(se_q_count() == 0, "and is still not the queue's");

      /* the queue full: its own counter lags and the roll's does not */
      mark = roll_size();
      counter(100, 585); look();
      check(se_q_count() == 8 && se_pending() == 12, "a burst of twelve leaves the queue behind the counter (%d of %d)", se_q_count(), se_pending());
      look(); look();
      check(se_pending() == 12, "and still behind it, looks later (%d)", se_pending());
      drain();
      ROLL_FROM(mark);
      check(n == 1 && g_rec[0].count == 12 && g_rec[0].from_no == 574 && g_rec[0].to_no == 585,
            "and it is counted once: %d line, count %d", n, g_rec[0].count);
      se_auto = 0;

      /* a folder change inside a range */
      mark = roll_size(); lens_info.job_state = 8;
      counter(100, 586); look();
      counter(101, 587); look();
      base = g_rtc_sec;
      lens_info.job_state = 0; look();
      ROLL_FROM(mark);
      check(n == 1 && g_rec[0].from_folder == 100 && g_rec[0].from_no == 586 && g_rec[0].to_folder == 101 &&
            g_rec[0].to_no == 587 && g_rec[0].count == 2, "a folder change mid-range: folder %d to %d, one line", g_rec[0].from_folder, g_rec[0].to_folder);
      check(g_rec[0].span == 2 && g_rec[0].s == base, "dated at the look that saw the last frame, not the write (span %d, :%d)", g_rec[0].span, g_rec[0].s);
      /* a new folder on its own is not a frame */
      mark = roll_size();
      counter(102, 587); look();
      check(roll_size() == mark, "a folder change with no frame writes nothing");
      counter(102, 588); look();
      ROLL_FROM(mark);
      check(n == 1 && g_rec[0].from_folder == 102 && g_rec[0].from_no == 588, "and the next frame is in the new one");

      /* the wrap */
      counter(102, 9999); look();
      mark = roll_size();
      counter(103, 1); look();
      ROLL_FROM(mark);
      check(n == 1 && g_rec[0].from_folder == 103 && g_rec[0].from_no == 1 && g_rec[0].to_folder == 103 && g_rec[0].to_no == 1 && g_rec[0].count == 1,
            "9999 to 1: one frame, number 1, in the new folder");
      counter(103, 9998); look();
      mark = roll_size();
      counter(104, 2); look();
      ROLL_FROM(mark);
      check(n == 1 && g_rec[0].from_folder == 103 && g_rec[0].from_no == 9999 && g_rec[0].to_folder == 104 && g_rec[0].to_no == 2 && g_rec[0].count == 3,
            "a burst through the wrap: 9999 to 2, three frames (%d)", g_rec[0].count);

      /* a film change: between shots, and with Canon still busy */
      counter(100, 600); look();
      mark = roll_size();
      counter(100, 601); look();
      se_stock_index = film_b;
      counter(100, 602); look();
      ROLL_FROM(mark);
      check(n == 2 && g_rec[0].to_no == 601 && FILM_IS(0, film_a) && g_rec[1].to_no == 602 && FILM_IS(1, film_b),
            "a film change between shots is two lines, each on its film (%s, %s)", g_rec[0].film, g_rec[1].film);
      mark = roll_size(); lens_info.job_state = 8; se_roll_on = 1;
      counter(100, 603); look();
      se_stock_index = film_a; se_roll_no = 8;             /* a new film starts a new roll */
      check(roll_size() == mark, "the change alone writes nothing yet");
      counter(100, 604); look();
      ROLL_FROM(mark);
      check(n == 1 && g_rec[0].to_no == 603 && FILM_IS(0, film_b) && g_rec[0].roll == 7,
            "a shot on the new film sends out the old range even with Canon busy, on its own film and roll");
      lens_info.job_state = 0; look();
      ROLL_FROM(mark);
      check(n == 2 && g_rec[1].from_no == 604 && FILM_IS(1, film_a) && g_rec[1].roll == 8, "and the new range follows when Canon is idle");
      se_roll_on = 0; se_roll_no = 7;
      /* the film moved on, no frame came: the line still says what it was shot on */
      mark = roll_size(); lens_info.job_state = 8;
      counter(100, 605); look();
      se_stock_index = film_b; look();
      lens_info.job_state = 0; look();
      ROLL_FROM(mark);
      check(n == 1 && FILM_IS(0, film_a), "a range keeps its film when the choice moves before it is written");
      se_stock_index = film_a;

      /* the five-look limit: L0 opens, L1-L4 hold, L5 writes */
      mark = roll_size(); lens_info.job_state = 8;
      counter(100, 606); look();
      check(roll_size() == mark, "Canon busy: the look that opens a range writes nothing");
      { int i, held = 1; for (i = 1; i <= 4; i++) {
          if (i == 2) counter(100, 607);
          look();
          if (i == 2) base = g_rtc_sec;
          if (roll_size() != mark) held = 0; }
        check(held, "nor do the next four, one of which adds a frame"); }
      look();
      ROLL_FROM(mark);
      check(n == 1 && g_rec[0].from_no == 606 && g_rec[0].to_no == 607 && g_rec[0].count == 2, "the fifth look after it writes, Canon still busy (%d line)", n);
      check(g_rec[0].s == base && g_rec[0].span == 3, "dated at the frame's look, three looks long (:%d, span %d)", g_rec[0].s, g_rec[0].span);
      mark = roll_size(); look(); look();
      check(roll_size() == mark, "and once only");
      lens_info.job_state = 0; look();
      check(roll_size() == mark, "and Canon going idle adds nothing");

      /* no films */
      mark = roll_size(); se_nstocks = 0;
      counter(100, 610); look();
      check(roll_size() == mark, "no films: nothing is written");
      se_nstocks = stocks; look();
      check(roll_size() == mark, "and those frames are not news when films arrive");
      counter(100, 611); look();
      ROLL_FROM(mark);
      check(n == 1 && g_rec[0].from_no == 611 && g_rec[0].count == 1, "the next frame is the next line");

      /* a card that will not take it */
      { char b[1024]; FILE *h; char *log; long at; int said = 0;
        snprintf(b, sizeof b, "%s/ML/LOGS/SOUPENG.LOG", g_card);
        se_log_flush();
        h = fopen(b, "rb"); fseek(h, 0, SEEK_END); at = ftell(h); fclose(h);
        mark = roll_size(); opens = g_roll_opens; g_roll_bad_card = 1;
        counter(100, 612); look(); look();
        check(g_roll_opens == opens + 2 && roll_size() == mark, "a refused open keeps the range and tries at the next look");
        check(exists("ML/DATA/SOUPROLL.TXT") && roll_size() == mark, "and has not cost the roll what it already holds");
        counter(100, 613); look();
        check(roll_size() == mark, "the card still refusing, the range grows");
        g_roll_bad_card = 0;
        counter(100, 614); look();
        ROLL_FROM(mark);
        check(n == 1 && g_rec[0].from_no == 612 && g_rec[0].to_no == 614 && g_rec[0].count == 3, "and the card back, nothing was lost");

        /* a film change with the card refusing cannot wait: the old range goes */
        mark = roll_size(); g_roll_bad_card = 1; se_stock_index = film_a;
        counter(100, 620); look();
        se_stock_index = film_b;
        counter(100, 621); look();
        g_roll_bad_card = 0;
        look();
        ROLL_FROM(mark);
        check(n == 1 && g_rec[0].from_no == 621 && g_rec[0].count == 1, "a change of film drops the old range, it never gives it the new film");

        /* not during a develop */
        mark = roll_size(); se_busy = 1;
        counter(100, 622); look(); look(); look(); look(); look(); look(); look();
        check(roll_size() == mark, "nothing goes to the card while a frame develops, past the five-look limit too");
        se_stock_index = film_a;
        counter(100, 623); look();
        ROLL_FROM(mark);
        check(n == 1 && g_rec[0].to_no == 622, "except that a change of film cannot hold the old range");
        mark = roll_size();
        se_busy = 0; look();
        ROLL_FROM(mark);
        check(n == 1 && g_rec[0].from_no == 623, "and the frame ending lets the rest out");

        mark = roll_size(); g_roll_bad_card = 2;
        counter(100, 625); look();
        torn = roll_size();
        g_roll_bad_card = 0;
        check(torn > mark, "a short write leaves part of a line");
        counter(100, 626); look();
        { char c = 0; snprintf(b, sizeof b, "%s/ML/DATA/SOUPROLL.TXT", g_card);
          h = fopen(b, "rb"); fseek(h, torn, SEEK_SET); fread(&c, 1, 1, h); fclose(h);
          check(c == '\n', "the next line closes it first"); }
        ROLL_FROM(torn + 1);
        check(n == 1 && g_rec[0].from_no == 626, "and arrives whole");
        snprintf(b, sizeof b, "%s/ML/LOGS/SOUPENG.LOG", g_card);
        se_log_flush();
        h = fopen(b, "rb"); fseek(h, at, SEEK_SET);
        log = calloc(1, 4097); fread(log, 1, 4096, h); fclose(h);
        { char *p = log; while ((p = strstr(p, "cannot open ML/DATA/SOUPROLL.TXT"))) { said++; p++; } }
        free(log);
        check(said == 1, "all of that is one line in the log (%d)", said); }

      /* a counter that was reset: the last thing here, it leaves 106 for below */
      counter(100, 7000); look();
      mark = roll_size();
      counter(100, 106); look();
      ROLL_FROM(mark);
      check(n == 1 && g_rec[0].count == 3105 && g_rec[0].from_no == 7001 && g_rec[0].to_no == 106,
            "a reset counter, 7000 to 106, is one line that matches nothing (count %d)", g_rec[0].count);
      se_auto = 1; se_stock_index = film_a;
    }

    /* 10. power-off mid-frame */
    shoot(107, 1, sample);
    tick(3);
    /* the worker polls every 500 ms and a desktop frame can be over in a
     * tenth of a second: look often, or this misses it */
    { int t = 0; while (!se_busy && t < 3000000) { usleep(1); t++; } }
    check(se_busy, "a frame is in flight");
    ml_shutdown_requested = 1;
    { int t = 0; while (se_busy && t < 50) { usleep(100000); t++; }
      check(!se_busy, "the worker stopped within %d00 ms of shutdown", t); }
    check(!exists("DCIM/100CANON/FLM_0107.JPG"), "the partial FLM_0107.JPG was removed");
    pthread_join(g_worker, 0);
    pthread_join(g_ui_thread, 0);
    check(g_powersave_held == 0, "power-off hold released on the way out (%d)", g_powersave_held);

    /* the card is left alone from here, frames or no frames */
    { long was = roll_size(); int opens = g_roll_opens;
      se_auto = 0; lens_info.job_state = 0;
      g_shoot_card.file_number = 108; tick(1); tick(6);
      check(roll_size() == was && g_roll_opens == opens, "after shutdown the roll is not opened, let alone written");
      /* the whole run: the one torn line above, and nothing else out of shape */
      { char b[1024]; FILE *h; char c = 0; int n = roll_read(roll_start);
        check(n > 30 && g_rec_bad == 1, "the run's %d lines all parse, but for the one cut on purpose (%d)", n, g_rec_bad);
        snprintf(b, sizeof b, "%s/ML/DATA/SOUPROLL.TXT", g_card);
        h = fopen(b, "rb"); fseek(h, -1, SEEK_END); fread(&c, 1, 1, h); fclose(h);
        check(c == '\n', "and the file ends in a newline"); } }

    printf("sim700d: %d checks, %d failed\n", g_checks, g_fails);
    return g_fails ? 1 : 0;
}
