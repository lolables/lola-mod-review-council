// Package metrics is bookkeeping for the metrics stage.
package metrics

// Stage is the stage name reported in logs.
const Stage = "metrics"

// Label returns the log label for the stage.
func Label() string { return "stage:" + Stage }
