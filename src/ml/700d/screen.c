/*
 * screen.c - the label on the shooting screen, and the INFO picker.
 */
#include "soupeng.h"

/*
 * Two things on Canon's shooting screen, both drawn on Magic Lantern's
 * bitmap layer over it.
 *
 * The status line: one line at the bottom right, "SOUP PROVIA quarter",
 * redrawn once a second from the watcher because Canon repaints its
 * screen whenever it likes. While a frame is developing the same line
 * is its progress and the count behind it. Above it, in red, a warning
 * when Magic Lantern's Advanced
 * Bracket is on: that feature sits at the top of the same Shoot menu as
 * this module, one SET press turns it on, and from then on every press
 * of the shutter takes a whole sequence. The first field test lost five
 * frames to it before anyone knew where to look.
 *
 * The picker: INFO, on the bare shooting screen, opens a list of the
 * films over it with the current one highlighted; the wheel or the
 * arrows move, SET chooses a film or flips the AUTO row, Trash or MENU
 * cancels, a half-press of the shutter cancels and still fires, and it
 * closes by itself after a few idle seconds. INFO again closes it and
 * goes on to Canon: the picker is the first stop of Canon's own INFO
 * cycle -- shooting screen, this list, then Canon's camera-settings
 * screen and the rest -- and a press of INFO always moves on, so
 * nothing is ever more than a press away.
 *
 * SET only ever chooses, inside the open list. It opened the list too,
 * in two builds: SET is what Canon's Q screen and Canon's menu use to
 * open and confirm things, and the field tests found the picker opening
 * over both. Outside the open picker the module leaves SET alone. INFO
 * has no job on the shooting screen but its cycle, and this slots in.
 *
 * The picker opens only on the bare shooting screen: gui_state idle, no
 * dialog of Canon's up, display on, no live view, no playback, no Magic
 * Lantern menu. In Canon's menu, the Q screen, the ISO screen and the
 * rest, INFO is Canon's. Whether Canon's camera-settings INFO screen
 * counts as a dialog on this body is not known: if it does not, INFO
 * there opens the picker again, and the next INFO moves on as before.
 *
 * Whether the main dial reaches a module on the idle shooting screen is
 * not settled either: Canon may turn it into exposure changes before it
 * is a button event. The wheel cases are here either way, and the
 * arrows always work.
 *
 * Under the films, two more rows: DEVELOP LAST SHOT queues the newest
 * raw and closes, and AUTO DEVELOP flips the watcher and stays open --
 * so a shot can be judged on the back screen before it is developed:
 * auto off, shoot, look, INFO, SET, develop the one that deserves it.
 *
 * While it is open the picker is modal: every button Magic Lantern has
 * a name for is the picker's, and one it does not use closes it and
 * goes no further. On this body's idle screen the arrows are ISO, drive,
 * AF and white balance, the zoom-in button is AF point selection, the
 * zoom-out button is AE lock, LV starts live view and a touch opens
 * Canon's touch menu; none of those may happen under the list. The two
 * exceptions are INFO, which closes it and goes on to Canon's next
 * screen, and the half-press of the shutter, which closes it and still
 * focuses and fires: a picture is never lost to a menu.
 *
 * Magic Lantern gives modules the presses of the arrows and the zoom
 * buttons but not their releases, and the zoom-out button not at all,
 * so a second callback sees the raw events and finishes the job: the
 * release of a press the picker took is swallowed too, so Canon sees
 * pairs or nothing, and the zoom-out press is taken while the list is
 * open. Everything else in the raw stream -- Canon's own notifications
 * among them -- is left alone.
 */
static int se_pick_open, se_pick_sel, se_pick_idle;
static int se_set_taken;        /* a SET press chose; its release is ours too */

/* Raw button codes whose press the picker took; the release is taken
 * when it comes, whether or not the picker is still open. */
static uint8_t se_taken[128];

/*
 * The status line lives at the bottom RIGHT, anchored to its right end,
 * where Canon's shooting screen keeps nothing it repaints: at the bottom
 * left it sat over Canon's own text. A line anchored on the right grows
 * leftwards, so a shorter line would leave the head of a longer one
 * standing; each line is padded on the left to the length of the one
 * before it, which wipes exactly what was there and nothing more. The
 * bracket warning takes the row above, the same way.
 */
#define SE_BOTTOM_X  710
#define SE_BOTTOM_Y  440
#define SE_WARN_Y    416
#define SE_LINE_MAX  60

static void se_bottom(const char *text, int color, int y, int *last_len)
{
    char line[SE_LINE_MAX + 1];
    int n = (int)strlen(text), pad = *last_len > n ? *last_len - n : 0;
    if (n > SE_LINE_MAX) n = SE_LINE_MAX;
    if (pad > SE_LINE_MAX - n) pad = SE_LINE_MAX - n;
    memset(line, ' ', (size_t)pad);
    memcpy(line + pad, text, (size_t)n);
    line[pad + n] = 0;
    *last_len = n;
    bmp_printf(FONT(FONT_MED, color, COLOR_BLACK) | FONT_ALIGN_RIGHT, SE_BOTTOM_X, y, "%s", line);
}

/*
 * The film, the size and manual when auto is off; or, while a frame
 * develops, its stage, its percentage and how many frames wait behind
 * it. Drawn once a second from the watcher, at every fifth percent from
 * the develop, and whenever the picker closes -- Canon repaints its
 * screen after every shot, which is exactly when the queue is longest,
 * and a line drawn only at percentage steps was missing for the first
 * quarter minute of every frame.
 */
void se_draw_status(void)
{
    static int status_len, warn_len;
    char text[80];
    if (!se_nstocks || se_pick_open) return;
    if (gui_menu_shown() || lv || is_play_mode() || !display_is_on()) return;
    if (se_stock_index < 0 || se_stock_index >= se_nstocks) se_stock_index = 0;
    if (se_busy) {
        char prog[48];
        se_count_waiting();
        se_progress_text(prog, sizeof prog);
        snprintf(text, sizeof text, "SOUP %s %s", se_stocks[se_stock_index].name, prog);
    } else {
        snprintf(text, sizeof text, "SOUP %s  %s%s", se_stocks[se_stock_index].name,
                 se_size_name(), se_auto ? "" : "  manual");
    }
    se_bottom(text, COLOR_WHITE, SE_BOTTOM_Y, &status_len);
    if (is_hdr_bracketing_enabled())
        se_bottom("ML BRACKET ON", COLOR_RED, SE_WARN_Y, &warn_len);
    else if (warn_len)
        se_bottom("", COLOR_RED, SE_WARN_Y, &warn_len);     /* wipe it once */
}

/* The bare shooting screen: Canon idle, no dialog of Canon's or Magic
 * Lantern's over it. The only place the picker opens. */
static int se_shooting_screen(void)
{
    return se_nstocks && !ml_shutdown_requested && !gui_menu_shown() && !lv
        && !is_play_mode() && display_is_on()
        && gui_state == GUISTATE_IDLE && get_gui_mode() == 0;
}

#define SE_PICK_X   60
#define SE_PICK_Y   8
#define SE_PICK_W   600
#define SE_PICK_ROW 24
#define SE_PICK_DEVELOP (se_nstocks)        /* the two rows under the films */
#define SE_PICK_AUTO    (se_nstocks + 1)
#define SE_PICK_ROWS    (se_nstocks + 2)

/*
 * `full` paints the box and border as well as the text: on opening and
 * on every key. The once-a-second repaint -- there in case Canon drew
 * its screen over the picker -- re-stamps only the text, in place, which
 * is invisible when nothing changed. Filling the box each second was a
 * visible flicker.
 */
static void se_pick_draw(int full)
{
    int i, h = 70 + SE_PICK_ROWS * SE_PICK_ROW + 20;
    const char *desc;
    if (full) {
        bmp_fill(COLOR_BLACK, SE_PICK_X, SE_PICK_Y, SE_PICK_W, h);
        bmp_draw_rect(COLOR_WHITE, SE_PICK_X, SE_PICK_Y, SE_PICK_W, h);
    }
    bmp_printf(FONT(FONT_MED, COLOR_WHITE, COLOR_BLACK), SE_PICK_X + 20, SE_PICK_Y + 8, "FILM");
    for (i = 0; i < SE_PICK_ROWS; i++) {
        int y = SE_PICK_Y + 40 + i * SE_PICK_ROW;
        uint32_t f = (i == se_pick_sel) ? FONT(FONT_MED, COLOR_BLACK, COLOR_WHITE)
                                        : FONT(FONT_MED, COLOR_WHITE, COLOR_BLACK);
        if (i < se_nstocks)
            bmp_printf(f, SE_PICK_X + 20, y, " %s%s ", se_stocks[i].name,
                       i == se_stock_index ? "  *" : "");
        else if (i == SE_PICK_DEVELOP)
            bmp_printf(f, SE_PICK_X + 20, y, " DEVELOP LAST SHOT ");
        else
            bmp_printf(f, SE_PICK_X + 20, y, " AUTO DEVELOP  %s ", se_auto ? "ON " : "OFF");
    }
    if (se_pick_sel < se_nstocks)      desc = se_stocks[se_pick_sel].desc;
    else if (se_pick_sel == SE_PICK_DEVELOP) desc = "Develop the newest raw with the film marked *";
    else desc = se_auto ? "Every shot is developed as it is taken"
                        : "Shots are kept raw until you ask";
    {
        /* padded by hand to a fixed width, so a short description wipes
         * a long one: Canon's printf has no field widths */
        char d[64];
        int n = snprintf(d, sizeof d, "%s", desc);
        if (n < 0 || n > 56) n = 56;
        while (n < 56) d[n++] = ' ';
        d[n] = 0;
        bmp_printf(FONT(FONT_SMALL, COLOR_CYAN, COLOR_BLACK), SE_PICK_X + 20,
                   SE_PICK_Y + 44 + SE_PICK_ROWS * SE_PICK_ROW, "%s", d);
    }
    bmp_printf(FONT(FONT_SMALL, COLOR_WHITE, COLOR_BLACK), SE_PICK_X + 20,
               SE_PICK_Y + h - 18, "WHEEL/ARROWS move   SET choose   TRASH cancel   INFO next");
}

static void se_pick_show(void)
{
    se_pick_open  = 1;
    se_pick_sel   = se_stock_index;
    se_pick_idle  = 0;
    se_pick_draw(1);
}

static void se_pick_close(int apply)
{
    if (apply) {
        se_stock_index = se_pick_sel;
        se_stock_id = (int)se_name_id(se_stocks[se_stock_index].name);
    }
    se_pick_open = 0;
    redraw();                       /* Canon paints its screen back */
    se_draw_status();
}

/* What SET does on the highlighted row. The AUTO row is a switch to
 * look at, so the picker stays open for it. */
static void se_pick_choose(void)
{
    if (se_pick_sel == SE_PICK_AUTO) {
        se_auto = !se_auto;
        se_pick_draw(1);
    } else if (se_pick_sel == SE_PICK_DEVELOP) {
        char cr2[FIO_MAX_PATH_LENGTH];
        se_pick_close(0);
        if (se_newest_cr2(cr2, sizeof cr2) == 0 && se_q_push(cr2, 1))
            NotifyBox(1000, "Soup: developing %s", cr2 + strlen(get_dcim_dir()) + 1);
        else
            NotifyBox(1500, "Soup: no raw to develop");
    } else {
        se_pick_close(1);
    }
}

/* Once a second, from the watcher: the picker times out, or the label is
 * put back if Canon drew over it. */
void se_screen_tick(void)
{
    if (se_pick_open) {
        if (++se_pick_idle > 6) se_pick_close(0);
        else se_pick_draw(0);       /* Canon may have painted over it */
    } else {
        se_draw_status();
    }
}

static int se_key_moves(unsigned int key, int *dir)
{
    switch (key) {
    case MODULE_KEY_WHEEL_UP:   case MODULE_KEY_WHEEL_LEFT:
    case MODULE_KEY_PRESS_UP:   case MODULE_KEY_PRESS_LEFT:
        *dir = -1; return 1;
    case MODULE_KEY_WHEEL_DOWN: case MODULE_KEY_WHEEL_RIGHT:
    case MODULE_KEY_PRESS_DOWN: case MODULE_KEY_PRESS_RIGHT:
        *dir = 1; return 1;
    }
    return 0;
}

/* The raw press behind a module key whose release Magic Lantern does
 * not hand to modules, or -1. */
static int se_raw_press(unsigned int key)
{
    switch (key) {
    case MODULE_KEY_PRESS_UP:       return BGMT_PRESS_UP;
    case MODULE_KEY_PRESS_DOWN:     return BGMT_PRESS_DOWN;
    case MODULE_KEY_PRESS_LEFT:     return BGMT_PRESS_LEFT;
    case MODULE_KEY_PRESS_RIGHT:    return BGMT_PRESS_RIGHT;
    case MODULE_KEY_PRESS_ZOOMIN:   return BGMT_PRESS_ZOOM_IN;
    case MODULE_KEY_TOUCH_1_FINGER: return BGMT_TOUCH_1_FINGER;
    case MODULE_KEY_TOUCH_2_FINGER: return BGMT_TOUCH_2_FINGER;
    }
    return -1;
}

/* The raw press a raw release belongs to, or -1. */
static int se_press_of(int code)
{
    switch (code) {
    case BGMT_UNPRESS_UP:        return BGMT_PRESS_UP;
    case BGMT_UNPRESS_DOWN:      return BGMT_PRESS_DOWN;
    case BGMT_UNPRESS_LEFT:      return BGMT_PRESS_LEFT;
    case BGMT_UNPRESS_RIGHT:     return BGMT_PRESS_RIGHT;
    case BGMT_UNPRESS_ZOOM_IN:   return BGMT_PRESS_ZOOM_IN;
    case BGMT_UNPRESS_ZOOM_OUT:  return BGMT_PRESS_ZOOM_OUT;
    case BGMT_UNTOUCH_1_FINGER:  return BGMT_TOUCH_1_FINGER;
    case BGMT_UNTOUCH_2_FINGER:  return BGMT_TOUCH_2_FINGER;
    }
    return -1;
}

static void se_take(int raw_press)
{
    if (raw_press >= 0 && raw_press < (int)sizeof se_taken) se_taken[raw_press] = 1;
}

/*
 * Every raw event, after se_key_cbr has let it through. Returning 0
 * keeps it. Two jobs: the releases of presses the picker took, and the
 * zoom-out button, which Magic Lantern does not translate for modules.
 */
unsigned int se_raw_cbr(se_ctx_t ctx)
{
    struct event *ev = (struct event *)ctx;
    int code = ev->param, press;

    if (code < 0 || code >= (int)sizeof se_taken) return 1;
    press = se_press_of(code);
    if (press >= 0) {
        if (!se_taken[press]) return 1;
        se_taken[press] = 0;
        return 0;
    }
    if (se_pick_open && code == BGMT_PRESS_ZOOM_OUT) {
        se_take(code);
        se_pick_close(0);
        return 0;
    }
    return 1;
}

/*
 * Every key, before Magic Lantern or Canon see it. Returning 0 keeps it.
 * The convention is Magic Lantern's game module's, which is the shipped
 * example of a module owning the keys. A key Magic Lantern has no name
 * for arrives as 0 and is never ours.
 */
unsigned int se_key_cbr(unsigned int key)
{
    int dir;

    if (key == 0) return 1;

    if (!se_pick_open) {
        if (key == MODULE_KEY_UNPRESS_SET && se_set_taken) {
            se_set_taken = 0;       /* the release of a press that chose */
            return 0;
        }
        if (key == MODULE_KEY_INFO && se_shooting_screen()) {
            se_pick_show();
            return 0;
        }
        return 1;                   /* SET and everything else: Canon's */
    }

    se_pick_idle = 0;
    if (se_key_moves(key, &dir)) {
        se_pick_sel = (se_pick_sel + SE_PICK_ROWS + dir) % SE_PICK_ROWS;
        se_take(se_raw_press(key));
        se_pick_draw(1);
        return 0;
    }
    switch (key) {
    case MODULE_KEY_PRESS_SET:
        se_set_taken = 1;
        se_pick_choose();
        return 0;
    case MODULE_KEY_UNPRESS_SET:
        if (!se_set_taken) return 1;
        se_set_taken = 0;
        return 0;
    case MODULE_KEY_UNPRESS_UDLR:
        return 0;                   /* the releases of arrows we took */
    case MODULE_KEY_INFO:
        se_pick_close(0);
        return 1;                   /* on to Canon's next INFO screen */
    case MODULE_KEY_PRESS_HALFSHUTTER:
    case MODULE_KEY_PRESS_FULLSHUTTER:
        se_pick_close(0);
        return 1;                   /* the shot is taken */
    case MODULE_KEY_UNPRESS_HALFSHUTTER:
    case MODULE_KEY_UNPRESS_FULLSHUTTER:
    case MODULE_KEY_UNTOUCH_1_FINGER:
    case MODULE_KEY_UNTOUCH_2_FINGER:
        return 1;                   /* releases: se_raw_cbr pairs them */
    default:
        /* TRASH, MENU, Q, PLAY, LV, zoom-in, a touch, anything else
         * with a name: the picker closes and the button goes no
         * further. Its release, if it has one, is taken when it comes. */
        se_take(se_raw_press(key));
        se_pick_close(0);
        return 0;
    }
}
