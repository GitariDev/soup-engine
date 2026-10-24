# soupeng.mo - Soup Engine as a Magic Lantern module, for the EOS 700D.
#
# This borrows Magic Lantern's own module build (modules/Makefile in the
# pinned checkout under vendor/) rather than reproducing it, so the module
# is compiled exactly the way the ones on the card were. Our sources stay
# here; only TOP_DIR points into their tree.
#
# The engine is the same files the 5D payload and the desktop tools use,
# compiled unchanged. Nothing in ml/payload/ is used: that directory is
# the 5D Classic's hand-patched loader, and this module replaces all of it
# with calls into Magic Lantern.

MODULE_NAME = soupeng
TOP_DIR     = ../../vendor/magiclantern_simplified
ENGINE      = ../../engine

ENGINE_SRC  = se.c wb.c cr2.c color.c debayer.c lut.c stock.c grade.c \
              jpeg_enc.c jpeg_dec.c pipeline.c look.c
MODULE_OBJS = $(BUILD_DIR)/soupeng.o \
              $(addprefix $(BUILD_DIR)/, $(ENGINE_SRC:.c=.o))

# -fno-fast-math: Magic Lantern builds everything with -ffast-math, and
# the engine's setup paths (baking curves, deriving gains) are float. The
# desktop reference is built without it, and "the camera writes what the
# desktop computes" is the property the whole project rests on.
MODULE_CFLAGS += -I$(TOP_DIR)/src -I$(ENGINE) \
                 -fno-fast-math -fno-single-precision-constant

# The toolchain. Magic Lantern's Makefile.globals hard-codes /usr/bin and
# a bare `readelf`, with plain `=`, so these have to be `override` to
# survive the include below. Homebrew's arm-none-eabi-gcc will not do: it
# ships no libc headers, and Magic Lantern's own headers include them.
# This one is Arm's GNU toolchain, which has newlib's. It lives outside the
# repo because their Makefile does not quote $(CC) and this repo's path has
# a space in it.
ARM_TOOLCHAIN ?= $(HOME)/.local/opt/arm-gnu-toolchain-15.3.rel2/bin
override ARM_BINPATH := $(ARM_TOOLCHAIN)
override READELF     := $(ARM_TOOLCHAIN)/arm-none-eabi-readelf

include $(TOP_DIR)/modules/Makefile
.DEFAULT_GOAL := $(BUILD_DIR)/module_complete

# look.c is the per-pixel path. At -Os gcc calls __aeabi_idiv even for a
# constant divisor; -O2 turns those into multiply-shifts. Same reasoning
# as ml/payload/Makefile, same byte-identical result.
$(BUILD_DIR)/look.o: $(ENGINE)/look.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(CDEPS_FLAGS) -O2 -c -o $@ $<

$(BUILD_DIR)/%.o: $(ENGINE)/%.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(CDEPS_FLAGS) -c -o $@ $<
