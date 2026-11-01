#!/usr/bin/env python3
"""The bench card: a fixture with the shape of the mock, on real frames.

    mkbench.py <samples dir> [outdir]

30 frames: 16 Shot on, 2 Printed, 12 No record, and 28 Not developed. The roll's
lines are computed from each CR2's own date, and the result is checked frame by
frame against `darkroomctl scan`. A `.record` folder beside the card holds a
bench.json with one choice, which is the only way to reach Your choice, since
nothing about a choice is kept on a card.

The output holds the owner's photos, so it belongs in src/out/ or /tmp. Any
destination under /Volumes is refused. Files arrive by clonefile(2) and not
`cp -c`, because `cp -c` quietly falls back to a full copy. Samples are never
written, and that is checked at the end.
"""
import ctypes
import datetime
import json
import os
import shutil
import subprocess
import sys

SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = ".build-pack"                       # as in src/Makefile
MARK = ".mkbench"                           # what makes an old outdir safe to replace

GONE = "KODACHROME 64"                      # a film that is on no shelf
ORIGIN = datetime.datetime(2000, 1, 1)
REUSED_CLOCK = (2024, 9, 14, 11, 2, 30)     # a later card, after a counter reset

# Each line's frames are (folder, name). Where a frame has its clone under
# another name, CLONED_AS says so. Lines run in the order the camera wrote them.
# The range of a line may go past the frames on the card, as a real one would.
#   film, roll, frames, optional (fromNo, toNo)
LINES = [
    ("GOLD", 0, [(100, "IMG_3991")]),                                       # printed on PROVIA: the roll wins
    ("VELVIA", 0, [(100, "IMG_3993")]),                                     # a single line
    ("ACROS", 0, [(100, "IMG_3994")]),                                      # conflict, with
    ("ASTIA", 0, [(100, "IMG_3994")]),                                      # this one
    ("PORTRA", 7, [(100, n) for n in ("IMG_3997", "IMG_3998", "IMG_3999", "IMG_4004", "IMG_4005")],
     (3940, 4005)),                                                         # 66 by the counter: past SE_BURST
    ("ETERNA", 7, [(100, n) for n in ("IMG_4006", "IMG_4007", "IMG_4008", "IMG_4009")]),
    (GONE, 7, [(100, "IMG_4010")]),                                         # not on the shelf
    ("CLASSIC CHROME", 12, [(100, "IMG_4017"), (100, "IMG_4018"),           # across the folder change
                            (101, "IMG_4019"), (101, "IMG_4020")]),
    ("ASTIA", 12, [(101, "IMG_3990")]),                                     # same number as 100, another frame
]

# Damage a reader has to skip. Neither may count as a line.
SKIPPED = 2


def frame(state, shot=None, source=None, develops=None, prints=True, developed=False, film=None, why=None):
    return dict(state=state, shot=shot, source=source, develops=develops or shot, prints=prints,
                developed=developed, film=film, why=why)


def shot(film, prints=True):
    return frame("Shot on", film, "roll", develops=film if prints else "-", prints=prints)


NO = frame("No record", prints=False)

EXPECT = {
    (100, "IMG_3984"): dict(NO, why="canon jpeg"),
    (100, "IMG_3985"): NO,
    (100, "IMG_3990"): NO,                  # its number is on a line, but of folder 101
    (100, "IMG_3991"): frame("Printed", "GOLD", "roll", developed=True, film="PROVIA"),
    (100, "IMG_3992"): dict(NO, why="cut off"),
    (100, "IMG_3993"): shot("VELVIA"),
    (100, "IMG_3994"): dict(NO, why="both"),
    (100, "IMG_3995"): dict(NO, why="at the time"),
    (100, "IMG_3996"): NO,
    (100, "IMG_3997"): shot("PORTRA"),
    (100, "IMG_3998"): shot("PORTRA"),
    (100, "IMG_3999"): shot("PORTRA"),
    (100, "IMG_4004"): shot("PORTRA"),
    (100, "IMG_4005"): shot("PORTRA"),
    (100, "IMG_4006"): shot("ETERNA"),
    (100, "IMG_4007"): shot("ETERNA"),
    (100, "IMG_4008"): shot("ETERNA"),
    (100, "IMG_4009"): shot("ETERNA"),
    (100, "IMG_4010"): shot(GONE, prints=False),
    (100, "IMG_4011"): NO,
    (100, "IMG_4012"): NO,
    (100, "IMG_4013"): frame("Printed", "ETERNA", "card print", developed=True, film="ETERNA"),
    (100, "IMG_4014"): NO,
    (100, "IMG_4015"): NO,
    (100, "IMG_4016"): NO,
    (100, "IMG_4017"): shot("CLASSIC CHROME"),
    (100, "IMG_4018"): shot("CLASSIC CHROME"),
    (101, "IMG_3990"): shot("ASTIA"),
    (101, "IMG_4019"): shot("CLASSIC CHROME"),
    (101, "IMG_4020"): shot("CLASSIC CHROME"),
}

CLONED_AS = {(101, "IMG_3990"): "IMG_4023"}
CHOSEN = (100, "IMG_4006")                  # to VELVIA, in the .record folder


def die(message):
    sys.exit(f"mkbench: {message}")


def under_volumes(path):
    low = path.lower()
    return low == "/volumes" or low.startswith("/volumes/")


def refuse_card(outdir):
    """/Volumes is compared without case, on the path both as given and as it
    resolves, so neither a link nor /VOLUMES gets round it."""
    for path in (os.path.abspath(outdir), os.path.realpath(outdir)):
        if under_volumes(path):
            die(f"refusing {path}: nothing is written under /Volumes")


def clear(outdir):
    if os.path.lexists(outdir):
        if os.listdir(outdir) and not os.path.exists(os.path.join(outdir, MARK)):
            die(f"{outdir} has files in it and is not a bench card, so it is left alone")
        shutil.rmtree(outdir)
    for side in (outdir + ".record", outdir + ".prints"):
        shutil.rmtree(side, ignore_errors=True)


libc = ctypes.CDLL(None, use_errno=True)


def clone(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if libc.clonefile(os.fsencode(src), os.fsencode(dst), 0):
        errno = ctypes.get_errno()
        die(f"cannot clone {src} to {dst}: {os.strerror(errno)}. A full copy is never made, "
            "so the outdir must be on the same APFS volume as the samples")


def name_id(name):
    """se_name_id: FNV-1a of the name's bytes."""
    h = 2166136261
    for b in name.encode():
        h = ((h ^ b) * 16777619) & 0xffffffff
    return h


def film_name(path):
    with open(path, encoding="latin-1") as f:
        for line in f:
            if line.startswith("NAME"):
                return line[4:].strip()
    die(f"no NAME in {path}")


def seconds(date):
    """Seconds from a fixed origin, for differences within one camera clock."""
    d, t = date.split(" ")
    y, mo, day = map(int, d.split(":"))
    h, mi, s = map(int, t.split(":"))
    return int((datetime.datetime(y, mo, day, h, mi, s) - ORIGIN).total_seconds())


def clock_of(sec):
    t = ORIGIN + datetime.timedelta(seconds=sec)
    return t.year, t.month, t.day, t.hour, t.minute, t.second


def build_ctl():
    darkroom = os.path.join(SRC, "darkroom")
    swift = ["swift", "build", "-c", "release", "--build-path", BUILD, "--product", "darkroomctl"]
    subprocess.run(swift, cwd=darkroom, check=True, stdout=subprocess.DEVNULL)
    return os.path.join(darkroom, BUILD, "release", "darkroomctl")


def run(ctl, *args):
    done = subprocess.run([ctl, *args], capture_output=True, text=True)
    if done.returncode:
        die(f"darkroomctl {' '.join(args)} failed: {done.stderr.strip()}")
    return done.stdout


def number(name):
    return int(name[-4:])


def line_text(film, roll, frames, date_of, numbers=None):
    """A line as the watcher writes it. The clock is the look after the last
    frame and the span runs from the look before the first."""
    times = [seconds(date_of[f]) for f in frames]
    first, last = frames[0], frames[-1]
    from_no, to_no = numbers or (number(first[1]), number(last[1]))
    clock = max(times) + 1
    span = clock - (min(times) - 1)
    count = to_no - from_no + 1
    return clock, line(roll, first[0], from_no, last[0], to_no, count, clock_of(clock), span, film)


def line(roll, from_folder, from_no, to_folder, to_no, count, clock, span, film):
    fields = [roll, from_folder, from_no, to_folder, to_no, count, *clock, span]
    return "R1 " + " ".join(map(str, fields)) + f" {name_id(film):x} {film}\n"


def roll_text(date_of):
    lines = [line_text(*spec[:3], date_of, *spec[3:]) for spec in LINES]
    lines.sort(key=lambda x: x[0])
    # A reused number: a later line says 3995, but this frame is months older.
    lines.append((0, line(0, 100, 3995, 100, 3995, 1, REUSED_CLOCK, 1, "PROVIA")))
    text = "".join(t for _, t in lines)
    text += "R2 a line from a newer camera build\n"
    # Cut off by the power, so its id no longer fits its name.
    text += line(0, 100, 4100, 100, 4100, 1, REUSED_CLOCK, 1, "CLASSIC CHROME").replace("CLASSIC CHROME", "CLASSIC")
    return text


def check_scan(report, chosen):
    bad = []
    rows = {(int(r["folder"][:3]), r["name"][:-4]): r for r in report["frames"]}
    if set(rows) != set(EXPECT):
        bad.append(f"frames differ: {sorted(set(rows) ^ set(EXPECT))}")
    for key, want in EXPECT.items():
        row = rows.get(key)
        if row is None:
            continue
        state = "Your choice" if chosen and key == CHOSEN else want["state"]
        develops = "VELVIA" if chosen and key == CHOSEN else want["develops"]
        develops = None if develops == "-" else develops
        for field, value in (("state", state), ("shotOn", want["shot"]), ("shotOnSource", want["source"]),
                             ("developing", develops), ("canPrint", want["prints"]),
                             ("developed", want["developed"]), ("printFilm", want["film"])):
            if row.get(field) != value:
                bad.append(f"{key[0]}CANON/{key[1]}: {field} is {row.get(field)!r}, expected {value!r}")
        why = want["why"]
        if why == "cut off" and not row.get("cutOffPrint"):
            bad.append(f"{key[1]}: the zero-byte FLM_ was not seen as cut off")
        elif why in ("both", "at the time") and why not in (row.get("reason") or ""):
            bad.append(f"{key[1]}: reason is {row.get('reason')!r}, expected it to say {why!r}")
    roll = report["roll"] or {}
    if roll.get("lines") != len(LINES) + 1 or roll.get("skipped") != SKIPPED:
        bad.append(f"roll is {roll}, expected {len(LINES) + 1} lines and {SKIPPED} skipped")
    if roll.get("latestRoll") != 12:
        bad.append(f"latest roll is {roll.get('latestRoll')}, expected 12")
    return bad


def verify(ctl, outdir):
    counts = dict(all=30, shotOn=16, printed=2, yourChoice=0, noRecord=12, notDeveloped=28)
    with_choice = dict(counts, shotOn=15, yourChoice=1)
    failed = False
    for title, want, args in (("card alone", counts, ()),
                              ("with the .record", with_choice, ("--record", outdir + ".record"))):
        print(f"expected, {title}: " + "  ".join(f"{k} {v}" for k, v in want.items()))
        report = json.loads(run(ctl, "scan", outdir, "--json", *args))
        got = report["counts"]
        print(f"scan,     {title}: " + "  ".join(f"{k} {got[k]}" for k in want))
        bad = [f"{k} is {got[k]}, expected {v}" for k, v in want.items() if got[k] != v]
        bad += check_scan(report, chosen=bool(args))
        for b in bad:
            print(f"MISMATCH: {b}", file=sys.stderr)
        failed = failed or bool(bad)
    if failed:
        die("the bench card does not match")


def samples_state(samples):
    out = {}
    for name in sorted(os.listdir(samples)):
        st = os.stat(os.path.join(samples, name))
        out[name] = (st.st_size, st.st_mtime_ns, st.st_mode)
    return out


def main():
    if len(sys.argv) not in (2, 3):
        die("usage: mkbench.sh <samples dir> [outdir]")
    samples = os.path.realpath(sys.argv[1])
    outdir = os.path.abspath(sys.argv[2] if len(sys.argv) == 3 else os.path.join(SRC, "out", "bench-card"))
    refuse_card(outdir)
    if os.path.realpath(outdir).startswith(samples + os.sep):
        die("the outdir is inside the samples, and samples are never written")

    source = {key: os.path.join(samples, CLONED_AS.get(key, key[1]) + ".CR2") for key in EXPECT}
    jpeg = os.path.join(samples, "IMG_3984.JPG")
    missing = [p for p in [*source.values(), jpeg] if not os.path.isfile(p)]
    if missing:
        die(f"not in the samples: {', '.join(os.path.basename(p) for p in missing)}")

    before = samples_state(samples)
    ctl = build_ctl()
    clear(outdir)
    os.makedirs(outdir)
    open(os.path.join(outdir, MARK), "w").close()

    for (folder, name), src in source.items():
        clone(src, os.path.join(outdir, "DCIM", f"{folder}CANON", name + ".CR2"))
    card = os.path.join(outdir, "DCIM", "100CANON")
    # Printed, Canon JPEG, cut-off print, AppleDouble: what sits beside a frame.
    clone(jpeg, os.path.join(card, "IMG_3984.JPG"))
    open(os.path.join(card, "FLM_3992.JPG"), "w").close()
    with open(os.path.join(card, "._IMG_0000.CR2"), "wb") as f:
        f.write(b"\x00\x05\x16\x07\x00\x02\x00\x00")

    stocks = os.path.join(SRC, "stocks")
    fs_files = {}
    for name in sorted(os.listdir(stocks)):
        if name.endswith(".fs"):
            fs_files[film_name(os.path.join(stocks, name))] = os.path.join(stocks, name)
            clone(os.path.join(stocks, name), os.path.join(outdir, "ML", "FILM", name))

    date_of = {key: json.loads(run(ctl, "probe", src, "--json"))["dateTime"] for key, src in source.items()}
    os.makedirs(os.path.join(outdir, "ML", "DATA"))
    with open(os.path.join(outdir, "ML", "DATA", "SOUPROLL.TXT"), "w") as f:
        f.write(roll_text(date_of))

    # Printed outside the card, since the engine refuses a card, then moved in.
    side = outdir + ".prints"
    os.makedirs(side)
    for name, film in (("IMG_3991", "PROVIA"), ("IMG_4013", "ETERNA")):
        out = f"FLM_{name[-4:]}.JPG"
        run(ctl, "print", os.path.join(card, name + ".CR2"), fs_files[film], side, "--half", "--name", out)
        os.rename(os.path.join(side, out), os.path.join(card, out))
    os.rmdir(side)

    # Your choice lives in the record, never on the card. Identity is R1's.
    key = CHOSEN
    path = os.path.join(outdir, "DCIM", f"{key[0]}CANON", key[1] + ".CR2")
    record = outdir + ".record"
    os.makedirs(record)
    with open(os.path.join(record, "bench.json"), "w") as f:
        identity = f"{key[1]}|{date_of[key]}|{os.path.getsize(path)}"
        json.dump(dict(version=1, choices={identity: "VELVIA"}, prints={}), f, indent=2)

    verify(ctl, outdir)
    if samples_state(samples) != before:
        die("the samples changed")
    print(f"bench card: {outdir}")


if __name__ == "__main__":
    main()
