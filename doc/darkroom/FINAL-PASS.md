# Final pass

Run these in order. Every command starts from the worktree's `src` folder:

    cd /Users/gitaritirima/.t3/worktrees/soup-engine/feature-darkroom-desktop/src

## What nobody has verified yet

These could not be checked here, so check them first.

1. **The roll file on a real camera.** It has only run in the simulator. No
   `SOUPROLL.TXT` has been written by a 700D.
2. **The module's full build.** `watch.c` was cross-compiled against the real Magic
   Lantern headers and all its firmware imports are in `700D_115.sym`. `soupeng.c`
   was not, in its final form, and `soupeng.mo` has not been built or loaded.
3. **Card reads during shooting.** Whether a line written while Canon is busy slows
   anything down, and what the roll costs on the shoot task, are unmeasured.
4. **A hand on the mouse.** The wipe, cans and strip were driven with events
   delivered to the views. Real menus, open panels, Cmd-O, Cmd-P, Cmd-Shift-P, typing
   in Name, trackpad scrolling and Space while Name has focus were not driven.
5. **The green card chip with ROLL in it.** The real card has no roll file yet, and
   the fixture opens as a folder, so `● EOS_DIGITAL · 700D · ROLL n` has not been seen.
6. **Pulling a real card mid-work.** Tried only on a mounted exFAT image.

## 1. First launch

    make darkroom
    open "out/Soup Darkroom.app"

- macOS asks to let Soup Darkroom read a removable volume. Allow it. Every rebuild
  is a new ad hoc identity, so expect it to ask again after a `make darkroom`.
- The window appears at once, even before you answer. That was a real bug and it is
  fixed, but the answered prompt on this exact build has not been seen.
- You should see `EOS_DIGITAL · 700D` in green, "Card found. 2 frames, 13 films."
  and the shelf opening on Portra.
- If you refuse, the bench says macOS has not let it read the card, and where to
  change that. Returning to the app tries again.

## 2. Find and choose, on your card

- Click 4230. The picture goes from a drained DEVELOPING to the film, under a
  second once read. The first read off the card takes about 2.5 s.
- The tray says `PRINTED · ETERNA` and "Redevelop to folder".
- Click the Velvia can. The picture changes at once, a wipe appears, and the tray
  says `YOUR CHOICE · VELVIA`.
- Hold Space: the Eterna picture. Let go: back. Drag the line across.
- Press up and down for films, left and right for frames.
- Type in the Name field, including a space. It must type and not trigger the compare.
- Cmd-O opens a picker for any folder or a single CR2.

## 3. Print

- Click "Redevelop to folder". The first print creates `~/Pictures/Soup Prints`.
- A green line names the file. Show in Finder finds it.
- Open it: 5184x3456, on Velvia. The card is unchanged.
- Print it again: `-2`, nothing overwritten.
- In Save to, choose a folder on the card. It must refuse and say why.

To check the card afterwards, this must list only `soupeng.mo` and `SOUPUI.BIN`,
your own install:

    find /Volumes/EOS_DIGITAL -type f -newermt "2026-11-01 00:00:00"

## 4. Every state, on a fixture

This builds a card from your samples in `out/bench-card`, an ignored folder, and
checks its own counts:

    S="/Users/gitaritirima/Documents/Workspace/Personal Projects/soup-engine/src/samples/t5i"
    make bench S="$S"
    open -n "out/Soup Darkroom.app" --args --open "$PWD/out/bench-card"

You should see ALL 30, SHOT ON 16, PRINTED 2, YOUR CHOICE 0 or 1, NO RECORD 12 and
NOT DEVELOPED 28. These use your real record and save folder, so use a test folder
in Save to here.

- **No record:** the tray says why, "No film yet", Print is held, and Space shows the
  straight raw. IMG_3994 has two conflicting roll lines and stays No record.
- **Not developed:** 28 frames. IMG_3992 has a zero-byte `FLM_` and is in the tab.
  IMG_3984 has only a Canon JPEG and is in the tab. FLM_3991 and FLM_4013 are out.
  It is a tab, not a state, so it does not add into All.
- **Work the tab down:** "Print these 15 on their films", with the destination and
  "13 wait for a film" beside it. Pick cans for the rest. It should end on "Every
  frame here is developed."
- **NO CAN:** IMG_4010's film, Kodachrome 64, is not on the shelf. Print waits.
- **Portrait:** IMG_4019 and IMG_4020 stand upright, and their prints do too.

## 5. The roll on the camera

The module build needs Magic Lantern's source, which is only in your main checkout.
This points the worktree at it. I have not run this step.

    ln -s "/Users/gitaritirima/Documents/Workspace/Personal Projects/soup-engine/src/vendor" vendor
    make card-700d
    COPYFILE_DISABLE=1 cp out/card-700d/ML/modules/soupeng.mo /Volumes/EOS_DIGITAL/ML/modules/

Eject, then on the camera:

1. Auto develop off. Choose Portra. Shoot 3 frames.
2. Choose Velvia. Shoot 3 frames.
3. Hold a burst, as long as the buffer allows.
4. If you can, cross a folder or a counter wrap.
5. Auto develop on. Shoot one frame while another develops, and change film during it.

Then, with the card back in:

    cat /Volumes/EOS_DIGITAL/ML/DATA/SOUPROLL.TXT
    darkroom/.build-pack/release/darkroomctl scan /Volumes/EOS_DIGITAL

- One `R1` line for each run of frames, with the right films and folder.
- Frames show Shot on Portra and Shot on Velvia. Print takes 1 click.
- Frames from before the module have no record and say so.
- Compare the card's clock against the frames: the window is what links them.
- If `ML/LOGS/SOUPENG.LOG` says `cannot open ML/DATA/SOUPROLL.TXT`, the module saw
  the card refuse it. Frames in that window fall back to No record.

## 6. The checks, all at once

    sh tools/darkroom-gates.sh "$S"

Should end `all gates pass`, in about 2.5 minutes. It opens a window for a moment.

## Where to look next

- `doc/darkroom/POLISH.md`: the score, the 15 issues the budget did not reach.
- `doc/darkroom/PLAN.md`: every decision, including what Not developed means.
- One call to overrule if you disagree: the film name is in the camera's Barlow Semi
  Condensed, not the serif in `a-v4.png`, which was a font fallback in the mock. The
  feel judge agreed. `Theme.display` is the one line to change.
