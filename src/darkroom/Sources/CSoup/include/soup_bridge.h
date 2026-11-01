/*
 * soup_bridge.h - what Swift sees of the engine.
 *
 * The engine's own headers are left out of Swift's view: they are written for
 * a camera and speak in arenas and row callbacks. This is the desktop's
 * vocabulary: a frame's facts, a film, a negative held in memory, a picture,
 * a print. Files are only ever opened for reading, except the print's own
 * output, which goes to a path the caller gave.
 */
#ifndef SOUP_BRIDGE_H
#define SOUP_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

/* The engine's tables are built on first use. Call once before any threads. */
void sb_warm_up(void);

/* ------------------------------------------------- a frame, without decoding */
typedef struct {
    int   width, height;     /* what a full print will be, before rotation */
    int   orientation;       /* EXIF 1..8, 1 when the file does not say    */
    char  make[32];
    char  model[64];
    char  datetime[24];      /* "YYYY:MM:DD HH:MM:SS", empty if unknown    */
    float exposure_time;     /* seconds                                    */
    float aperture;
    int   iso;
} sb_cr2_facts;

/* 0, or -1 if this is not a CR2 the engine understands. */
int sb_cr2_probe(const char *path, sb_cr2_facts *out);

/*
 * The JPEG embedded in the CR2, as RGB8, at 1/scale size with scale 1, 2, 4
 * or 8. Malloc'd; free with sb_free. Not rotated. Returns 0 or -1.
 */
int sb_cr2_embedded(const char *path, int scale, uint8_t **rgb, int *w, int *h);

/* A JPEG's EXIF Software tag: a print's film. 0, or -1 if it has none. */
int sb_jpeg_software(const char *path, char *out, size_t cap);

void sb_free(void *p);

/* ------------------------------------------------------------------ a film */
typedef struct sb_film sb_film;

/* Parse a .fs file. NULL if it is not one the engine accepts. */
sb_film    *sb_film_load(const char *path);
void        sb_film_free(sb_film *f);
const char *sb_film_name(const sb_film *f);
const char *sb_film_desc(const sb_film *f);

/* -------------------------------------------- a negative, decoded and held */
typedef struct sb_negative sb_negative;

/* Decode the sensor data once. NULL if the file cannot be read as a CR2. */
sb_negative *sb_negative_open(const char *path);
void         sb_negative_close(sb_negative *n);

/* The size a render comes out at, for a scale of 1, 2 or 4. */
void sb_negative_size(const sb_negative *n, int scale, int *w, int *h);

/*
 * The sensor data through se_develop, then the film through se_look_*, as
 * `filmdev looks --from-raw` does. `film` NULL is the straight raw with no
 * look. Fills width*height*3 bytes of RGB8, not rotated. A non-zero *cancel
 * stops it at the next row; a NULL cancel is never cancelled.
 *
 * Any number of these may run at once, on different threads.
 */
int sb_render(const sb_negative *n, const sb_film *film, int scale,
              uint8_t *rgb, const volatile int *cancel);

/*
 * The same develop, written as a JPEG to `out_path`, which is created or
 * truncated: the caller gives a temporary name and moves it into place.
 * `scale` 1 is the full 5184x3456. `orientation` goes into the EXIF. The
 * film's name goes into the Software tag, as on the camera. Returns 0, -1 on
 * failure, or 1 if cancelled. A failed or cancelled print leaves no file.
 */
int sb_print(const sb_negative *n, const sb_film *film, int scale, int quality,
             int orientation, const char *out_path, const volatile int *cancel);

#endif /* SOUP_BRIDGE_H */
