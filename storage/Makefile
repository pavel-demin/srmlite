CFLAGS = -O2 -Wall

all: putfile srmlite

putfile: putfile.c
	gcc $(CFLAGS) -o $@ $^

srmlite: srmlite.c
	gcc $(CFLAGS) $(shell pkg-config fuse --cflags --libs) -o $@ $^
