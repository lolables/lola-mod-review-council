package envx

import "testing"

func TestExpand(t *testing.T) {
	t.Setenv("GATE_HOME", "/srv/gate")
	if got := Expand("dir=$GATE_HOME/${GATE_HOME}"); got != "dir=/srv/gate//srv/gate" {
		t.Errorf("Expand() = %q", got)
	}
}
