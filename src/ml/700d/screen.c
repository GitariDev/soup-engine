/*
 * screen.c - the label on the shooting screen, and the SET picker.
 */
#include "soupeng.h"

/*
 * Two things on Canon's shooting screen, both drawn on Magic Lantern's
 * bitmap layer over it.
 *
 * The label: one line at the bottom, "SOUP PROVIA quarter", redrawn once
 * a second from the watcher because Canon repaints its screen whenever
 * it likes. The progress line, while a frame is developing, takes the
 * same spot.
 *
 * The picker: SET, in shooting mode, opens a list of the films over the
 * screen with the current one highlighted; the up and down arrows move,
 * SET chooses, Trash or MENU cancels, a half-press of the shutter cancels
 * and still fires, and it closes by itself after a few idle seconds.
 * Under the films, two more rows: DEVELOP LAST SHOT queues the newest
 * raw and closes, and AUTO DEVELOP flips the watcher and stays open --
 * so a shot can be judged on the back screen before it is developed:
 * auto off, shoot, look, SET, develop the one that deserves it. SET
 * is free in shooting mode on this body -- Canon leaves it unassigned,
 * and Magic Lantern claims it only when its SET+MainDial tweak is on.
 * The main dial does not move it: in shooting mode Canon turns the dial
 * into exposure changes before it ever becomes a button event, so it
 * never reaches a module. The cases below keep it harmless if it does.
 */
static int se_pick_open, se_pick_sel, se_pick_idle;

#define SE_LABEL_X   10
#define SE_LABEL_Y   440

void se_draw_label(void)
{
    if (!se_nstocks || se_busy || se_pick_open) return;
    if (gui_menu_shown() || lv || is_play_mode() || !display_is_on()) return;
    if (se_stock_index < 0 || se_stock_index >= se_nstocks) se_stock_index = 0;
    bmp_printf(FONT(FONT_MED, COLOR_WHITE, COLOR_BLACK), SE_LABEL_X, SE_LABEL_Y,
               "SOUP %s  %s%s   ", se_stocks[se_stock_index].name, se_size_name(),
               se_auto ? "" : "  manual");
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
    bmp_printf(FONT(FONT_SMALL, COLOR_CYAN, COLOR_BLACK), SE_PICK_X + 20,
               SE_PICK_Y + 44 + SE_PICK_ROWS * SE_PICK_ROW, "%-56s", desc);
    bmp_printf(FONT(FONT_SMALL, COLOR_WHITE, COLOR_BLACK), SE_PICK_X + 20,
               SE_PICK_Y + h - 18, "UP/DOWN move   SET choose   TRASH cancel");
}

static void se_pick_close(int apply)
{
    if (apply) {
        se_stock_index = se_pick_sel;
        se_stock_id = (int)se_name_id(se_stocks[se_stock_index].name);
    }
    se_pick_open = 0;
    redraw();                       /* Canon paints its screen back */
    se_draw_label();
}

/* Once a second, from the watcher: the picker times out, or the label is
 * put back if Canon drew over it. */
void se_screen_tick(void)
{
    if (se_pick_open) {
        if (++se_pick_idle > 6) se_pick_close(0);
        else se_pick_draw(0);       /* Canon may have painted over it */
    } else {
        se_draw_label();
    }
}

/*
 * Every key, before Magic Lantern or Canon see it. Returning 0 keeps it.
 * The convention is Magic Lantern's game module's, which is the shipped
 * example of a module owning the keys.
 */
unsigned int se_key_cbr(unsigned int key)
{
    if (!se_pick_open) {
        if (key == MODULE_KEY_PRESS_SET && se_nstocks && !ml_shutdown_requested
            && !gui_menu_shown() && !lv && !is_play_mode() && display_is_on()) {
            se_pick_open = 1;
            se_pick_sel  = se_stock_index;
            se_pick_idle = 0;
            se_pick_draw(1);
            return 0;
        }
        return 1;
    }

    se_pick_idle = 0;
    switch (key) {
    case MODULE_KEY_WHEEL_UP:
    case MODULE_KEY_WHEEL_LEFT:
    case MODULE_KEY_PRESS_UP:
    case MODULE_KEY_PRESS_LEFT:
        se_pick_sel = (se_pick_sel + SE_PICK_ROWS - 1) % SE_PICK_ROWS;
        se_pick_draw(1);
        return 0;
    case MODULE_KEY_WHEEL_DOWN:
    case MODULE_KEY_WHEEL_RIGHT:
    case MODULE_KEY_PRESS_DOWN:
    case MODULE_KEY_PRESS_RIGHT:
        se_pick_sel = (se_pick_sel + 1) % SE_PICK_ROWS;
        se_pick_draw(1);
        return 0;
    case MODULE_KEY_PRESS_SET:
        if (se_pick_sel == SE_PICK_AUTO) {
            se_auto = !se_auto;             /* and stay open */
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
        return 0;
    case MODULE_KEY_UNPRESS_SET:
    case MODULE_KEY_UNPRESS_UDLR:
        return 0;                   /* the releases of keys we took */
    case MODULE_KEY_TRASH:
    case MODULE_KEY_MENU:
    case MODULE_KEY_Q:
    case MODULE_KEY_INFO:
    case MODULE_KEY_PLAY:
        se_pick_close(0);
        return 0;
    case MODULE_KEY_PRESS_HALFSHUTTER:
    case MODULE_KEY_PRESS_FULLSHUTTER:
        se_pick_close(0);
        return 1;                   /* and the shutter still fires */
    default:
        return 1;
    }
}
