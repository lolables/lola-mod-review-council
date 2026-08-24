package textutil

import "strings"

// Wrap breaks text into lines of at most width characters, splitting only
// at spaces. A word longer than width is placed on a line of its own and
// is never cut.
//
// A width below one is treated as one. Empty input yields a nil slice.
func Wrap(text string, width int) []string {
	if width < 1 {
		width = 1
	}

	normalized := normalizeSpaces(text)
	if normalized == "" {
		return nil
	}

	var lines []string
	var current strings.Builder

	for _, word := range strings.Split(normalized, " ") {
		switch {
		case current.Len() == 0:
			current.WriteString(word)
		case current.Len()+1+len(word) <= width:
			current.WriteByte(' ')
			current.WriteString(word)
		default:
			lines = append(lines, current.String())
			current.Reset()
			current.WriteString(word)
		}
	}

	if current.Len() > 0 {
		lines = append(lines, current.String())
	}
	return lines
}
