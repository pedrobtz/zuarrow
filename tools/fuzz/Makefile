# Builds tools/fuzz/replay, the reader without R (ZAR_STANDALONE) over a
# replay driver, for mutation.yaml (#183). One compile per source and a
# separate link, because Mull re-parses each file from its own recorded
# command line. Run from the package root:
#
#   make -C tools/fuzz replay              # cc
#   make -C tools/fuzz replay CC="$MULL_CC"
#   tools/fuzz/replay
#
# The flags are fuzz.yaml's cflags, without the fuzzer.
ROOT := $(abspath ../..)
CC ?= cc
CFLAGS ?= -g -O1
ZAR_CFLAGS = -DZAR_STANDALONE -DNANOARROW_NAMESPACE=zuarrow -DNANOARROW_DLL= \
  -DFLATCC_NO_ASSERT -I$(ROOT)/src -I$(ROOT)/src/vendor/nanoarrow
BUILD = build
SOURCES = $(ROOT)/src/zar_ipc_read.c $(ROOT)/src/zar_utf8.c $(ROOT)/src/zar_codecs.c \
  $(ROOT)/src/vendor/nanoarrow/nanoarrow.c $(ROOT)/src/vendor/nanoarrow/nanoarrow_ipc.c \
  $(ROOT)/src/vendor/nanoarrow/flatcc.c $(ROOT)/tools/fuzz/replay.c
OBJECTS = $(addprefix $(BUILD)/,$(notdir $(SOURCES:.c=.o)))

vpath %.c $(ROOT)/src $(ROOT)/src/vendor/nanoarrow $(ROOT)/tools/fuzz

replay: $(OBJECTS)
	$(CC) $(CFLAGS) -o $@ $(OBJECTS) -lm

$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CFLAGS) $(ZAR_CFLAGS) -c $(abspath $<) -o $@

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD) replay

.PHONY: clean
