#!/usr/bin/env python3
"""What the walk must show, from the driver's dumps. G2, G2a, G4 and Not developed."""
import json, sys

log = {}
for line in open(sys.argv[1]):
    d = json.loads(line)
    log[d.get("label", "?")] = d
bad = []

def need(label, field, want):
    got = log.get(label, {}).get(field)
    ok = want(got) if callable(want) else got == want
    if not ok:
        bad.append(f"{label}: {field} is {got!r}")

def counts(label):
    text = log.get(label, {}).get("counts", "")
    return dict((k.strip(), int(v)) for k, v in (p.split(":") for p in text[text.find("(") + 1:-1].split(",")))

need("1-found", "frames", 30)
c = counts("1-found")
if c["shotOn"] + c["printed"] + c["yourChoice"] + c["noRecord"] != c["all"]:
    bad.append(f"the four states do not add up: {c}")
need("2-shot-on", "state", "shotOn")
need("2-shot-on", "canPrint", True)
need("3-your-choice", "state", "yourChoice")
def rect(label):
    text = log.get(label, {}).get("imageRect", "")
    return [round(float(v), 1) for v in text.strip("()").split(",")] if text else None

if rect("2-shot-on") is None or rect("2-shot-on") != rect("3-your-choice"):     # a compare does not move the picture
    bad.append(f"the picture moved: {rect('2-shot-on')} to {rect('3-your-choice')}")
need("3b-wiped", "wipe", lambda w: w is not None and abs(w - 0.3) < 0.02)
need("3c-hold", "holdShotOn", True)
need("3d-released", "holdShotOn", False)
need("4-no-record", "state", "noRecord")
need("4-no-record", "developing", lambda v: not v)   # never a guess
need("4-no-record", "picture", lambda v: (v or "").endswith("straight"))
need("4b-print-held", "canPrint", False)
need("4b-print-held", "lastPrint", None)
need("5-printed", "state", "printed")
need("5-printed", "canPrint", True)                  # G2a
need("7-printed-one", "state", "printed")
if counts("7b-tab-drained")["notDeveloped"] != counts("6-not-developed")["notDeveloped"] - 1:
    bad.append("the Not developed tab did not drain by one")
need("8-batch", "batch", lambda b: b is not None and "failed 0" in b)

# The selection follows the work, and an empty tab does not lose it.
need("9a-moved-on", "state", "shotOn")
need("9a-moved-on", "frame", lambda f: f and f != log.get("9-before-print", {}).get("frame"))
need("9a-moved-on", "visible", lambda v: log.get("9-before-print", {}).get("frame") not in (v or "").split())
need("9b-empty-tab", "frame", None)
need("9b-empty-tab", "visible", "")
need("9c-back", "frame", log.get("9a-moved-on", {}).get("frame"))

# A can pick keeps the developed picture; once the film is up nothing is old.
need("10-can-pick", "picture", lambda p: (p or "").split(" ")[0] in ("quick", "fine"))
need("10b-can-arrived", "showsOldFilm", False)
need("10b-can-arrived", "filmLate", False)

need("1-found", "firstFilms", "PORTRA GOLD")

# Print sits in one place on every tray, and every print is named and sized.
def button(label):
    text = log.get(label, {}).get("printRect", "")
    return [round(float(v), 1) for v in text.strip("()").split(",")] if text else None

for label in ("3-your-choice", "4-no-record", "5-printed"):
    if button(label) is None or button(label) != button("2-shot-on"):
        bad.append(f"Print moved: {button('2-shot-on')} to {button(label)} at {label}")

need("11-no-can", "state", "shotOn")
need("11-no-can", "word", "NO CAN")
need("2-shot-on", "word", "SHOT ON")

prints = open(sys.argv[2]).read().split()
if len(prints) < 2:
    bad.append(f"expected prints, found {prints}")

# The stack. The picture is the file, the count is the files, and looking at it
# changes nothing.
def shown(label, name):
    need(label, "place", name)
    need(label, "picture", lambda p: (p or "") .startswith("fine print|") and (p or "").endswith("/" + name))

def stack(label, *names):
    need(label, "stack", len(names))
    need(label, "stackFiles", " ".join(names))

VELVIA, PORTRA, AGAIN = "IMG_4008_VELVIA.JPG", "IMG_4008_PORTRA.JPG", "IMG_4008_VELVIA-2.JPG"
ETERNA_RENDER = lambda p: (p or "").startswith("fine ") and (p or "").endswith("/eterna.fs")

need("s1-no-stack", "state", "shotOn")
stack("s1-no-stack")
need("s1-no-stack", "place", "film")
need("s1-no-stack", "onOriginal", False)

need("s2-first-print", "state", "printed")
stack("s2-first-print", VELVIA)
shown("s2-first-print", VELVIA)
need("s2-first-print", "stackLabel", "PRINT 1 OF 1")
need("s2-first-print", "right", "PRINT 1 OF 1 · VELVIA")
need("s2-first-print", "left", "SHOT ON ETERNA")
need("s2-first-print", "printWipe", 0)              # a print shows whole
need("s2-first-print", "lastPrint", lambda p: (p or "").endswith("/" + VELVIA))

# The original is the frame on its shot-on film. The choice stands, and Print still uses it.
need("s3-original", "place", "original")
need("s3-original", "onOriginal", True)
need("s3-original", "wipes", False)
need("s3-original", "picture", ETERNA_RENDER)
need("s3-original", "stackLabel", "1 PRINT")
need("s3-original", "developing", "VELVIA")
need("s3-original", "state", "printed")
need("s3-original", "inHand", False)
need("s3b-original-held", "holdShotOn", True)
need("s3b-original-held", "spaceShows", lambda p: (p or "").endswith("/eterna.fs"))

need("s4-second-choice", "state", "yourChoice")     # another can on a stack is a choice again
need("s4-second-choice", "place", "film")
need("s4-second-choice", "inHand", True)
stack("s4-second-choice", VELVIA)

stack("s5-second-print", VELVIA, PORTRA)
shown("s5-second-print", PORTRA)
need("s5-second-print", "stackLabel", "PRINT 2 OF 2")
stack("s6-third-print", VELVIA, PORTRA, AGAIN)      # never overwritten
shown("s6-third-print", AGAIN)
need("s6-third-print", "stackLabel", "PRINT 3 OF 3")
need("s6-third-print", "stackFilms", "VELVIA PORTRA VELVIA")

shown("s7-back-one", PORTRA)
need("s7-back-one", "stackLabel", "PRINT 2 OF 3")
need("s7b-round-to-original", "place", "original")
shown("s7c-round-to-newest", AGAIN)
shown("s7d-clicked-back", PORTRA)
shown("s7e-clicked-next", AGAIN)

need("s8-print-wiped", "printWipe", lambda w: w is not None and abs(w - 0.4) < 0.02)
need("s8-print-wiped", "wipe", log.get("3b-wiped", {}).get("wipe"))  # the film wipe is left alone
shown("s8b-wipe-holds", PORTRA)
need("s8b-wipe-holds", "printWipe", lambda w: w is not None and abs(w - 0.4) < 0.02)
need("s8c-space-on-print", "holdShotOn", True)
need("s8c-space-on-print", "spaceShows", lambda p: (p or "").endswith("/eterna.fs"))
need("s8c-space-on-print", "compare", ETERNA_RENDER)

need("s9-pending", "state", "yourChoice")
shown("s9b-off-the-film", AGAIN)                    # the film in hand is the last stop
need("s9c-back-to-the-film", "place", "film")
need("s9c-back-to-the-film", "picture", lambda p: (p or "").endswith("/gold.fs"))

need("s10-printed-can-is-live", "state", "printed")
need("s10-printed-can-is-live", "place", "film")
need("s10-printed-can-is-live", "picture", lambda p: (p or "").endswith("/velvia.fs"))
shown("s10b-opens-on-newest", AGAIN)

stack("s11-shown-print-lost", VELVIA, PORTRA)
shown("s11-shown-print-lost", PORTRA)               # it moves off what went
stack("s12-lost-without-coming-back", PORTRA)
stack("s13-moved-back", VELVIA, PORTRA, AGAIN)      # a drive plugged back in
shown("s14-stepped-onto-nothing", VELVIA)
stack("s14-stepped-onto-nothing", VELVIA, PORTRA)

stack("s15b-all-gone")
need("s15b-all-gone", "state", "yourChoice")        # Velvia is chosen and no longer printed
need("s15b-all-gone", "place", "film")
need("s15b-all-gone", "onOriginal", False)
if counts("s15b-all-gone")["notDeveloped"] != counts("s15-before-all-gone")["notDeveloped"] + 1:
    bad.append("the Not developed tab did not take the frame back")

stack("s16-name-came-free", VELVIA)                 # one path, one print
need("s16-name-came-free", "state", "printed")
stack("s16b-others-back", PORTRA, AGAIN, VELVIA)    # the one aside could not come back over it
need("s16b-others-back", "stackFilms", "PORTRA VELVIA VELVIA")

# Only the file can do this: a render of the film would not change.
shown("s16c-file-a", AGAIN)
shown("s16d-file-b", PORTRA)
shown("s16e-file-b-now-a", PORTRA)
shown("s16f-file-a-now-b", AGAIN)
sum_of = lambda label: log.get(label, {}).get("pictureSum")
if sum_of("s16c-file-a") in (None, sum_of("s16d-file-b")):
    bad.append("two prints on different films are the same picture")
if sum_of("s16e-file-b-now-a") != sum_of("s16c-file-a"):
    bad.append("the enlarger did not show the file at this path")
if sum_of("s16f-file-a-now-b") != sum_of("s16d-file-b"):
    bad.append("the enlarger did not show the file at this path, a step along")

stack("s17-card-print", "FLM_3991.JPG")
shown("s17-card-print", "FLM_3991.JPG")
need("s17-card-print", "right", "PRINT 1 OF 1 · PROVIA")
need("s17-card-print", "left", "SHOT ON GOLD")      # the roll wins for the original
need("s17-card-print", "developing", "GOLD")
need("s17-card-print", "pictureSize", "2592x1728")
need("s17b-card-original", "picture", lambda p: (p or "").endswith("/gold.fs"))
need("s17b-card-original", "inHand", True)          # on its own film, the original is what Print makes
stack("s17c-card-and-desk", "FLM_3991.JPG", "IMG_3991_PORTRA.JPG")
need("s17c-card-and-desk", "stackLabel", "PRINT 2 OF 2")

need("s18-portrait-film", "pictureSize", "1728x2592")
need("s18b-portrait-print", "pictureSize", "1728x2592")
if rect("s18-portrait-film") != rect("s18b-portrait-print"):
    bad.append(f"a portrait print moved: {rect('s18-portrait-film')} to {rect('s18b-portrait-print')}")

need("s19-no-record", "state", "noRecord")
need("s19b-no-record-printed", "state", "printed")
need("s19b-no-record-printed", "left", "STRAIGHT RAW")
need("s19c-straight-original", "picture", lambda p: (p or "").endswith("straight"))
need("s19c-straight-original", "onOriginal", True)
need("s19d-choice-cleared", "developing", lambda v: not v)  # a print is no film record
need("s19d-choice-cleared", "shotOn", lambda v: not v)
need("s19d-choice-cleared", "canPrint", False)
need("s19d-choice-cleared", "onOriginal", True)
need("s19e-print-still-waits", "canPrint", False)
stack("s19e-print-still-waits", "IMG_3985_GOLD.JPG")
need("s19e-print-still-waits", "hold", "No film is recorded. Choose a can to print.")

for label in ("s2-first-print", "s3-original", "s6-third-print", "s8-print-wiped", "s9-pending", "s15b-all-gone"):
    if rect(label) != rect("s1-no-stack"):
        bad.append(f"the picture moved at {label}: {rect('s1-no-stack')} to {rect(label)}")
    if button(label) != button("2-shot-on"):
        bad.append(f"Print moved at {label}: {button('2-shot-on')} to {button(label)}")

for name in (VELVIA, PORTRA, "IMG_3991_PORTRA.JPG", "IMG_3985_GOLD.JPG"):
    if name not in prints:
        bad.append(f"{name} is not on disk: {prints}")

for b in bad:
    print("  " + b)
sys.exit(1 if bad else 0)
