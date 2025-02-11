package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"time"

	"github.com/redis/go-redis/v9"
)

var ctx = context.Background()

var path = "/storage/data/cms/"

var port = ":9500"

var servers = []string{
	"10.1.2.11",
	"10.1.2.12",
	"10.1.2.13",
}

func calculate(name string) (string, error) {
	request := path + name + "\n"
	result := make([]byte, 8)
	for _, addr := range servers {
		conn, err := net.DialTimeout("tcp", addr+port, 3*time.Second)
		if err != nil {
			continue
		}
		defer conn.Close()
		conn.Write([]byte(request))
		_, err = io.ReadFull(conn, result)
		if err != nil || string(result) == "00000001" {
			continue
		}
		return string(result), nil
	}
	return "", errors.New("no result")
}

func main() {
	if len(os.Args) < 2 {
		os.Exit(1)
	}

	name := os.Args[1]

	rdb := redis.NewClient(&redis.Options{
		Addr:     "localhost:6379",
		Password: "",
		DB:       0,
	})

	value, err := rdb.Get(ctx, name).Result()
	if err == nil && value != "00000001" {
		fmt.Println(value)
		os.Exit(0)
	}

	value, err = calculate(name)

	if err != nil {
		os.Exit(1)
	}

	if value == "00000001" {
		time.Sleep(3 * time.Second)
		value, err = calculate(name)
	}

	if err != nil {
		os.Exit(1)
	}

	if value != "00000001" {
		rdb.Set(ctx, name, value, 0)
	}

	fmt.Println(value)
}
