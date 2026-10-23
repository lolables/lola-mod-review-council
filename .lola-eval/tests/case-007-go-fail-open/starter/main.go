package main

import (
	"flag"
	"log"
	"net/http"
	"time"
)

func main() {
	cfgPath := flag.String("config", "config.json", "path to the JSON configuration file")
	flag.Parse()

	cfg, err := Load(*cfgPath)
	if err != nil {
		log.Fatal(err)
	}

	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           newMux(cfg, NewFlagStore()),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("flagsvc listening on %s", cfg.ListenAddr)
	log.Fatal(srv.ListenAndServe())
}
