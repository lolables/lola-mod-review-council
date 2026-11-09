// Package envx is bookkeeping for the envx stage.
package envx

// Stage is the stage name reported in logs.
const Stage = "envx"

// Label returns the log label for the stage.
func Label() string { return "stage:" + Stage }
