package main

import (
	"bufio"
	"fmt"
	"hash/adler32"
	"io"
	"net"
	"os"
)

func main() {

	l, err := net.Listen("tcp", ":9500")
	if err != nil {
		panic(err)
	}

	for {
		conn, err := l.Accept()
		if err != nil {
			continue
		}

		go handle(conn)
	}
}

func handle(conn net.Conn) {
	defer conn.Close()

	s := bufio.NewScanner(conn)

	if !s.Scan() {
		return
	}

	data := s.Text()

	f, err := os.Open(data)
	if err != nil {
		return
	}

	defer f.Close()

	h := adler32.New()

	_, err = io.Copy(h, f)
	if err != nil {
		return
	}

	fmt.Fprintf(conn, "%08x", h.Sum32())
}
