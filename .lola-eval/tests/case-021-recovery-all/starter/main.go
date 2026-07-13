package main

import (
	"encoding/json"
	"log"
	"net/http"
)

type Status struct {
	Service string `json:"service"`
	Version string `json:"version"`
	Healthy bool   `json:"healthy"`
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(Status{
		Service: "userapi",
		Version: "0.1.0",
		Healthy: true,
	})
}

func main() {
	http.HandleFunc("/health", healthHandler)
	log.Println("listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
