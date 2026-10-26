/*
 * soupeng.h - what the module's four files share.
 *
 *   soupeng.c   the films, the menu, the config, the module's lifetime
 *   develop.c   one frame: the preview out of the raw, the look, the JPEG
 *   watch.c     the queue, the watcher that fills it, the worker that drains it
 *   screen.c    the label on the shooting screen and the SET picker
 *
 * Everything here is module-global on purpose: the four files are one
 * program that happens to be in four pieces, and Magic Lantern links the
 * module as a single relocatable object. The se_ prefix keeps the names
 * clear of Magic Lantern's own symbol table, into which every global of
 * a module is exported.
 */
#ifndef SE700_SOUPENG_H
#define SE700_SOUPENG_H

#include <ml.h>

#include "se.h"
#include "stock.h"
#include "cr2.h"
#include "lut.h"
#include "jpeg_dec.h"
#include "jpeg_enc.h"
#include "look.h"

#define SE_MAX_STOCKS   32

/* ---------------------------------------------------------- the films */
extern se_stock *se_stocks;                /* SE_MAX_STOCKS of them, sorted */
extern int       se_nstocks;
extern int       se_stock_index;           /* the live selection            */
extern int       se_stock_id;              /* FNV-1a of its name, saved     */
extern int       se_size;                  /* 0 half, 1 full, 2 quarter     */
extern int       se_auto;                  /* develop every shot            */

int         se_scale(void);                /* se_size as a decode scale     */
const char *se_size_name(void);
uint32_t    se_name_id(const char *name);  /* what se_stock_id holds        */

/* ----------------------------------------------------------- logging */
void se_logf(const char *fmt, ...);
void se_log_flush(void);

/* ------------------------------------------------------------- utils */
#define FNV_INIT 2166136261u
uint32_t se_hash_bytes(uint32_t h, const void *p, int n);
int      ends_with_ci(const char *n, const char *ext);
uint32_t file_size(const char *path);      /* 0 if it does not exist        */

/* ------------------------------------------------------- the develop */
typedef struct {
    int      ow, oh, scale;
    int      bytes;
    uint32_t hash;
    int      ms_hdr, ms_read, ms_stream, ms_total;
    size_t   arena_peak;
    int      aborted;                      /* power-off during the frame    */
} se_result;

extern volatile int se_busy;               /* a frame is being developed    */
extern const char  *se_stage;              /* its progress, for the screen  */
extern int          se_pct;
extern int          se_waiting;            /* frames queued behind it       */
extern char         se_status[64];         /* what the last develop did     */
extern int          se_done, se_failed;    /* this session                  */

se_err se_develop_preview(const char *cr2_path, const char *out_path,
                          const se_stock *st, int scale, se_result *R);
void   se_progress_hook(void *ctx, const char *stage, int pct);
int    se_progress_text(char *buf, size_t cap);   /* "stream 45%, 3 waiting" */
void   se_count_waiting(void);                    /* se_waiting, read live   */
int    se_newest_cr2(char *out, size_t cap);
void   se_out_name(const char *cr2, char *out, size_t cap);

/* --------------------------------------------------------- the queue */
#define SE_QUEUE 8

typedef struct {
    char     path[FIO_MAX_PATH_LENGTH];
    uint32_t size;          /* last size seen                        */
    int      stable;        /* looks at which the size did not change */
    int      age;           /* looks since queued                     */
    int      ready;         /* 1 develop it, -1 skip it, 0 not yet    */
    int      force;         /* asked for by hand: overwrite, no checks */
} se_job;

extern se_job       se_q[SE_QUEUE];
extern volatile int se_q_head, se_q_tail;  /* indices, never wrap           */

int     se_q_count(void);
se_job *se_q_push(const char *path, int force);     /* once per path */
void    se_resume_cut(void);                        /* at power-on   */

unsigned int se_watch_cbr(unsigned int ctx);     /* once a second         */
void         se_worker_task(void *arg);          /* for the whole session */

/* -------------------------------------------------------- the screen */
void         se_draw_status(void);               /* film, or progress     */
void         se_screen_tick(void);               /* from the watcher      */
unsigned int se_key_cbr(unsigned int key);       /* translated keys     */
unsigned int se_raw_cbr(se_ctx_t ctx);           /* then the raw events */

#endif
