package gate

import (
	"fmt"
	"strings"
)

// Spec is a parsed job spec.
type Spec struct {
	Name  string
	Steps []string
}

// LoadSpec parses the text of a job spec: a "name:" line, then a "steps:"
// line followed by one "  - command" line per step.
func LoadSpec(text string) (Spec, error) {
	var spec Spec
	inSteps := false
	for _, line := range strings.Split(text, "\n") {
		switch {
		case strings.HasPrefix(line, "name: "):
			spec.Name = strings.TrimPrefix(line, "name: ")
		case line == "steps:":
			inSteps = true
		case inSteps && strings.HasPrefix(line, "  - "):
			spec.Steps = append(spec.Steps, strings.TrimPrefix(line, "  - "))
		}
	}
	if spec.Name == "" || len(spec.Steps) == 0 {
		return Spec{}, fmt.Errorf("spec needs a name and at least one step")
	}
	return spec, nil
}

// Run validates every step of spec and returns the steps cleared to execute.
// It stops at the first step the gate denies.
func Run(spec Spec) ([]string, error) {
	var cleared []string
	for _, step := range spec.Steps {
		if err := Validate(step); err != nil {
			return nil, fmt.Errorf("job %s: %w", spec.Name, err)
		}
		cleared = append(cleared, step)
	}
	return cleared, nil
}
