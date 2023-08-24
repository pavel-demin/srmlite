package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"github.com/hashicorp/golang-lru/v2"
	"io/ioutil"
	"math/rand"
	"net/http"
	"os"
	"path/filepath"
)

type Configuration struct {
	Addr    string
	Cert    string
	Key     string
	Servers []string
}

type RedirectHandler struct {
	Cache   *lru.Cache[string, int]
	Servers []string
}

func (rh *RedirectHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := filepath.Clean(r.URL.Path)
	index, ok := rh.Cache.Get(path)
	if !ok {
		index = rand.Intn(len(rh.Servers))
		rh.Cache.Add(path, index)
	}
	url := rh.Servers[index] + path
	if r.Method == http.MethodGet {
		http.Redirect(w, r, url, 302)
	} else {
		http.Redirect(w, r, url, 307)
	}
}

func main() {
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "Usage: redirector redirector.json")
		os.Exit(1)
	}
	buffer, err := ioutil.ReadFile(flag.Arg(0))
	if err != nil {
		panic(err)
	}
	cfg := Configuration{Addr: ":1094", Cert: "hostcert.pem", Key: "hostkey.pem"}
	err = json.Unmarshal(buffer, &cfg)
	if err != nil {
		panic(err)
	}
	cache, _ := lru.New[string, int](1024)
	handler := &RedirectHandler{Cache: cache, Servers: cfg.Servers}
	server := http.Server{Addr: cfg.Addr, Handler: handler}
	err = server.ListenAndServeTLS(cfg.Cert, cfg.Key)
	if err != nil {
		panic(err)
	}
}
