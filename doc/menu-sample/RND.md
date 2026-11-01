# INFO menu for the EOS 700D: R&D notes

`index.html` is the design. This file is what each item would take on the
camera, and what was measured to say so. The layout follows the M-FILM menu
in the video by @hng.spl (5D Mark III); nothing of theirs was available to
read, so all of this comes from the video and from Soup Engine's own source.

## Where this stands

The Film screen, both toggles, the pending counter and the three fixes
below are built: `src/ml/700d/ui.c`, with the art in
`src/ml/700d/data/SOUPUI.BIN` from `src/tools/mkui.js`. It has run on the
camera. Home, Darkroom, Prints, Roll, Lens and System are built too and pass
the simulator, but have not run on a camera yet.

Prints went a different way from the plan below: photos are on the bitmap
layer through a colour cube palette, not Canon's YUV layer. The camera proved
the palette holds, the YUV route is unproven, and this keeps the half-press
working. It costs colour accuracy: a preview is dithered to 180 colours, good
for judging a frame, not for judging a grade. Lens name, ISO and the film of a
raw with no print are live values or the film in the camera.

What the first camera run showed, from `ML/LOGS/SOUPENG.LOG`:

| Question | Answer |
|:--|:--|
| Does the palette hold on the idle screen? | Yes. Canon reloaded it 0 times across 9 sessions, and the colours stayed right while frames developed |
| How long does a frame take? | Full frame 18-28 ms, one slide step 9-17 ms. Opening reads the pack in 150-190 ms |
| Does it fit beside a develop? | Yes, with no change in develop time: 39.7 and 40.3 s for a half-size frame |
| Which buttons arrive? | Left, right, down, Q, MENU and the half-press. SET, up and the dial were not pressed in that run |
| AE lock and AF point? | Never arrive, in either callback, so the toggles moved to PLAY and Trash |
| Does anything else draw on the screen? | Yes: Magic Lantern's flexinfo. It goes to the back buffer now, see `ui.c` |

The sections below are the plan as it was written.

## Verdicts

| Item | Verdict | What it takes | Still unknown |
|:--|:--|:--|:--|
| **Film** (replaces today's INFO list) | Build it | Sprite pack, a new `screen.c` draw path, new keys | Palette on the idle screen |
| **Auto develop, Quality toggles** | Build it | Two keys; the switches exist (`se_auto`, `se_size`) | Whether both buttons reach the module |
| **Pending counter** | Build it | `se_q_count()` and the progress line, both exist | Nothing |
| **Prints** | Worth building | Viewer on the YUV layer, a preview saved at develop | Play-mode drawing on this body |
| **Darkroom** | Worth building | Folder walk (`se_resume_cut` already does one) feeding the queue | Walk time on a full card |
| **Lens** | Easy | `lens_info.name` and friends | Nothing |
| **System** | Easy | Palette swap, rescan, `fake_simple_button(BGMT_MENU)` | Nothing |
| **Roll** | Easy, optional | Two config integers. A counter with no size: it starts again when a new film is loaded, and it never stops the shutter | Nothing |
| **Viewfinder** | Drop | The 700D has an optical finder and nothing can draw in it. `CONFIG_BEEP` is off on this body, so a wind reminder has no way out either | |
| **Touch** | Not yet | Magic Lantern reports that a finger touched, not where (`menu.c` turns any touch into Q) | Whether the event carries coordinates at all |

## Can the 700D draw this?

Yes, on the bitmap layer, without Canon's full-colour layer.

- The layer is 720x480, one byte a pixel, through a 256-entry palette of
  opacity, Y, U, V. Magic Lantern leaves entries 0, 3, 0x14 and 255 alone
  and keeps one for zebras; about 250 are free.
- Everything a module needs is in `700D_115.sym`: `LCD_Palette` and
  `EngDrvOut` to set entries, `bmp_draw_to_idle` and `bmp_idle_copy` to draw
  off screen and swap, and `canon_gui_disable_front_buffer` so Canon cannot
  paint over the menu, which is how Magic Lantern's own menu does it.
- **Tested here:** all 13 films and Home rendered from the sample at 720x480
  and reduced to one shared 250-colour palette with ordered dither. The
  result is 37.5 dB against true colour and reads the same at a glance.
  `8bit-check.png` shows it: true colour above, 8-bit below.
- Dithered art does not compress: a frame is 345,600 bytes raw and 644,978
  with RLE8. Sprites are stored raw, and the background is generated.
- Budget: 13 cans at 3 sizes is about 490 KB raw before the film leaders,
  read from one file when the menu opens. That is too much for malloc (137
  KB free in the card's log), so it goes through `fio_malloc`, the same
  place a develop gets its 768 KB of buffers and, through `__mem_malloc`, its
  1.5 MB arena. That memory prefers Canon's shoot pool, which has to be
  handed back before some Canon settings change, so the sprites are freed
  when the menu closes.
- Speed: the camera's own benchmark reads cached memory at about 90 MB/s and
  uncached at about 21 MB/s, so a full repaint is tens of milliseconds. A
  three-step slide (Motion: Stepped in the sample) is the honest target
  until it is timed on the camera. Keep to stepped while a frame develops.

The palette is the one real risk. Magic Lantern's own code re-applies its
palette at least once a second because Canon can reset it, and the entries
must be put back from `LCD_Palette[3*i + 2]` on close or Canon's screens
come back in the wrong colours.

## Buttons

Seen on the camera: left, right, down, Q, MENU, the half-press, and from the
old list up, SET, Trash and INFO. PLAY and the dial have not been confirmed.

| Button | Film screen | Reaches the module as |
|:--|:--|:--|
| ◄ ► | Films | `MODULE_KEY_PRESS_LEFT/RIGHT` |
| Main dial | Films | `MODULE_KEY_WHEEL_*`; **never confirmed in shooting mode** |
| ▲ ▼ | Shelves | `MODULE_KEY_PRESS_UP/DOWN` |
| SET | Load | `MODULE_KEY_PRESS_SET` |
| PLAY | Auto develop | `MODULE_KEY_PLAY` |
| Trash | Quality | `MODULE_KEY_TRASH` |
| Q | Develop last shot | `MODULE_KEY_Q` |
| MENU | Close; Home once it is built | `MODULE_KEY_MENU` |
| AE lock, AF point | Canon's | Nothing arrives; `se_ui_saw_raw` logs any unnamed event |
| INFO | Close, on to Canon | `MODULE_KEY_INFO`, passed on |
| Half-press | Close and shoot | `MODULE_KEY_PRESS_HALFSHUTTER`, passed on |

PLAY and Trash sit side by side on the back of the camera, so the left button
is the left toggle and the right button the right one.

## Prints

Canon's playback is the cheap thing to rule out first: shoot a frame, turn
the camera off and on, press PLAY. If `FLM_` files show, zoom and histogram
come free. Our EXIF has no thumbnail, which may be why they would not.

Otherwise the viewer is ours. `engine/jpeg_dec.c` was tried on nine real
files from the camera, 4:2:0 and 4:4:4, and read them all. Calibration: the
frame the camera benchmarked decodes in 14.2 s there and 40.7 ms on this
Mac, about 350 times slower, so these are estimates, not camera timings:

| Print | File size | Decoded to | Mac | Camera, estimated |
|:--|:--|:--|:--|:--|
| Quarter | 90–200 KB | 648x432 at 1/2 | 1.8–3.4 ms | 0.6–1.2 s |
| Half | 290–1070 KB | 648x432 at 1/4 | 5.4–16 ms | 1.9–5.6 s |
| Full | 2.8 MB | 1296x864 at 1/4 | 45 ms | 16 s, then a 2:1 reduction |
| Saved preview | 21 KB | 648x432 at 1/1 | 0.9 ms | 0.3 s |

That last row is the design. Flipping through frames at 4 seconds each is not
a viewer, so a 648x432 preview is saved beside each print while it develops.
The rows are already passing through, and at the measured encode rate it
adds about 0.7 s to a frame. Frames without one fall back to decoding the
JPEG, as "Prints: Decode the JPEG each time" in the sample shows. A contact
sheet needs smaller thumbnails again, since six decodes would be a wait.

Showing true colour needs the YUV layer, which only exists in play mode:
`enter_play_mode`, then `get_yuv422_vram`, which is what `pic_view` does.
Half-press leaves play mode by itself, so a picture is still never lost to
the menu. A decode needs the arena and the CPU the worker is using, so a
print cannot open at full speed during a develop; the viewer should say so.

## Three things the new menu exposes

These were in the module and matter more once the counter is on screen.
All three are fixed. With no Darkroom yet, a burst past 8 frames waits in
the watcher and is queued as room appears, and the counter includes it.

| Before | Where | Now |
|:--|:--|:--|
| A frame takes whatever film and size are selected when its turn comes, not what it was shot with. Five frames waiting, load VELVIA, and they all come out VELVIA | `se_develop_job`, `watch.c:178` | `se_job` keeps the film and size from when the frame was queued |
| A burst past 8 frames: the rest are logged and never developed, and the counter moves on so nothing comes back for them | `se_watch_cbr`, `watch.c:137` | They are queued as room appears; a Darkroom list comes later |
| `NotifyBox` announces each finished frame, and would draw over the menu in the wrong colours | `se_develop_job`, `watch.c:206` | Silent while the menu is open; the counter says it |

## Order of work

1. One camera run to answer the unknowns: does a palette hold on the idle
   screen, how long does a repaint take, do AE lock, AF point, Q and the dial
   arrive, does a touch carry a position, and do `FLM_` files show in PLAY.
2. A sprite tool that turns the design JSON into `ML/DATA/SOUPUI.BIN`.
   A `.fs` file not in the pack gets a plain can at the end of the row, so
   dropping a new film on the card keeps working with no rebuild.
3. The Film screen in `screen.c`, with its tests in `tools/sim700d`.
4. The queue changes above, then Prints and Darkroom.

## Notes for sharing

- ISO on a can is only a label, as `FILM SPEED` is on the 5D. PORTRA, GOLD,
  PROVIA, VELVIA, ACROS and SOUP 800 take theirs from the film's name or
  `.fs` notes. The other seven are guesses. Film files have no brand, shelf,
  ISO or process, so all four live in the design and are editable there.
- Cans carry brand names as shorthand, like the film names themselves. The
  brand line is one field per film in the Edit tab.
- The photos are `doc/stocks.jpg`, the engine's real output, and already
  public in the repository.
