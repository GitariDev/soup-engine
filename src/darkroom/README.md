# Soup Darkroom

A desktop raw developer for macOS, for the CR2 files on a Canon T5i / 700D card.
It uses the same C engine and the same film files as the camera, and a print from
the app is byte for byte what `filmdev looks --from-raw` makes of that frame. It
reads which film each frame was shot on from `ML/DATA/SOUPROLL.TXT`, and from the
prints on the card.

It needs macOS 14 or later, and Xcode to build.

## Build and run

From `src/`:

    make darkroom                     # builds out/Soup Darkroom.app
    open "out/Soup Darkroom.app"
    make darkroom-test                # swift test
    make darkroom-parity S=<samples>  # prints against filmdev, byte for byte
    make bench S=<samples>            # a fixture card in out/bench-card

`S` is a folder of raws. `bench` clones them onto a card with every frame state
and checks the result. `darkroomctl` is the same code from a terminal:

    cd darkroom
    swift build --build-path .build-pack --product darkroomctl
    .build-pack/debug/darkroomctl cards
    .build-pack/debug/darkroomctl scan /Volumes/EOS_DIGITAL

`scan` and `cards` write nothing. `scan --record` reads a copy of the app's record.

## What it never does

- Write to a card. Prints go to a folder on the computer, and a folder on a card
  or inside a `DCIM` tree is refused, even when picked by hand.
- Change a CR2.
- Use the network. It has no account, key or limit.

## Where its data lives

- `~/Library/Application Support/Soup Darkroom/bench.json`: film choices, the
  prints the app has made, and the save folder.
- `~/Library/Application Support/Soup Darkroom/Films/`: films you added.
- `~/Pictures/Soup Prints`: prints, until you pick another folder.

The stack on the enlarger shows those files themselves, so a print you delete or
move leaves the stack and its count.

## Credit and licence

GPL v2, see [LICENSE](../../LICENSE). Distributed **without any warranty**.

The UX and UI of the 700D's menu, which this grew out of, are inspired by
[**M-Film**](https://github.com/HNGSeries/M-Film), by
[**@hng.spl**](https://www.instagram.com/hng.spl). None of their code was seen
or used.

The app bundles the Barlow typeface, by The Barlow Project Authors, under the SIL
Open Font License 1.1. The files in [`Resources/Fonts`](Resources/Fonts) are the
subset embedded in [`doc/menu-sample/index.html`](../../doc/menu-sample/index.html),
written out by `Resources/mkfonts.swift`, and the licence is beside them.
