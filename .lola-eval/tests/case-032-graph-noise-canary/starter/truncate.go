package textutil

// Truncate shortens s to at most limit runes, appending a single-rune
// ellipsis when anything was removed.
//
// Counting is by rune, not byte, so multi-byte characters are never cut
// in half. A limit below one returns the empty string.
func Truncate(s string, limit int) string {
	if limit < 1 {
		return ""
	}

	runes := []rune(s)
	if len(runes) <= limit {
		return s
	}

	if limit == 1 {
		return "…"
	}
	return string(runes[:limit-1]) + "…"
}
