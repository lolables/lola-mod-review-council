import { formatAmount, parseAmount, isSupported } from "./currency.ts";

/**
 * Minimal assertion helpers — this fixture has no test-runner dependency
 * on purpose, so `node --experimental-strip-types src/currency.test.ts`
 * is enough to run it.
 */
function assertEqual<T>(actual: T, expected: T, label: string): void {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${String(expected)}, got ${String(actual)}`);
  }
}

function assertThrows(fn: () => unknown, label: string): void {
  try {
    fn();
  } catch {
    return;
  }
  throw new Error(`${label}: expected a throw, got none`);
}

// formatAmount takes MINOR units.
assertEqual(formatAmount(1999, "USD"), "$19.99", "formats cents");
assertEqual(formatAmount(0, "USD"), "$0.00", "formats zero");
assertEqual(formatAmount(5, "USD"), "$0.05", "pads single-digit minor");
assertEqual(formatAmount(-2550, "USD"), "-$25.50", "formats negatives");
assertEqual(formatAmount(100000, "GBP"), "£1000.00", "formats large GBP");
assertThrows(() => formatAmount(100, "XYZ"), "rejects unknown currency");

// parseAmount is the inverse.
assertEqual(parseAmount("$19.99"), 1999, "parses cents");
assertEqual(parseAmount("-$25.50"), -2550, "parses negatives");
assertEqual(parseAmount(" $0.05 "), 5, "tolerates surrounding space");
assertThrows(() => parseAmount("nineteen dollars"), "rejects prose");

assertEqual(isSupported("EUR"), true, "EUR supported");
assertEqual(isSupported("JPY"), false, "JPY unsupported");

console.log("currency: all assertions passed");
