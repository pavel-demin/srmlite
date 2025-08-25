package main

import (
	"container/list"
	"encoding/json"
	"log"
	"math/rand/v2"
	"net/http"
	"net/url"
	"os"
	"path"
	"sync"
	"time"
)

type Configuration struct {
	Addr    string
	Cert    string
	Key     string
	Servers []string
}

type CacheEntry struct {
	key   string
	value int
}

type Cache struct {
	elements map[string]*list.Element
	list     *list.List
	mutex    sync.RWMutex
}

type RedirectHandler struct {
	Cache   *Cache
	Servers []string
}

func (c *Cache) Add(k string, v int) {
	c.mutex.Lock()
	defer c.mutex.Unlock()

	c.elements[k] = c.list.PushFront(&CacheEntry{key: k, value: v})

	if c.list.Len() > 1024 {
		element := c.list.Back()
		delete(c.elements, element.Value.(*CacheEntry).key)
		c.list.Remove(element)
	}
}

func (c *Cache) Get(k string) (int, bool) {
	c.mutex.RLock()
	element, ok := c.elements[k]
	c.mutex.RUnlock()

	if !ok {
		return 0, false
	}

	c.mutex.Lock()
	c.list.MoveToFront(element)
	c.mutex.Unlock()

	return element.Value.(*CacheEntry).value, true
}

func (h *RedirectHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	rpath := path.Clean(r.URL.Path)
	index, ok := h.Cache.Get(rpath)
	if !ok {
		index = rand.IntN(len(h.Servers))
		h.Cache.Add(rpath, index)
	}
	authz := r.Header.Get("Authorization")
	if authz != "" {
		sep := "?"
		if r.URL.RawQuery != "" {
			sep = "&"
		}
		rpath += sep + "authz=" + url.PathEscape(authz)
	}
	location := h.Servers[index] + rpath
	header := w.Header()
	header.Del("Date")
	header.Set("Location", location)
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
	cache := &Cache{
		elements: make(map[string]*list.Element),
		list:     list.New(),
	}
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
