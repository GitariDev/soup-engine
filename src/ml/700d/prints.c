/*
 * prints.c - the small copies Prints shows, and the lists of what is on the
 * card.
 *
 * A print on this camera takes seconds to decode, which is no way to flip
 * through frames, so every frame gets a preview as it develops: the rows are
 * passing through anyway, and adding them up costs little. It lives in
 * ML/PRINTS as FLM_1234.SPV, 648x432 and a 216x144 thumbnail, already in the
 * screen's colours, so opening one is a card read. Older prints have none;
 * the worker makes one from the JPEG the first time it is asked.
 *
 * The screen's photo palette is a 6x6x5 colour cube at fixed entries, which
 * is what lets the worker write these with the pack not even loaded. Photos
 * go on the bitmap layer rather than Canon's YUV one because the first camera
 * run proved the palette holds on the shooting screen, and because staying
 * here means the half-press closes it as it closes everything else. tools/
 * mkui.js puts the cube at the same entries.
 */
#include "soupeng.h"

#define SE_CUBE_BASE 69
#define SE_PV_MAGIC  0x31565053    /* "SPV1" */

typedef struct {
    uint32_t magic, flm_bytes;
    int32_t  size;                 /* se_size's numbering */
    char     film[32];
    uint8_t  pad[20];
} se_pv_head;                      /* 64 bytes, then thumbnail, then preview */

#define SE_PV_TH    (SE_TH_W * SE_TH_H)
#define SE_PV_FULL  (SE_PV_W * SE_PV_H)
#define SE_PV_FILE  (64 + SE_PV_TH + SE_PV_FULL)

/* ------------------------------------------------------------ the reducer */
/* One user at a time: the worker. */
static uint8_t  *pv_file;
static uint32_t  pv_acc[SE_PV_W * 3], pv_tacc[SE_TH_W * 3];
static int       pv_f, pv_rows, pv_y;

static const uint8_t pv_bayer[16] = { 0,8,2,10, 12,4,14,6, 3,11,1,9, 15,7,13,5 };

static uint8_t pv_cube(int r, int g, int b, int d)
{
    int t = d * 16 + 8;
    return (uint8_t)(SE_CUBE_BASE + (((r * 5 + t) >> 8) * 6 + ((g * 5 + t) >> 8)) * 5 + ((b * 4 + t) >> 8));
}

int se_pv_begin(int width)
{
    pv_f = width / SE_PV_W;
    if (pv_f < 1) return -1;
    pv_file = fio_malloc(SE_PV_FILE);
    if (!pv_file) return -1;
    memset(pv_file, 0, SE_PV_FILE);
    memset(pv_acc, 0, sizeof pv_acc);
    memset(pv_tacc, 0, sizeof pv_tacc);
    pv_rows = pv_y = 0;
    return 0;
}

/* One row of RGB, at any width that is a multiple of 648. */
void se_pv_row(const uint8_t *rgb)
{
    int x, k;
    if (!pv_file || pv_y >= SE_PV_H) return;
    for (x = 0; x < SE_PV_W; x++) {
        uint32_t r = 0, g = 0, b = 0;
        for (k = 0; k < pv_f; k++, rgb += 3) { r += rgb[0]; g += rgb[1]; b += rgb[2]; }
        pv_acc[x * 3] += r; pv_acc[x * 3 + 1] += g; pv_acc[x * 3 + 2] += b;
    }
    if (++pv_rows < pv_f) return;

    {
        uint8_t *out = pv_file + 64 + SE_PV_TH + pv_y * SE_PV_W;
        int n = pv_f * pv_f, ty = pv_y / 3;
        for (x = 0; x < SE_PV_W; x++) {
            int r = (int)pv_acc[x * 3] / n, g = (int)pv_acc[x * 3 + 1] / n, b = (int)pv_acc[x * 3 + 2] / n;
            out[x] = pv_cube(r, g, b, pv_bayer[(pv_y & 3) * 4 + (x & 3)]);
            pv_tacc[(x / 3) * 3] += (uint32_t)r; pv_tacc[(x / 3) * 3 + 1] += (uint32_t)g; pv_tacc[(x / 3) * 3 + 2] += (uint32_t)b;
        }
        if (pv_y % 3 == 2) {
            uint8_t *t = pv_file + 64 + ty * SE_TH_W;
            for (x = 0; x < SE_TH_W; x++)
                t[x] = pv_cube((int)pv_tacc[x * 3] / 9, (int)pv_tacc[x * 3 + 1] / 9, (int)pv_tacc[x * 3 + 2] / 9,
                               pv_bayer[(ty & 3) * 4 + (x & 3)]);
            memset(pv_tacc, 0, sizeof pv_tacc);
        }
    }
    memset(pv_acc, 0, sizeof pv_acc);
    pv_rows = 0;
    pv_y++;
}

void se_pv_abort(void)
{
    if (pv_file) { fio_free(pv_file); pv_file = 0; }
}

static void pv_path(int no, char *buf, size_t cap)
{
    snprintf(buf, cap, "ML/PRINTS/FLM_%04d.SPV", no);
}

/* Writes it and lets go of the buffer. A preview that fails is only a
 * preview: the worker makes it again when it is next asked for. */
void se_pv_save(int no, const char *film, int size, uint32_t flm_bytes)
{
    char path[48];
    se_pv_head *h = (se_pv_head *)pv_file;
    FILE *f;
    if (!pv_file) return;
    h->magic = SE_PV_MAGIC;
    h->flm_bytes = flm_bytes;
    h->size = size;
    snprintf(h->film, sizeof h->film, "%s", film);
    pv_path(no, path, sizeof path);
    f = FIO_CreateFile(path);
    if (f) {
        if (FIO_WriteFile(f, pv_file, SE_PV_FILE) != SE_PV_FILE) se_logf("preview short write");
        FIO_CloseFile(f);
    }
    se_pv_abort();
}

void se_pv_remove(int no)
{
    char path[48];
    pv_path(no, path, sizeof path);
    FIO_RemoveFile(path);
}

/* ------------------------------------------------------------ reading one */
static int pv_read(int no, uint32_t off, void *dst, int n)
{
    char path[48];
    uint8_t *bounce, *d = dst;
    FILE *f;
    int ok = 1;
    pv_path(no, path, sizeof path);
    f = FIO_OpenFile(path, O_RDONLY | O_SYNC);
    if (!f) return -1;
    bounce = fio_malloc(64 * 1024);
    if (!bounce) { FIO_CloseFile(f); return -1; }
    if (FIO_SeekSkipFile(f, off, SEEK_SET) != (int64_t)off) ok = 0;
    while (ok && n > 0) {
        int want = n > 64 * 1024 ? 64 * 1024 : n, got = FIO_ReadFile(f, bounce, (size_t)want);
        if (got <= 0) { ok = 0; break; }
        memcpy(d, bounce, (size_t)got);
        d += got; n -= got;
    }
    fio_free(bounce);
    FIO_CloseFile(f);
    return ok ? 0 : -1;
}

/* The preview's record, if it has one for the print now on the card: a
 * number reused after a reformat must not show the old picture. */
int se_pv_info(int no, char *film, size_t cap, int *size)
{
    char flm[FIO_MAX_PATH_LENGTH];
    static se_pv_head h;
    se_flm_path(no, flm, sizeof flm);
    if (pv_read(no, 0, &h, sizeof h) != 0 || h.magic != SE_PV_MAGIC) return -1;
    if (h.flm_bytes != file_size(flm)) return -1;
    h.film[sizeof h.film - 1] = 0;
    snprintf(film, cap, "%s", h.film);
    *size = h.size;
    return 0;
}

int se_pv_thumb(int no, uint8_t *dst) { return pv_read(no, 64, dst, SE_PV_TH); }
int se_pv_full(int no, uint8_t *dst)  { return pv_read(no, 64 + SE_PV_TH, dst, SE_PV_FULL); }

/* ---------------------------------------------------------- what is there */
uint16_t se_prints[SE_MAX_LIST], se_raws[SE_MAX_LIST];
int      se_nprints, se_nraws;

void se_flm_path(int no, char *buf, size_t cap) { snprintf(buf, cap, "%s/FLM_%04d.JPG", get_dcim_dir(), no); }
void se_cr2_path(int no, char *buf, size_t cap) { snprintf(buf, cap, "%s/%s%04d.CR2", get_dcim_dir(), get_file_prefix(), no); }

/* The four digits before the extension, or -1. */
int se_file_no(const char *name)
{
    int n = (int)strlen(name), i, v = 0;
    if (n < 8 || name[n - 4] != '.') return -1;
    for (i = n - 8; i < n - 4; i++) {
        if (name[i] < '0' || name[i] > '9') return -1;
        v = v * 10 + name[i] - '0';
    }
    return v;
}

/*
 * One walk of the shooting folder: names only, no stat of each file. A print
 * and a raw pair up by number, in a bit each, so a folder of thousands costs
 * the walk and no searching. Newest first in both lists.
 */
void se_walk_card(void)
{
    static uint8_t flm[1250], cr2[1250];
    struct fio_file *file = alloc_fio_file();
    struct fio_dirent *d;
    int no;

    memset(flm, 0, sizeof flm);
    memset(cr2, 0, sizeof cr2);
    se_nprints = se_nraws = 0;
    if (!file) return;
    d = FIO_FindFirstEx(get_dcim_dir(), file);
    if (IS_ERROR(d)) { free(file); return; }
    do {
        struct file_info fi = convert_fio_file_info(file);
        if (!fi.name[0] || (fi.mode & ATTR_DIRECTORY)) continue;
        no = se_file_no(fi.name);
        if (no < 0) continue;
        if (ends_with_ci(fi.name, ".CR2")) cr2[no >> 3] |= (uint8_t)(1 << (no & 7));
        else if (ends_with_ci(fi.name, ".JPG") && strncmp(fi.name, "FLM_", 4) == 0) flm[no >> 3] |= (uint8_t)(1 << (no & 7));
    } while (FIO_FindNextEx(d, file) == 0);
    FIO_FindClose(d);
    free(file);

    for (no = 9999; no >= 0; no--) {
        int f = (flm[no >> 3] >> (no & 7)) & 1, c = (cr2[no >> 3] >> (no & 7)) & 1;
        if (f && se_nprints < SE_MAX_LIST) se_prints[se_nprints++] = (uint16_t)no;
        if (c && !f && se_nraws < SE_MAX_LIST) se_raws[se_nraws++] = (uint16_t)no;
    }
}
