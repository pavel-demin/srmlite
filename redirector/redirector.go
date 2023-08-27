package main

import (
	"encoding/json"
	"flag"
	"log"
	"math/rand"
	"net/http"
	"os"
	"path"
	"time"

	lru "github.com/hashicorp/golang-lru/v2"
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

func (h *RedirectHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header()["Date"] = nil
	path := path.Clean(r.URL.Path)
	index, ok := h.Cache.Get(path)
	if !ok {
		index = rand.Intn(len(h.Servers))
		h.Cache.Add(path, index)
	}
	url := h.Servers[index] + path
	if r.Method == http.MethodGet {
		http.Redirect(w, r, url, http.StatusFound)
	} else {
		http.Redirect(w, r, url, http.StatusTemporaryRedirect)
	}
}

func main() {
	log.SetFlags(0)
	flag.Parse()
	if flag.NArg() != 1 {
		log.Fatal("usage: redirector redirector.json")
	}
	data, err := os.ReadFile(flag.Arg(0))
	if err != nil {
		log.Fatal(err)
	}
	cfg := &Configuration{Addr: ":1094", Cert: "hostcert.pem", Key: "hostkey.pem"}
	err = json.Unmarshal(data, cfg)
	if err != nil {
		log.Fatal("configuration file: ", err)
	}
	if len(cfg.Servers) == 0 {
		log.Fatal("configuration file: empty servers list")
	}
	cache, _ := lru.New[string, int](1024)
	handler := &RedirectHandler{Cache: cache, Servers: cfg.Servers}
	server := &http.Server{
		Addr:           cfg.Addr,
		Handler:        handler,
		ReadTimeout:    3 * time.Second,
		WriteTimeout:   3 * time.Second,
		MaxHeaderBytes: 4096,
	}
	err = server.ListenAndServeTLS(cfg.Cert, cfg.Key)
	if err != nil {
		log.Fatal(err)
	}
}
