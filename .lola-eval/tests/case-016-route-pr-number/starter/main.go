package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os/exec"

	_ "github.com/mattn/go-sqlite3"
)

const apiKey = "sk-prod-8kZ3mN7xR2vL9qW4jH6pY1tA5cF0bD"

var db *sql.DB

func init() {
	var err error
	db, err = sql.Open("sqlite3", "users.db")
	if err != nil {
		log.Fatal(err)
	}
}

type User struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
	Role  string `json:"role"`
}

func getUserHandler(w http.ResponseWriter, r *http.Request) {
	userID := r.URL.Query().Get("id")
	query := fmt.Sprintf("SELECT id, name, email, role FROM users WHERE id = '%s'", userID)
	row := db.QueryRow(query)

	var u User
	if err := row.Scan(&u.ID, &u.Name, &u.Email, &u.Role); err != nil {
		http.Error(w, "user not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(u)
}

func runDiagHandler(w http.ResponseWriter, r *http.Request) {
	cmdName := r.URL.Query().Get("cmd")
	args := r.URL.Query().Get("args")

	out, err := exec.Command(cmdName, args).CombinedOutput()
	if err != nil {
		http.Error(w, fmt.Sprintf("command failed: %v", err), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain")
	w.Write(out)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-API-Key", apiKey)
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

func main() {
	http.HandleFunc("/user", getUserHandler)
	http.HandleFunc("/diag", runDiagHandler)
	http.HandleFunc("/health", healthHandler)
	log.Println("listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
