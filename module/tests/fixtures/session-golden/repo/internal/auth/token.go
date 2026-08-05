package auth

import "time"

func Valid(exp time.Time) bool {
	return exp.Before(time.Now())
}
