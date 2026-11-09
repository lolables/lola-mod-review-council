// Package lint is bookkeeping for the lint stage.
package lint

// Stage is the stage name reported in logs.
const Stage = "lint"

// Label returns the log label for the stage.
func Label() string { return "stage:" + Stage }
