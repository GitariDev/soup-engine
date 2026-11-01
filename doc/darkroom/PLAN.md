# Soup Darkroom: build plan

A macOS desktop app over the C engine, matching Enlarger Bench v4. The design,
statute and guidelines are in `doc/darkroom-sample/` in the main checkout. They
are not tracked, and they are the acceptance standard.

## Facts found before planning

These were read from the code, the samples and the card, and they decide the
design.

| Fact | Evidence | What it decides |
|:--|:--|:--|
| SwiftUI, XCTest and offscreen window capture all work here | a spike package built and ran; Xcode 27.2, Swift 6.4 | SwiftUI, in a Swift package |
| A symlink inside a target compiles the engine | spike: `engine/se.c` built through a symlink | the app uses `src/engine` with no copy |
| The engine has no per-run globals, only lazily built tables | `look.c`, `jpeg_enc.c`, `se.c` | safe to run at once after one warm-up |
| The engine ignores orientation and writes `Orientation: normal` | `jpeg_enc.c:230`, no 0x0112 read in `cr2.c` | the bridge reads it; the print carries it |
| 2 of 30 samples are portrait | IFD0 tag 0x0112 = 6 on IMG_4019, IMG_4020 | previews rotate; prints carry the tag |
| The print name is `FLM_` plus the four digits before `.CR2`, in the same folder | `se_out_name`, `develop.c:61` | the pairing rule below |
| A zero-byte `FLM_` is an output cut off by the power | `se_resume_cut`, `watch.c:76`; `file_size(out) > 0`, `watch.c:202` | a zero-byte print is not a print |
| `se_last_file_number` can lag the counter with auto on and the queue full | `watch.c:152` | the roll keeps its own last-seen state |
| A Canon `IMG_nnnn.JPG` can sit beside a CR2 | the card, samples 3984 and 3985 | a Canon JPEG is not a developed image |
| `FLM_` prints carry their film in the Software tag | `FLM_4230.JPG` on the card reads ETERNA | second source for the shot-on film |
| macOS can leave `._*` files on a card | memory of earlier card work | names starting with `.` are ignored |

## Areas and owners

| Area | Files | Phase |
|:--|:--|:--|
| Camera roll file | `src/ml/700d/watch.c`, `soupeng.c/.h`, `tools/sim700d/` | 2a |
| Engine bridge | `src/darkroom/Sources/CSoup/`, small `jpeg_enc` change | 2a |
| Preview pipeline, export | `src/darkroom/Sources/DarkroomEngine/` | 2a |
| Card and roll reading, frame state, bench record, naming | `src/darkroom/Sources/DarkroomCore/` | 2a |
| UI | `src/darkroom/Sources/DarkroomApp/` | 2b |
| App bundle, fixtures, driver | `src/Makefile`, `src/tools/`, `Sources/DarkroomApp/Drive/` | 2b |
| Polish | anywhere, one change at a time | 3 |

## Decisions

### Not developed

A CR2 is **Not developed** when both of these hold:

1. No non-empty `FLM_nnnn.JPG` is in the same folder, with `nnnn` the four digits
   before `.CR2`. The name is compared without regard to case.
2. No print this app made of that frame is still on disk.

It is a tab, not a state. It cuts across the states, so a Shot on frame and a No
record frame can both be Not developed, and its count is not part of All.

The first rule is the camera's own: the name is `se_out_name`, and `file_size(out)
> 0` is the test `se_develop_job` uses for "already developed". So a zero-byte
`FLM_` counts as not developed. `se_walk_card` does not stat, so the camera's own
Darkroom list treats a zero-byte print as present until power-on repairs it. That
difference is in the camera's list and is left as it is.

A Canon `IMG_nnnn.JPG` is not a developed image. A print in another folder does
not count. A CR2 whose name has no four digits before the extension can never
pair, so it stays Not developed until the app prints it. The second rule is there
so the tab empties as the user works; delete the print and the frame comes back.

### Frame states

Each frame has exactly one state, so the four counts add up to All.

| State | When |
|:--|:--|
| Your choice | the user picked a film that is not the film it would otherwise develop on |
| Printed | a print exists, on the card or from this app, and no pending choice differs |
| Shot on | a film is recorded and nothing else applies |
| No record | no film is recorded and none is chosen |

Shot-on film, in order: a matching roll entry, then the Software tag of the
`FLM_` beside it. Where they disagree the roll wins, since a print may have been
redeveloped on another film. Two roll entries that match one frame with different
films are treated as no record, because a guess is worse than a gap.

A recorded film that is not on the shelf shows its name and holds Print until a
can is chosen. The state stays Shot on; the strip says NO CAN.

### Open questions from the report

| Question | Decision |
|:--|:--|
| Name clash | never overwrite: `IMG_3990_VELVIA.JPG`, then `-2`, `-3`. The file is moved into place with an exclusive rename, so the check cannot race. A batch asks for plain names and that rename alone resolves a clash |
| Batch progress | "Printing 3 of 16" in the tray, a Stop that finishes the current frame, and a result naming the folder and what was printed, skipped and failed |
| Where a batch prints | the destination is printed on the batch button's line, always |
| Does a printed frame show its shot-on film? | yes, "Printed on Eterna" and "Shot on Portra", and Space compares against the shot-on film |
| Fogged Eterna on IMG_3996 | measured in Phase 2, recorded in `doc/darkroom/POLISH.md` |
| Toolkit | SwiftUI, in a Swift package, on macOS 14 or later |
| A batch includes No record frames | they are skipped and counted, never guessed: "Print 16 of 28, 12 wait for a film" |

### Other defaults

- **Rotation.** Stored pixels stay 5184x3456, as the camera writes them. The print
  carries the CR2's orientation in EXIF, and previews rotate.
- **Space on a frame with no record.** Shows the straight raw, labelled.
- **Save folder.** `~/Pictures/Soup Prints`, created on first print, then remembered.
- **Refused destinations.** Any folder on a card, or inside a `DCIM` tree. This
  holds for G5 even when the user picks such a folder by hand. A folder inside the
  home folder is never a card, but a `DCIM` tree there stays refused. The app and
  `darkroomctl` share one rule, `Destination.cardReason`.
- **The bench record.** Choices, prints and the save folder are kept in
  `~/Library/Application Support/Soup Darkroom/bench.json`. Nothing goes on the card.
  Only the user removes a choice: one equal to a file's own film does not count for
  that file, and stays in the record for a copy with no film of its own.
- **Frame identity (R1).** `<stem>|<CR2 date and time>|<bytes>`, so a reused number
  on a later frame is a different frame, and a copied folder keeps its record.
- **Films.** The shelf is ML/FILM, then films the user added (kept in Application
  Support), then the bundled stocks so a folder with no card can still develop. A
  name appears once, and the card's copy wins. It reads in the camera's FILMS order,
  with films the camera does not know after.
- **Sizes.** Full 5184x3456 JPEG 92 by default, Half on request.
- **Previews.** The embedded JPEG only as a placeholder, marked as developing. The
  picture the user judges is always the film on the sensor data. A can pick keeps
  the developed picture up until the new film's quick render arrives, without the
  YOUR CHOICE label, and with a DEVELOPING chip if that takes more than a moment.
- **Licence.** GPL stays. The About box and README keep the M-Film credit. No
  account, key, limit or network call.

### The roll file

`ML/DATA/SOUPROLL.TXT`: an 8.3 name (R2), append only, and the camera never reads
it. One line per look at which frames were seen, in plain `%d` and `%s` because
Canon's `snprintf` has no widths or `%u`:

    R1 <roll> <fromFolder> <fromNo> <toFolder> <toNo> <count> <Y> <M> <D> <h> <m> <s> <span> <filmId> <film name>

| Field | Meaning |
|:--|:--|
| `R1` | format version. A reader skips a line with any other tag |
| `roll` | `se_roll_no` with the roll on, otherwise 0 |
| `fromFolder fromNo` | the first frame of the range, as Canon's folder and file numbers |
| `toFolder toNo` | the last frame of the range |
| `count` | frames by the counter, so a line may cover more than `SE_BURST` |
| `Y M D h m s` | camera clock at the look that saw the last frame |
| `span` | seconds from the look before the first frame to that look |
| `filmId` | hex FNV-1a of the film's name (`se_name_id`) |
| `film name` | the film's NAME, to the end of the line |

A range is written rather than one line per frame, so a burst of any length costs
one line, and an impossible jump costs one line that matches nothing.

**Matching on the desktop (R1).** A frame in folder F, number N, shot at T with
exposure E matches a line when all of these hold:

- F is `fromFolder` or `toFolder`.
- N is in the range from `fromNo` to `toNo`, going through the wrap from 9999 to 1.
- T is in `[clock - span - 2E - 5 s, clock + 5 s]`. `2E` covers long-exposure noise
  reduction, which holds the counter back after the shutter closes.

The time test is what makes a reused number safe: a counter reset cannot link an
old frame, because the old frame's time falls outside the window.

**Writing on the camera.** The watcher keeps its own last-seen folder and number
with its own baseline at the first look. It records frames whether auto is on or
off, because recording both costs one line and keeps the shot-on film for a frame
whose print is later deleted or redone. It holds one pending range and extends it
while the film is unchanged. It writes when Canon is idle, or after 5 looks, and
always before a film change starts a new range. A line lost to a power cut leaves
those frames as No record, which is the safe failure.

Known limit: the film is read at the look, up to a second after the shot. Changing
film means opening the film screen, which takes longer than that, so a shot cannot
be seen under the wrong film in ordinary use.

## Phases and done checks

Each check is a command that can be run. `S` is the samples folder, passed as
`SOUP_SAMPLES` because samples are not in this worktree.

| Phase | Work | Done check |
|:--|:--|:--|
| 1 | this plan, the package scaffold, the frozen bridge header | `cd src/darkroom && swift build` |
| 2a camera | roll file in `watch.c`, sim coverage | `cd src && make sim700d SIM700D_SAMPLE=$S/IMG_3990.CR2`, and `make test` |
| 2a engine | bridge, previews, prints | `swift test --filter DarkroomEngineTests`; `sh tools/darkroom-parity.sh` shows a print byte-identical to `filmdev looks --from-raw` |
| 2a core | card, roll, states, naming, bench record | `swift test --filter DarkroomCoreTests`, including Not developed with and without an `FLM_` |
| 2b UI | every screen in `a-v4.png` | `make darkroom`, then the driver script in `tools/darkroom-walk.txt` walks each step |
| 2b bundle | app bundle, fixture card, driver | `make darkroom && open "out/Soup Darkroom.app"`, and `tools/mkbench.sh` builds the fixture |
| 3 | polish hill climb | `doc/darkroom/POLISH.tsv` records each iteration; every gate still passes |
| 4 | `doc/darkroom/FINAL-PASS.md` | the user runs it |

## Rules for all work

- Develop through `se_develop` then `se_look_*`, never `develop --stock`.
- CR2s are opened read-only. Nothing is written to any mounted card, and no test
  or build writes to `/Volumes/EOS_DIGITAL`.
- Owner photos and renders of them stay in ignored paths or `/tmp`.
- D's Test Strip stays out. The wipe compare stays.
