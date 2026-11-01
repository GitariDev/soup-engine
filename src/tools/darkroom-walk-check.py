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

prints = open(sys.argv[2]).read().split()
if len(prints) < 2:
    bad.append(f"expected prints, found {prints}")

for b in bad:
    print("  " + b)
sys.exit(1 if bad else 0)
