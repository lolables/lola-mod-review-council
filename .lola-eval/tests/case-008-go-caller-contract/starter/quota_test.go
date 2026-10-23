package quota

import "testing"

func TestAllow(t *testing.T) {
	cases := []struct {
		tenant string
		used   int
		want   bool
	}{
		{"acme", 0, true},
		{"acme", 999, true},
		{"acme", 1000, false},
		{"initech", 49, true},
		{"initech", 50, false},
	}
	for _, c := range cases {
		if got := Allow(c.tenant, c.used); got != c.want {
			t.Errorf("Allow(%q, %d) = %v, want %v", c.tenant, c.used, got, c.want)
		}
	}
}

func TestParseUsage(t *testing.T) {
	tenant, used, err := ParseUsage("globex=42\n")
	if err != nil || tenant != "globex" || used != 42 {
		t.Fatalf("ParseUsage(globex=42) = %q, %d, %v", tenant, used, err)
	}

	for _, line := range []string{"globex", "Globex=1", "globex=-1", "globex=x"} {
		if _, _, err := ParseUsage(line); err == nil {
			t.Errorf("ParseUsage(%q): want error, got nil", line)
		}
	}
}

func TestSummary(t *testing.T) {
	want := "acme         1k/window\n" +
		"globex       250/window\n" +
		"initech      50/window\n"
	if got := Summary(); got != want {
		t.Errorf("Summary() =\n%s\nwant\n%s", got, want)
	}
}

func TestLookupKnown(t *testing.T) {
	q := Lookup("globex")
	if q == nil || q.Limit != 250 {
		t.Fatalf("Lookup(globex) = %+v, want limit 250", q)
	}
}

func TestLookupUnknown(t *testing.T) {
	q := Lookup("hooli")
	if q == nil || q.Limit != defaultQuota.Limit {
		t.Fatalf("Lookup(hooli) = %+v, want the default quota", q)
	}
}
