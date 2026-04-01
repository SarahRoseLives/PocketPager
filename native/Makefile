CC      = gcc
CFLAGS  = -std=gnu11 -O2 -Wall -Wextra \
          -DMAX_VERBOSE_LEVEL=0 \
          -DCHARSET_UTF8 \
          -DNO_X11 \
          -DNO_SDL3 \
          -DDUMMY_AUDIO \
          -I../multimon-ng

LDFLAGS = -lrtlsdr -lsamplerate -lm

MULTIMON_SRCS = \
    ../multimon-ng/pocsag.c \
    ../multimon-ng/demod_poc5.c \
    ../multimon-ng/demod_poc12.c \
    ../multimon-ng/demod_poc24.c \
    ../multimon-ng/demod_flex.c \
    ../multimon-ng/demod_flex_next.c \
    ../multimon-ng/bch.c \
    ../multimon-ng/costabf.c \
    ../multimon-ng/cJSON.c

TARGET  = pocketpager_test
SRCS    = pocketpager_test.c $(MULTIMON_SRCS)

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

clean:
	rm -f $(TARGET)
