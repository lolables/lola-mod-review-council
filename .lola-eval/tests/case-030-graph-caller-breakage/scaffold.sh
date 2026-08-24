#!/usr/bin/env bash
# scaffold.sh — create git history for case-030-graph-caller-breakage.
#
# The starter's initial code becomes the first commit (handled by reset.sh).
# This script creates a `feat` branch whose single commit rewrites
# src/currency.ts and NOTHING else.
#
# The rewrite breaks every caller in two ways at once:
#
#   1. Unit change  — formatAmount used to take minor units (cents) and
#      divide by 100 internally. It now takes MAJOR units and passes the
#      value straight to Intl.NumberFormat. Every existing call site still
#      passes cents, so every rendered amount is inflated 100x.
#   2. Arity change — a third required parameter, `locale`, was added.
#      Every existing call site passes two arguments.
#
# The four affected sites all live OUTSIDE the diff:
#   src/checkout.ts       (3 calls)
#   src/invoice.ts        (2 calls)
#   src/report.ts         (3 calls)
#   src/currency.test.ts  (6 assertions, now wrong)
#
# A reviewer working from the diff alone can see that the signature changed.
# It cannot enumerate who breaks without looking outside the changeset.
set -euo pipefail
workdir="$1"
cd "$workdir"

git -c user.name="scaffold" -c user.email="scaffold@test" branch -m main
git checkout -b feat --quiet

cat >src/currency.ts <<'TS'
/**
 * Currency formatting helpers.
 *
 * Formatting is delegated to Intl.NumberFormat so that grouping separators
 * and symbol placement follow the caller's locale.
 */

const SYMBOLS: Record<string, string> = {
  USD: "$",
  EUR: "€",
  GBP: "£",
};

const AMOUNT_PATTERN = /^(-?)([^\d]+)(\d+)\.(\d{2})$/;

const MINOR_UNITS_PER_MAJOR = 100;

/**
 * Format a monetary amount for display.
 *
 * @param amount - amount in major units (19.99 renders as $19.99)
 * @param currency - ISO 4217 code
 * @param locale - BCP 47 locale tag driving separators and placement
 * @returns the formatted string
 * @throws if the currency is not supported
 */
export function formatAmount(
  amount: number,
  currency: string,
  locale: string,
): string {
  if (!Object.prototype.hasOwnProperty.call(SYMBOLS, currency)) {
    throw new Error(`unsupported currency: ${currency}`);
  }

  return new Intl.NumberFormat(locale, {
    style: "currency",
    currency,
  }).format(amount);
}

/**
 * Parse a display string back into minor units.
 *
 * @param text - a string produced by formatAmount
 * @returns the amount in minor units
 * @throws if the text is not a recognised amount
 */
export function parseAmount(text: string): number {
  const match = text.trim().match(AMOUNT_PATTERN);
  if (match === null) {
    throw new Error(`unparseable amount: ${text}`);
  }

  const [, sign, , majorText, minorText] = match;
  const magnitude =
    Number(majorText) * MINOR_UNITS_PER_MAJOR + Number(minorText);
  return sign === "-" ? -magnitude : magnitude;
}

/** Report whether a currency code can be formatted. */
export function isSupported(currency: string): boolean {
  return Object.prototype.hasOwnProperty.call(SYMBOLS, currency);
}
TS

git -c user.name="scaffold" -c user.email="scaffold@test" add src/currency.ts
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -m "Localize currency formatting via Intl.NumberFormat"
