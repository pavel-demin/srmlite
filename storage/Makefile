CFLAGS = -O2 -Wall

all: srmlite

adler32: adler32.go
	go build -ldflags="-s -w" $^

srmlite: srmlite.c
	gcc $(CFLAGS) $(shell pkg-config fuse --cflags --libs) -o $@ $^
