// Package report is bookkeeping for the report stage.
package report

// Stage is the stage name reported in logs.
const Stage = "report"

// Label returns the log label for the stage.
func Label() string { return "stage:" + Stage }
