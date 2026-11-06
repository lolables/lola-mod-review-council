// Package pins reads the lock files that own every pinned upstream value.
package pins

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// Read parses a lock file of "key value" lines. Blank lines and lines that
// start with # are skipped.
func Read(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	out := map[string]string{}
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, ok := strings.Cut(line, " ")
		if !ok {
			return nil, fmt.Errorf("%s:%d: want \"key value\"", path, n)
		}
		out[key] = strings.TrimSpace(val)
	}
	return out, sc.Err()
}
