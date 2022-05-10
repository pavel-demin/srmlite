CFLAGS = -O2 -Wall

all: srmlite

adler32: adler32.c
	gcc $(CFLAGS) -lz -lhiredis -o $@ $^

srmlite: srmlite.c
	gcc $(CFLAGS) $(shell pkg-config fuse --cflags --libs) -o $@ $^
