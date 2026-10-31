# Builds and runs the portable C unit tests (Linux or macOS, no USB hardware needed).
CC ?= cc
CFLAGS ?= -O2 -g -Wall -Wextra -std=c11 -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE -D_POSIX_C_SOURCE=200809L
SRC = ../../Sources/SMICore
INC = -I$(SRC)/include

test_core: test_core.c $(SRC)/smi_parser.c $(SRC)/smi_image.c $(SRC)/include/smi_core.h
	$(CC) $(CFLAGS) $(INC) -o $@ test_core.c $(SRC)/smi_parser.c $(SRC)/smi_image.c -lm

test: test_core
	./test_core

clean:
	rm -f test_core

.PHONY: test clean
