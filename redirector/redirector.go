package main

import (
	"encoding/json"
	"log"
	"math/rand/v2"
	"net/http"
	"net/url"
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
	path := path.Clean(r.URL.Path)
	index, ok := h.Cache.Get(path)
	if !ok {
		index = rand.IntN(len(h.Servers))
		h.Cache.Add(path, index)
	}
	authz, ok := r.Header["Authorization"]
	if ok {
		path += "?authz=" + url.PathEscape(authz[0])
	}
	header := w.Header()
	header["Date"] = nil
	header["Location"] = []string{h.Servers[index] + path}
	w.WriteHeader(http.StatusTemporaryRedirect)
}

func main() {
	log.SetFlags(0)
	if len(os.Args) != 2 {
		log.Fatal("usage: redirector redirector.json")
	}
	data, err := os.ReadFile(os.Args[1])
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
		ReadTimeout:    60 * time.Second,
		WriteTimeout:   60 * time.Second,
		MaxHeaderBytes: 12288,
	}
	err = server.ListenAndServeTLS(cfg.Cert, cfg.Key)
	if err != nil {
		log.Fatal(err)
	}
}
