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

prints = open(sys.argv[2]).read().split()
if len(prints) < 2:
    bad.append(f"expected prints, found {prints}")

for b in bad:
    print("  " + b)
sys.exit(1 if bad else 0)
