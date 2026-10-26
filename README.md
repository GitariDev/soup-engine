<div align="center">

# 🎞️ Soup Engine <sub><sup>beta</sup></sub>

### Film looks, in the camera, on a Canon EOS 5D Classic.

<br>

<img src="doc/camera.gif" alt="scrolling the film stocks on the camera" width="620">

<br>
<br>

`beta` &nbsp;·&nbsp; `GPL v2` &nbsp;·&nbsp; `13 film stocks` &nbsp;·&nbsp; `EOS 5D Classic`

</div>

<br>

Press the **trash button** and a list of film stocks fills the back
screen. Turn the wheel to pick one, press `SET`. Every photo you take
after that gets a second JPEG saved beside the raw, with the look
already on it.

```
IMG_1234.CR2        your raw file, untouched
IMG_1234.FLM.JPG    the same photo with the look on it
```

Your raw files are never modified. Delete the JPEG and the photo is
exactly as the camera shot it.

<br>

![all thirteen film looks on one frame](doc/stocks.jpg)

<div align="center"><sub>
All thirteen, one frame, straight off the card.
</sub></div>

<br>

> ⚠️ **Beta.** Unofficial code on a twenty year old camera. It's easy to
> remove, and it never modifies your raw files.

> ⚖️ **No warranty.** Like all GPL software this comes with none. You
> install it at your own risk. See sections 11 and 12 of the
> [licence](LICENSE).

> 🎨 **The looks are still being tweaked** and will keep changing. The
> names are shorthand for the films they're based on, not exact copies.
> All trademarks belong to their owners.

<br>

---

<br>

## 📷 Also: the EOS 700D / Rebel T5i / Kiss X7i

There is a second camera build, for the **EOS 700D** (firmware 1.1.5),
as a Magic Lantern module rather than a patched binary. Install Magic
Lantern's 700D build first, then copy `ML/modules/soupeng.mo`, the
`ML/FILM` folder and `ML/SETTINGS/soupeng.en` from a `make card-700d`
onto the card (see [`src/README.md`](src/README.md)). Soup Engine then
lives under **Shoot** in Magic Lantern's menu, and the current film is
shown at the bottom right of the shooting screen. To change it quickly, press
**INFO** in shooting mode: the film list is the first stop of Canon's
INFO cycle. The **wheel or the arrows** move, **SET** chooses a film or
flips the auto switch, Trash cancels, and INFO again moves on to Canon's
next screen. Outside the open list SET is left to Canon, and the list
keeps out of Canon's menu, the Q screen and the other settings screens. While the list is open every button is the
list's and nothing underneath it reacts, except the shutter, which
closes it and still fires.
The same list offers **Develop last shot** and an **Auto develop**
switch, so you can shoot with auto off, judge on the back screen, and
develop only the frames that deserve it. With auto on, every shot gets
`FLM_1234.JPG` beside its raw. Quarter size takes about 11
seconds a frame, half about 40, full about three minutes; frames queue
while you keep shooting, and the camera will not switch itself off with
frames pending.

Always eject the card from the computer before pulling it, or the
camera may not start with it until it has been ejected cleanly again.

The 5D's `SOURCE: RAW` is not offered on the 700D. Developing from the
sensor data needs the whole decoded frame, 37 MB on this body, and
Magic Lantern cannot hand that out in one piece there; the 5D's answer
was to spool it through the card at minutes a frame, which is not worth
having. The JPEG source, which is the default on both cameras, is the
path every frame goes through.

<br>

## 📦 Installing on the 5D Classic

You need a **Canon EOS 5D Classic** (the original 2005 one, firmware
1.1.1) and a CompactFlash card. The 5D build will not work on any other
Canon: that camera-side code is built for this body's firmware.

<br>

### 1️⃣ &nbsp; Install Magic Lantern

> ### 👉 [builds.magiclantern.fm/5DC.html](https://builds.magiclantern.fm/5DC.html)

Follow their instructions, then check the camera starts and their menu
opens before going further. Soup Engine never touches your camera's
boot flag; their installer does that.

<br>

### 2️⃣ &nbsp; Back up their `autoexec.bin`

Copy it off the card somewhere safe. Putting it back is how you
uninstall.

<br>

### 3️⃣ &nbsp; Copy the files to the root of your card

> ### 📦 [Download the latest release](https://github.com/jiijii0/soup-engine/releases/latest)

Unzip to the card root, replacing `AUTOEXEC.BIN`. Or copy
[`card/`](card) from this repo, which is the same files.

| file | what it is |
|:--|:--|
| 📄 `AUTOEXEC.BIN` | replaces Magic Lantern's |
| ⚙️ `SE.BIN` | the engine |
| 🎞️ `ML/FILM/` | the film stocks |

<br>

### ✅ &nbsp; Put the card in and switch the camera on

That's it. Nothing to enable, no menu to find.

> While Soup Engine is installed you won't have Magic Lantern's own
> menu, since this replaces the file that provides it. Put their
> `autoexec.bin` back whenever you want it again.

<br>

---

<br>

## 📷 Using it

Press the **trash button** and the picker fills the screen.

| button | what it does |
|:--|:--|
| 🎛️ **Wheel** | choose a film |
| ↕️ **Up / Down** | choose where the look comes from |
| ✅ **`SET`** | pick that film and close |
| 🗑️ **Trash** | close, changing nothing |

Your choice survives switching the camera off.

Each photo takes about twenty seconds to develop. You can keep shooting
while it works, and the screen shows `FRAME 2 OF 3` when there's a
queue.

<br>

> ### ⚠️ Set your Picture Style to Standard, Neutral or Faithful
>
> On Monochrome every look comes out black and white.

<br>

**`SOURCE: JPEG`** is the default. Use this.

**`SOURCE: RAW`** works from the sensor data instead. It takes minutes
rather than seconds, some colour adjustments can't be applied, and
`ACROS` won't be black and white.

`FILM SPEED 50` on the picker is only a label. It does not change your
camera's ISO.

<br>

---

<br>

## 🎞️ The films

Thirteen, still under development.

They're small text files in `ML/FILM` on the card, so you can read them,
change them, or write your own.

<br>

<div align="center">

### 🎨 [Soup Stocks](https://jiijii0.github.io/soup-stocks/)

**A web editor for the film stocks.**

Drop in a photo, move sliders, download a `.fs`, put it on the card.

The preview is this engine's own code compiled to WebAssembly, so it
matches what the camera writes.<br>Your photo never leaves your browser.

</div>

<br>

---

<br>

## 🧹 Removing it

Put Magic Lantern's original `autoexec.bin` back. That's all.

To pause it without uninstalling, delete `SE.BIN`. The camera boots
normally without it.

> 🆘 **If the camera ever misbehaves:** pull the battery, put the card
> in a computer, delete `SE.BIN`. Don't delete `AUTOEXEC.BIN` while the
> boot flag is on, because with the flag set and no `AUTOEXEC.BIN` the
> camera won't start at all.

<br>

---

<br>

## ❤️ Thanks

This wouldn't exist without [Magic Lantern](https://magiclantern.fm).

Soup Engine runs inside their work. Their build for the 5D Classic is
what lets the camera run any of this, and years of their reverse
engineering made it possible to understand. They're worth supporting.

Soup Engine isn't their project, so please don't take problems with it
to them. Open an issue here instead.

<br>

## 📄 Source and licence

All of it is in [`src/`](src). `AUTOEXEC.BIN` is Magic Lantern's program
with 215 bytes changed, and the script that applies them is there too.

GPL v2. See [LICENSE](LICENSE). Distributed **without any warranty**,
including the implied warranties of merchantability and fitness for a
particular purpose (sections 11 and 12).
