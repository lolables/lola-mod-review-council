package textutil

import (
	"strings"
	"unicode"
)

// Slugify converts a title into a URL-safe slug: lowercase, with runs of
// non-alphanumeric characters replaced by a single hyphen.
//
// Leading and trailing hyphens are trimmed. An input with no alphanumeric
// content yields the empty string.
func Slugify(title string) string {
	normalized := normalizeSpaces(title)

	var b strings.Builder
	b.Grow(len(normalized))

	lastWasHyphen := false
	for _, r := range strings.ToLower(normalized) {
		switch {
		case unicode.IsLetter(r) || unicode.IsDigit(r):
			b.WriteRune(r)
			lastWasHyphen = false
		case !lastWasHyphen:
			b.WriteByte('-')
			lastWasHyphen = true
		}
	}

	return strings.Trim(b.String(), "-")
}
