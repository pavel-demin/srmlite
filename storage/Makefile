CFLAGS = -O2 -Wall

all: srmlite

adler32: adler32.go
	CGO_ENABLED=0 go build -ldflags="-s -w" $^

srmlite: srmlite.c
	gcc $(CFLAGS) $(shell pkg-config fuse --cflags --libs) -o $@ $^
