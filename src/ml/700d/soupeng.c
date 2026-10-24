/*
 * soupeng.c - Soup Engine as a Magic Lantern module, for the EOS 700D.
 *
 * The 5D Classic build (ml/payload/) patches itself into Magic Lantern's
 * binary and calls Canon's ROM by absolute address, because that body's
 * Magic Lantern port has no module loader. This one does: it loads .mo
 * files off the card at boot and resolves what they import against its
 * own symbol table. So this is an ordinary module, and everything it
 * needs from the camera -- files, memory, tasks, the menu, the screen --
 * is asked of Magic Lantern rather than taken from the firmware.
 *
 * Stage 1 found the films in ML/FILM and offered them in the menu.
 * Stage 2 developed the newest raw on demand, and proved on the camera
 * that the bytes it writes are the bytes the desktop computes.
 * Stage 3, this: develop every shot as it is taken.
 *
 * How a shot is noticed. Magic Lantern defines "after shot" callbacks
 * for modules and this build never fires them, so the watcher polls:
 * once a second, from Magic Lantern's own shoot task, it reads Canon's
 * file counter. A new number is a new frame. The frame is queued once
 * Canon reports itself idle and the raw's size has stopped changing,
 * because the counter can move before the file is finished.
 *
 * One worker task drains the queue. It is started once, at init, and
 * loops until power-off; it does not touch the card once shutdown has
 * been requested, because a task holding the card open is a shutdown
 * that does not finish.
 */
#include <module.h>
#include <dryos.h>
#include <menu.h>
#include <config.h>
#include <bmp.h>
#include <fio-ml.h>
#include <console.h>
#include <notify_box.h>
#include <lens.h>
#include <fileprefix.h>

#include "se.h"
#include "stock.h"
#include "cr2.h"
#include "lut.h"
#include "jpeg_dec.h"
#include "jpeg_enc.h"
#include "look.h"

#define SE_MAX_STOCKS   32
#define SE_STOCK_TEXT   8192      /* soup800.fs, the longest, is under 3 KB */

/* ---------------------------------------------------------------- state */

static se_stock *se_stocks;                       /* SE_MAX_STOCKS of them */
static char      se_stock_file[SE_MAX_STOCKS][16];/* the 8.3 name on card */
static int       se_nstocks;
static int       se_film_dir_missing;

/*
 * Remembered across power cycles by Magic Lantern's config system. By
 * index for now; the 5D build stores the NAME, because the list is
 * whatever is in ML/FILM and an index silently changes meaning when a
 * film is added. Worth doing the same here once there is a string config
 * to do it with.
 */
static CONFIG_INT("soupeng.stock",  se_stock_index, 0);
static CONFIG_INT("soupeng.source", se_source,      0);   /* 0 JPEG, 1 RAW */
static CONFIG_INT("soupeng.size",   se_size,        0);   /* 0 half, 1 full */
static CONFIG_INT("soupeng.auto",   se_auto,        1);   /* develop every shot */

static void se_menu_film_max(void);       /* defined below the menu table  */

static volatile int se_busy;              /* the worker is developing     */
static char         se_status[64];        /* what the last develop did     */
static int          se_done, se_failed;   /* this session                  */

/* --------------------------------------------------------------- logging */
/*
 * Lines go to Magic Lantern's console at once and to ML/LOGS/SOUPENG.LOG
 * when flushed. The file is written only between develops, never during
 * one: the 5D learnt that opening a log on the card in the middle of
 * streaming a frame off it gave the card something else to do at exactly
 * the wrong moment, and there is no reason to find out whether this body
 * minds.
 *
 * Formats are kept to %d %s %x. The printf here is Canon's: no %u, no
 * %.*s, no width flags -- it prints the format text literally instead.
 */
#define SE_LOG_CAP 4096
static char se_logbuf[SE_LOG_CAP];
static int  se_loglen;

static void se_logf(const char *fmt, ...)
{
    char line[160];
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vsnprintf(line, sizeof line - 1, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof line - 2) n = (int)sizeof line - 2;
    line[n++] = '\n';
    line[n] = 0;

    printf("soup: %s", line);
    if (se_loglen + n < SE_LOG_CAP) {
        memcpy(se_logbuf + se_loglen, line, (size_t)n);
        se_loglen += n;
    }
}

static void se_log_flush(void)
{
    FILE *f;
    if (!se_loglen || ml_shutdown_requested) return;
    f = FIO_CreateFileOrAppend("ML/LOGS/SOUPENG.LOG");
    if (f) {
        FIO_WriteFile(f, se_logbuf, (size_t)se_loglen);
        FIO_CloseFile(f);
    }
    se_loglen = 0;
}

/* The engine never prints; it calls this. */
static void se_log_hook(void *ctx, const char *msg)
{
    se_logf("engine: %s", msg);
}

/* ---------------------------------------------------------------- utils */

static int ends_with_ci(const char *n, const char *ext)
{
    size_t l = strlen(n), e = strlen(ext);
    size_t i;
    if (l < e) return 0;
    for (i = 0; i < e; i++) {
        char a = n[l - e + i], b = ext[i];
        if (a >= 'a' && a <= 'z') a -= 32;
        if (b >= 'a' && b <= 'z') b -= 32;
        if (a != b) return 0;
    }
    return 1;
}

/* FNV-1a, the same hash tools/previewcheck.c prints. */
#define FNV_INIT 2166136261u
static uint32_t se_hash_bytes(uint32_t h, const void *p, int n)
{
    const uint8_t *b = (const uint8_t *)p;
    int i;
    for (i = 0; i < n; i++) { h ^= b[i]; h *= 16777619u; }
    return h;
}

/*
 * Read a small text file whole. buf gets a terminating NUL.
 *
 * buf must come from fio_malloc: Magic Lantern's FIO_ReadFile refuses a
 * cacheable buffer above 8 KB, because Canon's FIO reads by DMA and a
 * cached buffer would be read back from the cache, not from the data.
 */
static int read_text(const char *path, char *buf, size_t cap, size_t *got)
{
    uint32_t size;
    FILE *f;
    int n;

    if (FIO_GetFileSize(path, &size) != 0) return -1;
    if (size >= cap) return -1;
    f = FIO_OpenFile(path, O_RDONLY | O_SYNC);
    if (!f) return -1;
    n = FIO_ReadFile(f, buf, size);
    FIO_CloseFile(f);
    if (n != (int)size) return -1;
    buf[n] = 0;
    *got = (size_t)n;
    return 0;
}

/* Read exactly n bytes at off, in as many calls as the card wants. */
static int read_at(FILE *f, uint32_t off, uint8_t *dst, uint32_t n)
{
    uint32_t done = 0;
    if (FIO_SeekSkipFile(f, off, SEEK_SET) != (int64_t)off) return -1;
    while (done < n) {
        int got = FIO_ReadFile(f, dst + done, n - done);
        if (got <= 0) return -1;
        done += (uint32_t)got;
    }
    return 0;
}

/* Size of a file, or 0 if it does not exist. */
static uint32_t file_size(const char *path)
{
    uint32_t sz = 0;
    if (FIO_GetFileSize(path, &sz) != 0) return 0;
    return sz;
}

/* ------------------------------------------------------------ the films */

static void se_sort_stocks(void)
{
    /* insertion sort by name; a dozen entries, once per scan */
    int i, j;
    for (i = 1; i < se_nstocks; i++) {
        se_stock tmp = se_stocks[i];
        char tmpf[16];
        memcpy(tmpf, se_stock_file[i], sizeof tmpf);
        for (j = i; j > 0 && strcmp(se_stocks[j - 1].name, tmp.name) > 0; j--) {
            se_stocks[j] = se_stocks[j - 1];
            memcpy(se_stock_file[j], se_stock_file[j - 1], sizeof tmpf);
        }
        se_stocks[j] = tmp;
        memcpy(se_stock_file[j], tmpf, sizeof tmpf);
    }
}

/*
 * Walk ML/FILM on the card Magic Lantern booted from and parse every
 * .fs file. The 5D build reads an INDEX.TXT instead, because that body's
 * FindNext was unreliable; here the directory walk is Magic Lantern's
 * own, used by its file manager, so the index is not needed.
 */
static void se_scan_stocks(void)
{
    char dir[32], path[64];
    char *text;
    struct fio_file *file;
    struct fio_dirent *d;
    const char *drive = get_ml_card()->drive_letter;

    se_nstocks = 0;
    se_film_dir_missing = 0;
    snprintf(dir, sizeof dir, "%s:/ML/FILM", drive);

    text = fio_malloc(SE_STOCK_TEXT);
    file = alloc_fio_file();
    if (!text || !file) {
        se_logf("out of memory scanning films");
        if (text) fio_free(text);
        if (file) free(file);
        return;
    }

    d = FIO_FindFirstEx(dir, file);
    if (IS_ERROR(d)) {
        se_film_dir_missing = 1;
        se_logf("no %s on the card", dir);
        fio_free(text);
        free(file);
        return;
    }

    do {
        struct file_info fi = convert_fio_file_info(file);
        size_t n;
        se_stock *s;

        if (!fi.name[0] || fi.name[0] == '.') continue;   /* exFAT quirk; dotfiles */
        if (fi.mode & ATTR_DIRECTORY) continue;
        if (!ends_with_ci(fi.name, ".fs")) continue;
        if (se_nstocks >= SE_MAX_STOCKS) {
            se_logf("more than %d films, ignoring the rest", SE_MAX_STOCKS);
            break;
        }

        snprintf(path, sizeof path, "%s/%s", dir, fi.name);
        if (read_text(path, text, SE_STOCK_TEXT, &n) != 0) {
            se_logf("cannot read %s", fi.name);
            continue;
        }
        s = &se_stocks[se_nstocks];
        se_stock_init(s);
        if (se_stock_parse(text, n, s) != SE_OK) {
            se_logf("cannot parse %s", fi.name);
            continue;
        }
        snprintf(se_stock_file[se_nstocks], sizeof se_stock_file[0], "%s", fi.name);
        se_nstocks++;
    } while (FIO_FindNextEx(d, file) == 0);

    FIO_FindClose(d);
    fio_free(text);
    free(file);

    se_sort_stocks();
    se_logf("%d films in %s", se_nstocks, dir);
}

/* ------------------------------------------------------- the newest raw */

/*
 * The highest-numbered .CR2 in the shooting folder, for "Develop last
 * shot". The watcher does not use this: it knows the number of each new
 * frame from Canon's counter and never walks the directory.
 */
static int se_newest_cr2(char *out, size_t cap)
{
    const char *dir = get_dcim_dir();
    struct fio_file *file = alloc_fio_file();
    struct fio_dirent *d;
    char best[FIO_MAX_PATH_LENGTH];

    best[0] = 0;
    if (!file) return -1;
    d = FIO_FindFirstEx(dir, file);
    if (IS_ERROR(d)) { free(file); return -1; }
    do {
        struct file_info fi = convert_fio_file_info(file);
        if (!fi.name[0] || (fi.mode & ATTR_DIRECTORY)) continue;
        if (!ends_with_ci(fi.name, ".CR2")) continue;
        if (strcmp(fi.name, best) > 0)
            snprintf(best, sizeof best, "%s", fi.name);
    } while (FIO_FindNextEx(d, file) == 0);
    FIO_FindClose(d);
    free(file);

    if (!best[0]) return -1;
    snprintf(out, cap, "%s/%s", dir, best);
    return 0;
}

/*
 * The output name: FLM_1234.JPG in the raw's folder.
 *
 * The 5D writes IMG_1234.FLM.JPG, and so did the first build of this,
 * which the camera refused: Canon's filesystem is 8.3 and DryOS will not
 * create a name that is not. FLM_ keeps the number and sorts the films
 * together, after the raws.
 *
 * Built by hand, not with snprintf: the snprintf here is Canon's, and it
 * does not know %.*s. The build before that one asked it for exactly
 * that and tried to create a file called ".*s.FLM.JPG".
 */
static void se_out_name(const char *cr2, char *out, size_t cap)
{
    size_t l = strlen(cr2);                 /* ".../IMG_1234.CR2" */
    size_t dir = l;                         /* length including the '/' */
    const char *digits;
    while (dir > 0 && cr2[dir - 1] != '/') dir--;
    digits = cr2 + l - 4;                   /* the four before ".CR2" */
    if (digits - 4 >= cr2 + dir) digits -= 4; else digits = cr2 + dir;

    if (dir + 13 >= cap) { out[0] = 0; return; }
    memcpy(out, cr2, dir);
    strcpy(out + dir, "FLM_");
    memcpy(out + dir + 4, digits, 4);
    strcpy(out + dir + 8, ".JPG");
}

/* --------------------------------------------------------- the develop */

/*
 * The CR2 header. The IFD0 entries that locate the preview, the MakerNote
 * with the exposure data, and the start of the preview itself all sit in
 * the first 100 KB of every 700D frame seen so far; 256 KB is ample.
 */
#define SE_HDR_BYTES  (256 * 1024)
#define SE_OUTBUF     (256 * 1024)
#define SE_ARENA      (1536 * 1024)

typedef struct {
    FILE    *f;
    uint8_t *buf;          /* uncacheable, so FIO needs no cache sync   */
    int      len;
    int      bytes;
    int      err;
} se_out;

static int out_flush(se_out *o)
{
    if (o->len) {
        if (FIO_WriteFile(o->f, o->buf, (size_t)o->len) != o->len) o->err = 1;
        o->len = 0;
    }
    return o->err ? -1 : 0;
}

static int out_sink(void *ctx, const uint8_t *d, size_t n)
{
    se_out *o = (se_out *)ctx;
    while (n) {
        size_t room = SE_OUTBUF - (size_t)o->len;
        size_t k = n < room ? n : room;
        memcpy(o->buf + o->len, d, k);
        o->len += (int)k; o->bytes += (int)k; d += k; n -= k;
        if (o->len == SE_OUTBUF && out_flush(o) != 0) return -1;
    }
    return 0;
}

typedef struct {
    se_jpeg     *enc;
    se_look_run *run;
    int          ow;
    uint32_t     hash;
    int          err;
    int          aborted;     /* power-off during the frame */
} look_ctx;

/* One finished row, on its way out of the look stage. The hash is taken
 * here, after the look, because with halation on rows leave `radius`
 * rows after they went in -- hashing the input would hash the wrong
 * pixels in the wrong order. tools/previewcheck.c hashes the same rows. */
static int look_emit(void *ctx, const uint8_t *row, int width)
{
    look_ctx *L = (look_ctx *)ctx;
    L->hash = se_hash_bytes(L->hash, row, width * 3);
    if (se_jpeg_write_rows(L->enc, row, 1) != SE_OK) { L->err = 1; return -1; }
    return 0;
}

static int look_rows(void *ctx, const uint8_t *rgb, int nrows, int width)
{
    look_ctx *L = (look_ctx *)ctx;
    /* The one place to stop a frame in flight: once a row batch, which
     * is a few milliseconds. The partial file is removed by the caller. */
    if (ml_shutdown_requested) { L->aborted = 1; L->err = 1; return -1; }
    if (width != L->ow) {
        if (!L->err) se_logf("decoder gave %d columns, expected %d", width, L->ow);
        L->err = 1; return -1;
    }
    if (se_look_rows(L->run, rgb, nrows, look_emit, L) != SE_OK) { L->err = 1; return -1; }
    return 0;
}

/* Progress, drawn by the worker itself. Skipped while Magic Lantern's
 * menu is up: it owns the screen then and would paint over it. */
static const char *se_stage = "";
static int         se_pct;
static int         se_waiting;        /* frames queued behind this one */

static void se_progress_hook(void *ctx, const char *stage, int pct)
{
    if (pct == se_pct && stage == se_stage) return;
    se_stage = stage; se_pct = pct;
    if (gui_menu_shown() || ml_shutdown_requested) return;
    if (pct % 5 == 0) {
        if (se_waiting)
            bmp_printf(FONT(FONT_MED, COLOR_WHITE, COLOR_BLACK), 10, 440,
                       "SOUP %s %s %d%%  +%d   ",
                       se_stocks[se_stock_index].name, stage, pct, se_waiting);
        else
            bmp_printf(FONT(FONT_MED, COLOR_WHITE, COLOR_BLACK), 10, 440,
                       "SOUP %s %s %d%%      ",
                       se_stocks[se_stock_index].name, stage, pct);
    }
}

typedef struct {
    int      ow, oh, scale;
    int      bytes;
    uint32_t hash;
    int      ms_hdr, ms_read, ms_stream, ms_total;
    size_t   arena_peak;
    int      aborted;
} se_result;

/*
 * Develop one frame from the preview Canon embedded in it.
 *
 * Memory: four allocations. The header window, the preview and the
 * output staging buffer come from fio_malloc, uncacheable, because the
 * card reads and writes them by DMA. The arena -- the decoder's MCU rows,
 * the look's delay line, the encoder and its strip -- is ordinary
 * cacheable memory, because the processor works in it and uncached
 * memory would make every access a bus cycle. The camera measured the
 * arena's peak at 511 KB for a full-size frame.
 */
static se_err se_develop_preview(const char *cr2_path, const char *out_path,
                                 const se_stock *st, int scale, se_result *R)
{
    uint8_t *hdr = 0, *pv = 0, *amem = 0;
    FILE    *in = 0;
    se_out   out;
    se_arena arena;
    se_look  lk;
    look_ctx L;
    se_cr2_info  info;
    se_jdec_info ji;
    se_jpeg_exif ex;
    se_jpeg *enc;
    uint32_t poff = 0, plen = 0, got;
    int pw, ph, t0, t1, t2, t3;
    se_err rc;

    memset(&out, 0, sizeof out);
    memset(&L, 0, sizeof L);
    memset(R, 0, sizeof *R);
    t0 = get_ms_clock();

    /* --- locate the preview and read the exposure data ----------------- */
    hdr = fio_malloc(SE_HDR_BYTES);
    if (!hdr) { se_logf("no memory for the header window"); return SE_E_NOMEM; }
    in = FIO_OpenFile(cr2_path, O_RDONLY | O_SYNC);
    if (!in) { rc = SE_E_IO; se_logf("cannot open %s", cr2_path); goto done; }
    {
        uint32_t size = FIO_GetFileSize_direct(cr2_path);
        got = size < SE_HDR_BYTES ? size : SE_HDR_BYTES;
    }
    if (read_at(in, 0, hdr, got) != 0) { rc = SE_E_IO; se_logf("header read failed"); goto done; }
    t1 = get_ms_clock();

    rc = se_cr2_find_preview(hdr, got, &poff, &plen, &pw, &ph);
    if (rc != SE_OK) { se_logf("no preview in the raw (rc=%d)", rc); goto done; }
    if (se_cr2_parse(hdr, got, &info) != SE_OK) memset(&info, 0, sizeof info);
    if (poff >= got) { rc = SE_E_UNSUPPORTED; se_logf("preview starts past the header window"); goto done; }
    if (se_jpeg_dec_info(hdr + poff, got - poff, &ji) != SE_OK) {
        rc = SE_E_BADFILE; se_logf("preview header unreadable"); goto done;
    }

    /* --- the preview, whole ------------------------------------------- */
    pv = fio_malloc(plen);
    if (!pv) {
        rc = SE_E_NOMEM;
        se_logf("no memory for the %d KB preview (%d KB free)", (int)(plen >> 10),
                GetFreeMemForMalloc() >> 10);
        goto done;
    }
    if (read_at(in, poff, pv, plen) != 0) { rc = SE_E_IO; se_logf("preview read failed"); goto done; }
    FIO_CloseFile(in); in = 0;
    t2 = get_ms_clock();

    /* --- the look and the working memory ------------------------------- */
    se_jpeg_scaled_size(ji.width, ji.height, scale, &R->ow, &R->oh);
    R->scale = scale;
    se_look_from_stock(st, scale, &lk);
    {
        int r0 = lk.hal_radius, a0 = lk.hal_amount;
        /* Same budget as tools/previewcheck.c, or the two grade differently
         * and the hash proves nothing. */
        se_look_fit(&lk, R->ow, SE_LOOK_BUDGET);
        if (a0 > 0 && lk.hal_amount == 0)
            se_logf("halation off at %d wide: does not fit %d KB", R->ow, SE_LOOK_BUDGET >> 10);
        else if (lk.hal_radius != r0)
            se_logf("halation radius %d -> %d to fit", r0, lk.hal_radius);
    }
    amem = __mem_malloc(SE_ARENA, MEM_TEMPORARY, __FILE__, __LINE__);
    out.buf = fio_malloc(SE_OUTBUF);
    if (!amem || !out.buf) {
        rc = SE_E_NOMEM;
        se_logf("no memory for the develop (%d KB free)", GetFreeMemForMalloc() >> 10);
        goto done;
    }
    se_arena_init(&arena, amem, SE_ARENA);

    enc = SE_NEW(&arena, se_jpeg, 1);
    if (!enc) { rc = SE_E_NOMEM; goto done; }
    rc = se_look_begin(&L.run, &lk, R->ow, &arena);
    if (rc != SE_OK) { se_logf("look stage refused at %d wide", R->ow); goto done; }
    L.ow = R->ow; L.hash = FNV_INIT; L.enc = enc;

    /* --- encode -------------------------------------------------------- */
    out.f = FIO_CreateFile(out_path);
    if (!out.f) { rc = SE_E_IO; se_logf("cannot create %s", out_path); goto done; }
    memset(&ex, 0, sizeof ex);
    ex.make          = info.make[0]  ? info.make  : "Canon";
    ex.model         = info.model[0] ? info.model : "Canon EOS 700D";
    ex.software      = st->name;
    ex.datetime      = info.datetime;
    ex.exposure_time = info.exposure_time;
    ex.aperture      = info.aperture;
    ex.iso           = info.iso;
    {
        uint8_t *strip = SE_NEW(&arena, uint8_t, (size_t)8 * R->ow * 3);
        if (!strip) { rc = SE_E_NOMEM; goto done; }
        rc = se_jpeg_begin(enc, R->ow, R->oh, 88, strip, &ex, out_sink, &out);
        if (rc != SE_OK) goto done;
    }

    rc = se_jpeg_decode_scaled(pv, plen, scale, &arena, look_rows, &L, &ji);
    if (rc != SE_OK && !L.aborted) se_logf("preview decode rc=%d", rc);
    /* the delay line still holds `radius` rows */
    if (rc == SE_OK && !L.err) rc = se_look_end(L.run, look_emit, &L);
    if (rc == SE_OK && !L.err) rc = se_jpeg_end(enc);
    if (rc == SE_OK && out_flush(&out) != 0) rc = SE_E_IO;
    if (L.err && rc == SE_OK) rc = SE_E_IO;
    t3 = get_ms_clock();

    R->hash = L.hash;
    R->bytes = out.bytes;
    R->arena_peak = arena.peak;
    R->aborted = L.aborted;
    R->ms_hdr = t1 - t0; R->ms_read = t2 - t1; R->ms_stream = t3 - t2;
    R->ms_total = t3 - t0;

done:
    if (out.f) FIO_CloseFile(out.f);
    if (rc != SE_OK && out.f) FIO_RemoveFile(out_path);
    if (in) FIO_CloseFile(in);
    if (out.buf) fio_free(out.buf);
    if (amem) free(amem);
    if (pv) fio_free(pv);
    if (hdr) fio_free(hdr);
    return rc;
}

/* ------------------------------------------------------------ the queue */
/*
 * Frames waiting to be developed. Filled by the watcher (once a second,
 * on Magic Lantern's shoot task) and by "Develop last shot" (on the GUI
 * task); drained by the worker. Three tasks, one array: the watcher and
 * the menu only ever append at `tail`, the worker only ever reads at
 * `head`, and each index is written by exactly one side, which is the
 * whole of the locking.
 *
 * A frame is WAITING until Canon is idle and its size has held still
 * for two consecutive looks; then it is READY. A frame that never
 * appears -- JPEG-only shooting, or a counter that moved for some other
 * reason -- is dropped after a while.
 */
#define SE_QUEUE 8

typedef struct {
    char     path[FIO_MAX_PATH_LENGTH];
    uint32_t size;          /* last size seen                        */
    int      stable;        /* looks at which the size did not change */
    int      age;           /* looks since queued                     */
    int      ready;
    int      force;         /* asked for by hand: overwrite, no checks */
} se_job;

static se_job       se_q[SE_QUEUE];
static volatile int se_q_head, se_q_tail;     /* indices, never wrap   */

static int se_q_count(void) { return se_q_tail - se_q_head; }

static se_job *se_q_push(const char *path, int force)
{
    se_job *j;
    if (se_q_count() >= SE_QUEUE) {
        se_logf("queue full, dropping %s", path);
        return 0;
    }
    j = &se_q[se_q_tail % SE_QUEUE];
    memset(j, 0, sizeof *j);
    snprintf(j->path, sizeof j->path, "%s", path);
    j->force = force;
    j->ready = force;
    se_q_tail++;
    return j;
}

/* ---------------------------------------------------------- the watcher */

static int se_last_file_number = -1;
static int se_last_folder_number = -1;

/*
 * Once a second, from Magic Lantern's shoot task.
 *
 * Canon's counter is the number of the last frame taken. It advances the
 * moment a frame is taken, which can be before the raw has finished
 * writing, so a new number only gets the frame QUEUED; it is developed
 * once lens_info.job_state is back to zero -- Canon's own "not writing"
 * -- and the file's size has held still across two looks. The 5D did
 * the same job with a directory walk every two seconds; the counter is
 * free.
 */
static unsigned int se_watch_cbr(unsigned int ctx)
{
    struct card_info *card = get_shooting_card();
    int num = card->file_number, folder = card->folder_number;
    int i;

    /* the first look is the baseline: nothing already on the card is new */
    if (se_last_file_number < 0) {
        se_last_file_number = num;
        se_last_folder_number = folder;
        return 0;
    }

    if (se_auto && se_nstocks && (num != se_last_file_number || folder != se_last_folder_number)) {
        int n = se_last_file_number, steps = 0;
        /* a burst can move the counter by more than one between looks */
        while (n != num && steps < SE_QUEUE) {
            char path[FIO_MAX_PATH_LENGTH];
            n = n >= 9999 ? 1 : n + 1;
            snprintf(path, sizeof path, "%s/%s%04d.CR2", get_dcim_dir(), get_file_prefix(), n);
            if (se_q_push(path, 0)) steps++;
            else break;
        }
        se_last_file_number = num;
        se_last_folder_number = folder;
    }

    /* ripen what is waiting */
    for (i = se_q_head; i < se_q_tail; i++) {
        se_job *j = &se_q[i % SE_QUEUE];
        uint32_t sz;
        if (j->ready) continue;
        j->age++;
        sz = file_size(j->path);
        if (sz && sz == j->size) j->stable++; else j->stable = 0;
        j->size = sz;
        if (sz > (1u << 20) && j->stable >= 1 && lens_info.job_state == 0)
            j->ready = 1;
        else if (j->age > 30) {
            se_logf("gave up waiting for %s", j->path);
            j->ready = -1;          /* the worker skips it */
        }
    }
    return 0;
}

/* ----------------------------------------------------------- the worker */

static void se_develop_job(se_job *j)
{
    char out[FIO_MAX_PATH_LENGTH];
    const se_stock *st;
    se_result R;
    se_err rc;
    int scale = se_size ? 1 : 2;

    if (se_stock_index < 0 || se_stock_index >= se_nstocks) se_stock_index = 0;
    st = &se_stocks[se_stock_index];
    se_out_name(j->path, out, sizeof out);

    if (!j->force && file_size(out) > 0) {
        se_logf("%s already developed", out);
        return;
    }
    if (se_source) se_logf("RAW source is not on this body yet; developing from the preview");

    se_busy = 1;
    se_stage = "starting"; se_pct = 0;
    se_waiting = se_q_count() - 1;
    se_logf("develop %s + %s, %s size, %d waiting, %d KB free", j->path, st->name,
            scale == 1 ? "full" : "half", se_waiting, GetFreeMemForMalloc() >> 10);

    rc = se_develop_preview(j->path, out, st, scale, &R);

    if (rc == SE_OK) {
        se_done++;
        snprintf(se_status, sizeof se_status, "%s %d.%ds",
                 out + strlen(get_dcim_dir()) + 1, R.ms_total / 1000, (R.ms_total % 1000) / 100);
        se_logf("wrote %s: %dx%d, %d KB, look hash %08x", out, R.ow, R.oh,
                R.bytes >> 10, R.hash);
        se_logf("time: hdr %d read %d stream %d total %d ms; arena peak %d KB",
                R.ms_hdr, R.ms_read, R.ms_stream, R.ms_total, (int)(R.arena_peak >> 10));
        if (!ml_shutdown_requested)
            NotifyBox(1500, "Soup: %s %d.%d s", st->name, R.ms_total / 1000, (R.ms_total % 1000) / 100);
    } else if (R.aborted) {
        se_logf("%s abandoned: power off", j->path);
    } else {
        se_failed++;
        snprintf(se_status, sizeof se_status, "failed: %s", se_strerror(rc));
        se_logf("develop failed: %s (rc=%d)", se_strerror(rc), rc);
        if (!ml_shutdown_requested)
            NotifyBox(3000, "Soup: failed, %s", se_strerror(rc));
    }
    se_busy = 0;
    se_log_flush();
}

/*
 * Lives for the whole session. Polls rather than blocks on a semaphore:
 * half a second of latency on a job that takes forty is nothing, and it
 * keeps the queue's locking as simple as it is.
 */
static void se_worker_task(void *arg)
{
    while (!ml_shutdown_requested) {
        if (se_q_count() > 0) {
            se_job *j = &se_q[se_q_head % SE_QUEUE];
            if (j->ready > 0) {
                se_develop_job(j);
                se_q_head++;
            } else if (j->ready < 0) {
                se_q_head++;
            } else {
                msleep(500);         /* the watcher is still ripening it */
            }
            continue;
        }
        msleep(500);
    }
}

/* ---------------------------------------------------------------- menu */

static MENU_UPDATE_FUNC(se_film_update)
{
    if (se_nstocks == 0) {
        MENU_SET_VALUE(se_film_dir_missing ? "no ML/FILM" : "none found");
        MENU_SET_HELP("Put the .fs film files in ML/FILM on the card, then Rescan.");
        return;
    }
    if (se_stock_index < 0 || se_stock_index >= se_nstocks)
        se_stock_index = 0;
    MENU_SET_VALUE("%s", se_stocks[se_stock_index].name);
    MENU_SET_HELP("%s", se_stocks[se_stock_index].desc);
    MENU_SET_RINFO("%d/%d", se_stock_index + 1, se_nstocks);
}

static MENU_UPDATE_FUNC(se_develop_update)
{
    if (se_busy) {
        if (se_waiting) MENU_SET_VALUE("%s %d%%, %d waiting", se_stage, se_pct, se_waiting);
        else MENU_SET_VALUE("%s %d%%", se_stage, se_pct);
    } else if (se_q_count()) {
        MENU_SET_VALUE("%d waiting", se_q_count());
    } else if (se_status[0]) {
        MENU_SET_VALUE("%s", se_status);
    } else {
        MENU_SET_VALUE("");
    }
}

static MENU_SELECT_FUNC(se_develop_select)
{
    char cr2[FIO_MAX_PATH_LENGTH];
    if (!se_nstocks) { NotifyBox(2000, "Soup: no films in ML/FILM"); return; }
    if (se_newest_cr2(cr2, sizeof cr2) != 0) {
        NotifyBox(2000, "Soup: no CR2 in %s", get_dcim_dir());
        return;
    }
    if (se_q_push(cr2, 1))
        NotifyBox(1000, "Soup: queued %s", cr2 + strlen(get_dcim_dir()) + 1);
}

static MENU_UPDATE_FUNC(se_auto_update)
{
    if (se_auto && !se_nstocks) MENU_SET_WARNING(MENU_WARN_NOT_WORKING, "No films in ML/FILM.");
    if (se_done || se_failed) MENU_SET_RINFO("%d done, %d failed", se_done, se_failed);
}

static MENU_UPDATE_FUNC(se_rescan_update)
{
    MENU_SET_VALUE("%d found", se_nstocks);
}

static MENU_SELECT_FUNC(se_rescan_select)
{
    if (se_busy) return;
    se_scan_stocks();
    se_menu_film_max();
    se_log_flush();
}

/* The top-level line shows the chosen film without opening the submenu. */
static MENU_UPDATE_FUNC(se_top_update)
{
    if (se_busy)
        MENU_SET_VALUE("%s %d%%", se_stage, se_pct);
    else if (se_nstocks && se_stock_index >= 0 && se_stock_index < se_nstocks)
        MENU_SET_VALUE("%s%s", se_stocks[se_stock_index].name, se_auto ? "" : " (manual)");
    else
        MENU_SET_VALUE("no films");
}

static struct menu_entry se_menu[] =
{
    {
        .name           = "Soup Engine",
        .select         = menu_open_submenu,
        .update         = se_top_update,
        .help           = "Film looks, in the camera.",
        .help2          = "Films are the .fs files in ML/FILM on the card.",
        .submenu_width  = 710,
        .children       = (struct menu_entry[]) {
            {
                .name       = "Film",
                .priv       = &se_stock_index,
                .min        = 0,
                .max        = 0,        /* set once the card has been scanned */
                .update     = se_film_update,
                .icon_type  = IT_DICE,
                .help       = "The look every photo gets from now on.",
            },
            {
                .name       = "Auto develop",
                .priv       = &se_auto,
                .max        = 1,
                .update     = se_auto_update,
                .help       = "Develop every shot as it is taken. FLM_1234.JPG beside each raw.",
                .help2      = "Keep shooting while it works; frames queue up. The raw is never modified.",
            },
            {
                .name       = "Develop last shot",
                .select     = se_develop_select,
                .update     = se_develop_update,
                .icon_type  = IT_ACTION,
                .help       = "Develop the newest raw on the card with this film, now.",
                .help2      = "Also how to redo a frame after changing the film.",
            },
            {
                .name       = "Size",
                .priv       = &se_size,
                .max        = 1,
                .choices    = CHOICES("Half", "Full"),
                .help       = "Half is 2592x1728 and takes about 45 s. Full is 18 MP and about 3 min.",
            },
            {
                .name       = "Source",
                .priv       = &se_source,
                .max        = 1,
                .choices    = CHOICES("JPEG", "RAW"),
                .help       = "JPEG grades the preview DIGIC already made. Use this.",
                .help2      = "RAW works from the sensor data: slower, some adjustments unavailable. Not yet on this body.",
            },
            {
                .name       = "Rescan films",
                .select     = se_rescan_select,
                .update     = se_rescan_update,
                .icon_type  = IT_ACTION,
                .help       = "Read ML/FILM again after changing the files on the card.",
            },
            MENU_EOL,
        },
    },
};

/* the Film entry's toggle range is the list's length */
static void se_menu_film_max(void)
{
    se_menu[0].children[0].max = se_nstocks > 0 ? se_nstocks - 1 : 0;
}

/* ------------------------------------------------------------- lifetime */

static unsigned int se_module_init(void)
{
    se_set_log(se_log_hook, NULL);
    se_set_progress(se_progress_hook, NULL);

    se_stocks = malloc(sizeof(se_stock) * SE_MAX_STOCKS);
    if (!se_stocks) {
        se_logf("cannot allocate %d bytes for the films",
                (int)(sizeof(se_stock) * SE_MAX_STOCKS));
        se_log_flush();
        return 1;
    }
    se_scan_stocks();
    se_menu_film_max();

    menu_add("Shoot", se_menu, COUNT(se_menu));
    task_create("soup_dev", 0x1c, 0x8000, se_worker_task, 0);

    se_logf("engine format %d, %d films, source %s, size %s, auto %s; free: malloc %d KB, AllocateMemory %d KB",
            SE_STOCK_VERSION, se_nstocks, se_source ? "RAW" : "JPEG",
            se_size ? "full" : "half", se_auto ? "on" : "off",
            GetFreeMemForMalloc() >> 10, GetFreeMemForAllocateMemory() >> 10);
    se_log_flush();
    return 0;
}

static unsigned int se_module_deinit(void)
{
    menu_remove("Shoot", se_menu, COUNT(se_menu));
    if (se_stocks) { free(se_stocks); se_stocks = NULL; }
    return 0;
}

MODULE_INFO_START()
    MODULE_INIT(se_module_init)
    MODULE_DEINIT(se_module_deinit)
MODULE_INFO_END()

MODULE_CBRS_START()
    MODULE_CBR(CBR_SECONDS_CLOCK, se_watch_cbr, 0)
MODULE_CBRS_END()

MODULE_CONFIGS_START()
    MODULE_CONFIG(se_stock_index)
    MODULE_CONFIG(se_source)
    MODULE_CONFIG(se_size)
    MODULE_CONFIG(se_auto)
MODULE_CONFIGS_END()
