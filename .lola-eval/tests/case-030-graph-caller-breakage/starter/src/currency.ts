/**
 * Currency formatting helpers.
 *
 * Every monetary value in this package is an integer count of MINOR units
 * (cents for USD/EUR, pence for GBP). Nothing here accepts a float: money
 * arithmetic on IEEE-754 doubles drifts, and the drift shows up in invoices.
 */

const MINOR_UNITS_PER_MAJOR = 100;

const SYMBOLS: Record<string, string> = {
  USD: "$",
  EUR: "€",
  GBP: "£",
};

const AMOUNT_PATTERN = /^(-?)([^\d]+)(\d+)\.(\d{2})$/;

/**
 * Format an integer count of minor units for display.
 *
 * @param cents - amount in minor units (1999 renders as $19.99)
 * @param currency - ISO 4217 code; must be a key of SYMBOLS
 * @returns the formatted string, e.g. "$19.99"
 * @throws if the currency is not supported
 */
export function formatAmount(cents: number, currency: string): string {
  const symbol = SYMBOLS[currency];
  if (symbol === undefined) {
    throw new Error(`unsupported currency: ${currency}`);
  }

  const negative = cents < 0;
  const magnitude = Math.abs(cents);
  const major = Math.floor(magnitude / MINOR_UNITS_PER_MAJOR);
  const minor = magnitude % MINOR_UNITS_PER_MAJOR;

  const body = `${symbol}${major}.${String(minor).padStart(2, "0")}`;
  return negative ? `-${body}` : body;
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
