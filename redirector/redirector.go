package main

import (
	"encoding/json"
	"flag"
	"github.com/hashicorp/golang-lru/v2"
	"log"
	"math/rand"
	"net/http"
	"os"
	"path"
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
	path := path.Clean(r.URL.Path)
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
	log.SetFlags(0)
	flag.Parse()
	if flag.NArg() != 1 {
		log.Fatalln("Usage: redirector redirector.json")
	}
	data, err := os.ReadFile(flag.Arg(0))
	if err != nil {
		log.Fatal(err)
	}
	cfg := Configuration{Addr: ":1094", Cert: "hostcert.pem", Key: "hostkey.pem"}
	err = json.Unmarshal(data, &cfg)
	if err != nil {
		log.Fatal(err)
	}
	cache, _ := lru.New[string, int](1024)
	handler := &RedirectHandler{Cache: cache, Servers: cfg.Servers}
	server := http.Server{Addr: cfg.Addr, Handler: handler}
	err = server.ListenAndServeTLS(cfg.Cert, cfg.Key)
	if err != nil {
		log.Fatal(err)
	}
}
