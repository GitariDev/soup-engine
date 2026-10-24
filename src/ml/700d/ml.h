/*
 * ml.h - everything this module asks of Magic Lantern, in one include.
 *
 * The module's sources include this and nothing else of Magic Lantern's,
 * so that tools/sim700d can stand in a header of the same name and run
 * the real sources on the desktop against a mock of the camera. Angle
 * brackets, not quotes: a quoted include resolves against this directory
 * first and could never be substituted.
 */
#ifndef SE700_ML_H
#define SE700_ML_H

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
#include <powersave.h>
#include <propvalues.h>     /* lv */
#include <gui-common.h>     /* display_is_on, is_play_mode, redraw */

#endif
