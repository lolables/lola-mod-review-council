package textutil

import "testing"

func TestSlugifyBasic(t *testing.T) {
	cases := map[string]string{
		"Hello World":            "hello-world",
		"  Leading and trailing ": "leading-and-trailing",
		"Punctuation! Goes: away": "punctuation-goes-away",
		"already-a-slug":          "already-a-slug",
		"Numbers 123 stay":        "numbers-123-stay",
	}

	for in, want := range cases {
		if got := Slugify(in); got != want {
			t.Errorf("Slugify(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSlugifyCollapsesSeparatorRuns(t *testing.T) {
	if got := Slugify("a --- b"); got != "a-b" {
		t.Errorf("Slugify() = %q, want %q", got, "a-b")
	}
}

func TestSlugifyEmptyWhenNoAlphanumerics(t *testing.T) {
	if got := Slugify("!!! ???"); got != "" {
		t.Errorf("Slugify() = %q, want empty", got)
	}
}

func TestSlugifyKeepsUnicodeLetters(t *testing.T) {
	if got := Slugify("Café Münster"); got != "café-münster" {
		t.Errorf("Slugify() = %q, want %q", got, "café-münster")
	}
}
