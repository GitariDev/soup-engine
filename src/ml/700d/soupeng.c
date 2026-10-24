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
 * Stage 1: find the films in ML/FILM and offer them in the menu. Nothing
 * here develops anything yet. The point of shipping this alone is to
 * learn, on the camera, that the module loads, the engine's parser runs,
 * the card reads and the config persists -- before the expensive part
 * is attempted on top of them.
 */
#include <module.h>
#include <dryos.h>
#include <menu.h>
#include <config.h>
#include <bmp.h>
#include <fio-ml.h>
#include <console.h>

#include "se.h"
#include "stock.h"

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

/* --------------------------------------------------------------- logging */

/* The engine never prints; it calls this. Magic Lantern's console is the
 * right place: it is visible from the menu and it costs no card writes. */
static void se_log_hook(void *ctx, const char *msg)
{
    printf("soup: %s\n", msg);
}

/* ------------------------------------------------------------ the films */

static int ends_with_fs(const char *n)
{
    size_t l = strlen(n);
    return l > 3 && n[l - 3] == '.'
        && (n[l - 2] | 0x20) == 'f' && (n[l - 1] | 0x20) == 's';
}

/* Read a small text file whole. buf gets a terminating NUL. */
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
        printf("soup: out of memory scanning films\n");
        if (text) fio_free(text);
        if (file) free(file);
        return;
    }

    d = FIO_FindFirstEx(dir, file);
    if (IS_ERROR(d)) {
        se_film_dir_missing = 1;
        printf("soup: no %s on the card\n", dir);
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
        if (!ends_with_fs(fi.name)) continue;
        if (se_nstocks >= SE_MAX_STOCKS) {
            printf("soup: more than %d films, ignoring the rest\n", SE_MAX_STOCKS);
            break;
        }

        snprintf(path, sizeof path, "%s/%s", dir, fi.name);
        if (read_text(path, text, SE_STOCK_TEXT, &n) != 0) {
            printf("soup: cannot read %s\n", fi.name);
            continue;
        }
        s = &se_stocks[se_nstocks];
        se_stock_init(s);
        if (se_stock_parse(text, n, s) != SE_OK) {
            printf("soup: cannot parse %s\n", fi.name);
            continue;
        }
        snprintf(se_stock_file[se_nstocks], sizeof se_stock_file[0], "%s", fi.name);
        se_nstocks++;
    } while (FIO_FindNextEx(d, file) == 0);

    FIO_FindClose(d);
    fio_free(text);
    free(file);

    se_sort_stocks();
    printf("soup: %d films in %s\n", se_nstocks, dir);
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

static MENU_UPDATE_FUNC(se_rescan_update)
{
    MENU_SET_VALUE("%d found", se_nstocks);
}

static MENU_SELECT_FUNC(se_rescan_select)
{
    se_scan_stocks();
}

/* The top-level line shows the chosen film without opening the submenu. */
static MENU_UPDATE_FUNC(se_top_update)
{
    if (se_nstocks && se_stock_index >= 0 && se_stock_index < se_nstocks)
        MENU_SET_VALUE("%s", se_stocks[se_stock_index].name);
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
                .name       = "Source",
                .priv       = &se_source,
                .max        = 1,
                .choices    = CHOICES("JPEG", "RAW"),
                .help       = "JPEG grades the preview DIGIC already made. Use this.",
                .help2      = "RAW works from the sensor data: slower, some adjustments unavailable.",
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

/* ------------------------------------------------------------- lifetime */

static unsigned int se_module_init(void)
{
    se_set_log(se_log_hook, NULL);

    se_stocks = malloc(sizeof(se_stock) * SE_MAX_STOCKS);
    if (!se_stocks) {
        printf("soup: cannot allocate %d bytes for the films\n",
               (int)(sizeof(se_stock) * SE_MAX_STOCKS));
        return 1;
    }
    se_scan_stocks();

    /* the Film entry's toggle range is the list's length */
    se_menu[0].children[0].max = se_nstocks > 0 ? se_nstocks - 1 : 0;

    menu_add("Shoot", se_menu, COUNT(se_menu));
    printf("soup: engine format %d, %d films, source %s\n",
           SE_STOCK_VERSION, se_nstocks, se_source ? "RAW" : "JPEG");
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

MODULE_CONFIGS_START()
    MODULE_CONFIG(se_stock_index)
    MODULE_CONFIG(se_source)
MODULE_CONFIGS_END()
