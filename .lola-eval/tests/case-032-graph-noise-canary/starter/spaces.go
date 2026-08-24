package textutil

import "strings"

// normalizeSpaces collapses every run of ASCII whitespace into a single
// space and trims the result.
//
// It is the shared front end for Slugify and Wrap: both need predictable
// single-space separation before they can do their own work.
func normalizeSpaces(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
