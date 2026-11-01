/*
 * bridge.c - the desktop's calls into the engine. See soup_bridge.h.
 */
#include "soup_bridge.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "se.h"
#include "cr2.h"
#include "jpeg_dec.h"
#include "jpeg_enc.h"
#include "look.h"
#include "pipeline.h"
#include "stock.h"

/* ----------------------------------------------------------- files, read only */
/*
 * Bytes off a card are read, never mapped: a card pulled during a read is an
 * error from pread and a SIGBUS from a mapping. `limit` bounds it, because the
 * facts of a frame are in its first bytes and a card reader is slow.
 */
typedef struct { const uint8_t *p; size_t len; } mapped;

#define SB_CR2_HEAD  (256 * 1024)      /* SE_HDR_BYTES: what the camera reads too */
#define SB_JPEG_HEAD (64 * 1024)       /* a JPEG's APP1 cannot be longer */
#define SB_FILM_MAX  (1024 * 1024)     /* soup800.fs, the longest, is under 3 KB */

static int read_at(int fd, void *dst, size_t n, off_t off)
{
    uint8_t *p = dst;
    while (n) {
        ssize_t got = pread(fd, p, n, off);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return -1;
        p += got; off += got; n -= (size_t)got;
    }
    return 0;
}

static int read_head(const char *path, size_t limit, mapped *m)
{
    struct stat st;
    int fd = open(path, O_RDONLY);
    uint8_t *p = 0;
    size_t n;
    if (fd < 0) return -1;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) goto fail;
    n = (size_t)st.st_size < limit ? (size_t)st.st_size : limit;
    p = malloc(n);
    if (!p || read_at(fd, p, n, 0) != 0) goto fail;
    close(fd);
    m->p = p;
    m->len = n;
    return 0;
fail:
    free(p);
    close(fd);
    return -1;
}

static void free_head(mapped *m) { free((void *)m->p); }

static uint16_t rd16(const uint8_t *p, int le) { return le ? (uint16_t)(p[0] | p[1] << 8) : (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t rd32(const uint8_t *p, int le)
{
    return le ? (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24
              : (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | (uint32_t)p[3];
}

/*
 * Find a tag in a TIFF's first IFD. `t` is the start of the TIFF header.
 * Returns a pointer to the 12-byte entry, or NULL. Every offset is checked:
 * these bytes come off a card.
 */
static const uint8_t *tiff_tag(const uint8_t *t, size_t len, int tag, int *le)
{
    uint32_t ifd;
    int n, i;
    if (len < 8) return 0;
    if (t[0] == 'I' && t[1] == 'I') *le = 1;
    else if (t[0] == 'M' && t[1] == 'M') *le = 0;
    else return 0;
    ifd = rd32(t + 4, *le);
    if (ifd > len || len - ifd < 2) return 0;
    n = rd16(t + ifd, *le);
    if ((size_t)n * 12 > len - ifd - 2) return 0;
    for (i = 0; i < n; i++) {
        const uint8_t *e = t + ifd + 2 + 12 * (size_t)i;
        if (rd16(e, *le) == tag) return e;
    }
    return 0;
}

/* --------------------------------------------------------------- the frame */
int sb_cr2_probe(const char *path, sb_cr2_facts *out)
{
    mapped m;
    se_cr2_info info;
    const uint8_t *e;
    int le = 1;

    memset(out, 0, sizeof *out);
    if (read_head(path, SB_CR2_HEAD, &m) != 0) return -1;
    if (se_cr2_parse(m.p, m.len, &info) != SE_OK) { free_head(&m); return -1; }

    out->width = info.active_width;
    out->height = info.active_height;
    snprintf(out->make, sizeof out->make, "%s", info.make);
    snprintf(out->model, sizeof out->model, "%s", info.model);
    snprintf(out->datetime, sizeof out->datetime, "%s", info.datetime);
    out->exposure_time = info.exposure_time;
    out->aperture = info.aperture;
    out->iso = info.iso;

    out->orientation = 1;
    e = tiff_tag(m.p, m.len, 0x0112, &le);
    if (e) {
        int v = rd16(e + 8, le);
        if (v >= 1 && v <= 8) out->orientation = v;
    }
    free_head(&m);
    return 0;
}

int sb_jpeg_software(const char *path, char *out, size_t cap)
{
    mapped m;
    size_t i, room;
    int rc = -1;

    if (cap == 0) return -1;
    out[0] = 0;
    if (read_head(path, SB_JPEG_HEAD, &m) != 0) return -1;

    /* walk the markers to APP1 */
    i = 2;
    if (m.len < 4 || m.p[0] != 0xFF || m.p[1] != 0xD8) goto done;
    while (i + 4 <= m.len && m.p[i] == 0xFF && m.p[i + 1] != 0xDA) {
        size_t seg = (size_t)m.p[i + 2] << 8 | m.p[i + 3];
        if (seg < 2 || seg > m.len - i - 2) goto done;
        if (m.p[i + 1] == 0xE1 && seg >= 8 && memcmp(m.p + i + 4, "Exif\0\0", 6) == 0) {
            const uint8_t *t = m.p + i + 10;
            size_t tlen = seg - 8;
            int le = 1;
            const uint8_t *e = tiff_tag(t, tlen, 0x0131, &le);
            if (e) {
                uint32_t n = rd32(e + 4, le);
                const uint8_t *s = n <= 4 ? e + 8 : 0;
                if (!s) {
                    uint32_t off = rd32(e + 8, le);
                    if (off <= tlen && n <= tlen - off) s = t + off;
                }
                if (s) {
                    room = n < cap - 1 ? n : cap - 1;
                    memcpy(out, s, room);
                    out[room] = 0;
                    if (out[0]) rc = 0;
                }
            }
            goto done;
        }
        i += seg + 2;
    }
done:
    free_head(&m);
    return rc;
}

void sb_free(void *p) { free(p); }

/* ---------------------------------------------------------------- the film */
struct sb_film { se_stock st; };

sb_film *sb_film_load(const char *path)
{
    mapped m;
    sb_film *f;
    if (read_head(path, SB_FILM_MAX, &m) != 0) return 0;
    f = malloc(sizeof *f);
    if (f && se_stock_parse((const char *)m.p, m.len, &f->st) != SE_OK) { free(f); f = 0; }
    free_head(&m);
    return f;
}

void        sb_film_free(sb_film *f) { free(f); }
const char *sb_film_name(const sb_film *f) { return f->st.name; }
const char *sb_film_desc(const sb_film *f) { return f->st.desc; }

/* ------------------------------------------------------------- whole reads */
/*
 * Read, not mapped, for anything that runs long. A page of a mapped file that
 * goes away with the card is a SIGBUS; a read() that does is an error.
 */
/* A slice at a time, so a frame left behind on the strip stops reading. */
#define SB_READ_SLICE (1u << 20)

static void *read_whole(const char *path, size_t *len, const volatile int *cancel)
{
    struct stat st;
    uint8_t *buf = 0;
    size_t done = 0, n = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    if (fstat(fd, &st) == 0 && st.st_size > 0) { n = (size_t)st.st_size; buf = malloc(n); }
    while (buf && done < n) {
        size_t want = n - done < SB_READ_SLICE ? n - done : SB_READ_SLICE;
        if ((cancel && *cancel) || read_at(fd, buf + done, want, (off_t)done) != 0) { free(buf); buf = 0; }
        done += want;
    }
    close(fd);
    if (buf) *len = n;
    return buf;
}

/* --------------------------------------------------------------- the warm-up */
static int warm_sink(void *ctx, const uint8_t *data, size_t len) { return 0; }

static void warm(void)
{
    se_stock *st = malloc(sizeof *st);
    se_jpeg  *enc = malloc(sizeof *enc);
    se_look  *lk = malloc(sizeof *lk);
    uint8_t   strip[8 * 8 * 3];

    /* look.c builds tables_init() here, jpeg_enc.c build_all_codes() here */
    if (st && lk) { se_stock_init(st); se_look_from_stock(st, 1, lk); }
    if (enc) se_jpeg_begin(enc, 8, 8, 92, strip, 0, warm_sink, 0);
    free(st); free(enc); free(lk);
}

void sb_warm_up(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, warm);
}

/* ------------------------------------------------------------ the embedded JPEG */
/* Enough of a CR2 to hold IFD0. The JPEG itself is then read alone. */
#define HEAD_BYTES (1u << 20)

/*
 * The JPEG's bytes, without reading the sensor data after them: a roll of
 * thumbnails off a card is twenty times the reading otherwise. A file whose
 * preview sits past the head is read whole.
 */
static uint8_t *read_preview(const char *path, uint32_t *off, uint32_t *bytes)
{
    struct stat st;
    uint8_t *head = 0, *jpg = 0;
    size_t   n;
    int      fd = open(path, O_RDONLY);

    if (fd < 0) return 0;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) goto out;
    n = (size_t)st.st_size < HEAD_BYTES ? (size_t)st.st_size : HEAD_BYTES;
    head = malloc(n);
    if (!head || read_at(fd, head, n, 0) != 0) goto out;

    if (se_cr2_find_preview(head, n, off, bytes, 0, 0) == SE_OK) {
        if ((uint64_t)*off + *bytes > (uint64_t)st.st_size) goto out;
        jpg = malloc(*bytes);
        if (jpg && read_at(fd, jpg, *bytes, *off) != 0) { free(jpg); jpg = 0; }
        *off = 0;
    } else if ((size_t)st.st_size > n) {
        size_t len = 0;
        uint8_t *all = read_whole(path, &len, 0);
        if (all && se_cr2_find_preview(all, len, off, bytes, 0, 0) == SE_OK &&
            (uint64_t)*off + *bytes <= len) jpg = all;
        else free(all);
    }
out:
    free(head);
    close(fd);
    return jpg;
}

typedef struct { uint8_t *rgb; int y, w, h, box; int *acc; } embed_ctx;

static int embed_rows(void *ctx, const uint8_t *rgb, int nrows, int width)
{
    embed_ctx *e = ctx;
    int i, x, c;
    for (i = 0; i < nrows; i++, e->y++, rgb += (size_t)width * 3) {
        if (e->box == 1) {
            if (e->y < e->h) memcpy(e->rgb + (size_t)e->y * e->w * 3, rgb, (size_t)e->w * 3);
            continue;
        }
        /* 1/8: the decoder stops at 1/4, so two rows and columns go to one */
        for (x = 0; x < e->w; x++)
            for (c = 0; c < 3; c++)
                e->acc[x * 3 + c] += rgb[x * 6 + c] + rgb[x * 6 + 3 + c];
        if (e->y & 1) {
            if (e->y / 2 < e->h)
                for (x = 0; x < e->w * 3; x++)
                    e->rgb[(size_t)(e->y / 2) * e->w * 3 + x] = (uint8_t)((e->acc[x] + 2) >> 2);
            memset(e->acc, 0, (size_t)e->w * 3 * sizeof(int));
        }
    }
    return 0;
}

int sb_cr2_embedded(const char *path, int scale, uint8_t **rgb, int *w, int *h)
{
    uint8_t     *jpg = 0, *pix = 0;
    void        *amem = 0;
    int         *acc = 0;
    size_t       need;
    uint32_t     off = 0, bytes = 0;
    se_jdec_info ji;
    se_arena     a;
    embed_ctx    e;
    int          ds = scale == 8 ? 4 : scale, ow, oh, rc = -1;

    *rgb = 0;
    if (ds != 1 && ds != 2 && ds != 4) return -1;
    jpg = read_preview(path, &off, &bytes);
    if (!jpg) return -1;
    if (se_jpeg_dec_info(jpg + off, bytes, &ji) != SE_OK) goto out;

    se_jpeg_scaled_size(ji.width, ji.height, ds, &ow, &oh);
    memset(&e, 0, sizeof e);
    e.box = scale == 8 ? 2 : 1;
    e.w = ow / e.box;
    e.h = oh / e.box;
    if (e.w < 1 || e.h < 1) goto out;

    /* the header's width*16*6, and the decoder's own state on top */
    need = (size_t)ji.width * 16 * 6 + (1u << 20);
    amem = malloc(need);
    pix  = malloc((size_t)e.w * e.h * 3);
    if (e.box > 1) acc = calloc((size_t)e.w * 3, sizeof(int));
    if (!amem || !pix || (e.box > 1 && !acc)) goto out;

    se_arena_init(&a, amem, need);
    e.rgb = pix;
    e.acc = acc;
    if (se_jpeg_decode_scaled(jpg + off, bytes, ds, &a, embed_rows, &e, &ji) != SE_OK) goto out;
    if (e.y < oh) goto out;

    *rgb = pix; pix = 0;
    *w = e.w;
    *h = e.h;
    rc = 0;
out:
    free(jpg); free(amem); free(pix); free(acc);
    return rc;
}

/* ------------------------------------------------------------ the negative */
struct sb_negative {
    se_cr2_info info;
    uint16_t   *raw;      /* the whole frame: nothing here points at the file */
    se_lut1    *flat;     /* the neutral stock's tables, three, read only     */
};

void sb_negative_close(sb_negative *n)
{
    if (!n) return;
    free(n->raw);
    free(n->flat);
    free(n);
}

sb_negative *sb_negative_open(const char *path, const volatile int *cancel)
{
    /* cr2.c takes 8 KB of header, a row and its window out of this */
    enum { SCRATCH = 1 << 20 };
    size_t       len = 0;
    uint8_t     *file = read_whole(path, &len, cancel);
    void        *amem = malloc(SCRATCH);
    se_stock    *neutral = malloc(sizeof *neutral);
    sb_negative *n = calloc(1, sizeof *n);
    se_arena     a;
    int          ok = 0;

    if (!file || !amem || !neutral || !n) goto out;
    if (se_cr2_parse(file, len, &n->info) != SE_OK) goto out;

    n->raw  = calloc((size_t)n->info.raw_width * n->info.raw_height, sizeof(uint16_t));
    n->flat = malloc(3 * sizeof(se_lut1));
    if (!n->raw || !n->flat) goto out;

    se_arena_init(&a, amem, SCRATCH);
    if (se_cr2_decode(file, len, &n->info, n->raw, &a) != SE_OK) goto out;
    se_cr2_measure_black(&n->info, n->raw);

    se_stock_init(neutral);
    se_stock_bake(neutral, n->flat);
    ok = 1;
out:
    free(file); free(amem); free(neutral);
    if (!ok) { sb_negative_close(n); n = 0; }
    return n;
}

void sb_negative_size(const sb_negative *n, int scale, int *w, int *h)
{
    se_develop_out_size(&n->info, scale, w, h);
}

/* ------------------------------------------------------------- the develop */
/*
 * One develop, with everything it needs on the heap and none of it shared:
 * this is what looks_cmd in host/main.c does for one stock, with its statics
 * taken out. Rows end up in `rgb` for a render and in `enc` for a print.
 */
typedef struct {
    se_look_run *run;           /* NULL for the straight raw */
    se_jpeg     *enc;
    uint8_t     *rgb;
    int          w, y;
    const volatile int *cancel;
    int          stopped;
} dev_ctx;

static int dev_emit(void *ctx, const uint8_t *row, int width)
{
    dev_ctx *c = ctx;
    if (c->enc) {
        if (se_jpeg_write_rows(c->enc, row, 1) != SE_OK) return -1;
    } else {
        memcpy(c->rgb + (size_t)c->y * width * 3, row, (size_t)width * 3);
    }
    c->y++;
    return 0;
}

static int dev_rows(void *ctx, const uint8_t *rgb, int nrows, int width)
{
    dev_ctx *c = ctx;
    int i;
    if (c->cancel && *c->cancel) { c->stopped = 1; return -1; }
    if (c->run) return se_look_rows(c->run, rgb, nrows, dev_emit, c) == SE_OK ? 0 : -1;
    for (i = 0; i < nrows; i++)
        if (dev_emit(c, rgb + (size_t)i * width * 3, width) != 0) return -1;
    return 0;
}

/* The arena for one develop, sized from what the engine says it spends. */
static void *dev_arena(const sb_negative *n, const se_look *lk, int ow, int extra, se_arena *a)
{
    size_t need = se_develop_scratch_size(&n->info) + (size_t)extra + 4096;
    void  *mem;
    if (lk) need += se_look_bytes(lk, ow);
    mem = malloc(need);
    if (mem) se_arena_init(a, mem, need);
    return mem;
}

/* 0, -1, or 1 if cancelled. The look, if any, is already begun on c->run. */
static int dev_run(const sb_negative *n, int scale, se_arena *a, dev_ctx *c)
{
    se_dev_opts o;
    se_raw_src  src;

    se_dev_opts_default(&o);
    o.scale = scale; o.tone = n->flat; o.dither = 1; o.grain_amount = 0;
    o.rows = dev_rows; o.rows_ctx = c;
    memset(&src, 0, sizeof src);
    src.mem = n->raw;

    if (se_develop(&n->info, &src, NULL, &o, a, NULL, NULL) != SE_OK)
        return c->stopped ? 1 : -1;
    if (c->run && se_look_end(c->run, dev_emit, c) != SE_OK) return -1;
    return 0;
}

int sb_render(const sb_negative *n, const sb_film *film, int scale,
              uint8_t *rgb, const volatile int *cancel)
{
    dev_ctx  c;
    se_look  lk;
    se_arena a;
    void    *mem;
    int      ow, oh, rc;

    if (!n || !rgb || (scale != 1 && scale != 2 && scale != 4)) return -1;
    if (cancel && *cancel) return 1;
    se_develop_out_size(&n->info, scale, &ow, &oh);
    if (film) {
        se_look_from_stock(&film->st, scale, &lk);
        se_look_fit(&lk, ow, SE_LOOK_BUDGET);
    }
    mem = dev_arena(n, film ? &lk : 0, ow, 0, &a);
    if (!mem) return -1;

    memset(&c, 0, sizeof c);
    c.rgb = rgb; c.w = ow; c.cancel = cancel;
    if (film && se_look_begin(&c.run, &lk, ow, &a) != SE_OK) { free(mem); return -1; }
    rc = dev_run(n, scale, &a, &c);
    if (rc == 0 && c.y != oh) rc = -1;
    free(mem);
    return rc;
}

/* ---------------------------------------------------------------- the print */
static int print_sink(void *ctx, const uint8_t *data, size_t len)
{
    return fwrite(data, 1, len, (FILE *)ctx) == len ? 0 : -1;
}

int sb_print(const sb_negative *n, const sb_film *film, int scale, int quality,
             int orientation, const char *out_path, const volatile int *cancel)
{
    dev_ctx      c;
    se_look      lk;
    se_arena     a;
    se_jpeg_exif ex;
    se_jpeg     *enc = 0;      /* ~6 KB, so the heap */
    uint8_t     *strip;
    void        *mem = 0;
    FILE        *fo = 0;
    int          ow, oh, rc = -1;

    if (!n || !out_path || (scale != 1 && scale != 2 && scale != 4)) return -1;
    if (cancel && *cancel) return 1;
    se_develop_out_size(&n->info, scale, &ow, &oh);
    if (film) {
        se_look_from_stock(&film->st, scale, &lk);
        se_look_fit(&lk, ow, SE_LOOK_BUDGET);
    }
    mem = dev_arena(n, film ? &lk : 0, ow, (int)SE_JPEG_STRIP_BYTES(ow, 0), &a);
    enc = malloc(sizeof *enc);
    if (!mem || !enc) goto fail;

    memset(&c, 0, sizeof c);
    c.enc = enc; c.w = ow; c.cancel = cancel;
    if (film && se_look_begin(&c.run, &lk, ow, &a) != SE_OK) goto fail;

    /* nothing above touched the disk, so a refused print leaves it alone */
    fo = fopen(out_path, "wb");
    if (!fo) goto fail;

    memset(&ex, 0, sizeof ex);
    ex.make = n->info.make[0] ? n->info.make : "Canon";
    ex.model = n->info.model[0] ? n->info.model : "Canon EOS 5D";
    ex.software = film ? film->st.name : "STRAIGHT RAW";
    ex.datetime = n->info.datetime[0] ? n->info.datetime : NULL;
    ex.exposure_time = n->info.exposure_time;
    ex.aperture = n->info.aperture;
    ex.iso = n->info.iso;
    ex.orientation = orientation >= 1 && orientation <= 8 ? orientation : 1;

    strip = SE_NEW(&a, uint8_t, SE_JPEG_STRIP_BYTES(ow, 0));
    if (!strip || se_jpeg_begin(enc, ow, oh, quality, strip, &ex, print_sink, fo) != SE_OK)
        goto fail;

    rc = dev_run(n, scale, &a, &c);
    if (rc == 0 && (c.y != oh || se_jpeg_end(enc) != SE_OK)) rc = -1;

    /* to the disk before the caller names it: a print is never a zero-byte
     * file a power cut left, and that is how the camera's own test reads */
    if (rc == 0 && (fflush(fo) != 0 || fsync(fileno(fo)) != 0)) rc = -1;
    if (fclose(fo) != 0 && rc == 0) rc = -1;
    fo = 0;
    if (rc == 0) goto done;
    unlink(out_path);
fail:
    if (fo) { fclose(fo); unlink(out_path); }
done:
    free(mem);
    free(enc);
    return rc;
}
