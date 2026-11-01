/*
 * bridge.c - the desktop's calls into the engine. See soup_bridge.h.
 */
#include "soup_bridge.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "se.h"
#include "cr2.h"
#include "stock.h"

/* ----------------------------------------------------------- files, read only */
typedef struct { const uint8_t *p; size_t len; } mapped;

static int map_file(const char *path, mapped *m)
{
    struct stat st;
    int fd = open(path, O_RDONLY);
    void *p;
    if (fd < 0) return -1;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) { close(fd); return -1; }
    p = mmap(0, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return -1;
    m->p = p;
    m->len = (size_t)st.st_size;
    return 0;
}

static void unmap_file(mapped *m) { munmap((void *)m->p, m->len); }

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
    if (map_file(path, &m) != 0) return -1;
    if (se_cr2_parse(m.p, m.len, &info) != SE_OK) { unmap_file(&m); return -1; }

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
    unmap_file(&m);
    return 0;
}

int sb_jpeg_software(const char *path, char *out, size_t cap)
{
    mapped m;
    size_t i, room;
    int rc = -1;

    if (cap == 0) return -1;
    out[0] = 0;
    if (map_file(path, &m) != 0) return -1;

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
    unmap_file(&m);
    return rc;
}

void sb_free(void *p) { free(p); }

/* ---------------------------------------------------------------- the film */
struct sb_film { se_stock st; };

sb_film *sb_film_load(const char *path)
{
    mapped m;
    sb_film *f;
    if (map_file(path, &m) != 0) return 0;
    f = malloc(sizeof *f);
    if (f && se_stock_parse((const char *)m.p, m.len, &f->st) != SE_OK) { free(f); f = 0; }
    unmap_file(&m);
    return f;
}

void        sb_film_free(sb_film *f) { free(f); }
const char *sb_film_name(const sb_film *f) { return f->st.name; }
const char *sb_film_desc(const sb_film *f) { return f->st.desc; }

/* The rest is the engine agent's: sb_warm_up, sb_cr2_embedded, sb_negative_*,
 * sb_render, sb_print. */
