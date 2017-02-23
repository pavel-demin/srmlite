CFLAGS = -O2 -Wall

all: srmlite

srmlite: srmlite.c
	gcc $(CFLAGS) $(shell pkg-config fuse --cflags --libs) -o $@ $^
