import { formatAmount } from "./currency.ts";

export interface CartLine {
  sku: string;
  quantity: number;
  unitPriceCents: number;
}

export interface CheckoutSummary {
  subtotal: string;
  shipping: string;
  total: string;
}

const FREE_SHIPPING_THRESHOLD_CENTS = 5000;
const FLAT_SHIPPING_CENTS = 599;

/** Sum a cart's lines, in minor units. */
export function subtotalCents(lines: CartLine[]): number {
  return lines.reduce(
    (running, line) => running + line.quantity * line.unitPriceCents,
    0,
  );
}

/** Shipping is free once the subtotal clears the threshold. */
export function shippingCents(subtotal: number): number {
  return subtotal >= FREE_SHIPPING_THRESHOLD_CENTS ? 0 : FLAT_SHIPPING_CENTS;
}

/**
 * Render the three lines a customer sees at checkout.
 *
 * Every value handed to formatAmount is in minor units, matching the
 * contract documented on currency.ts.
 */
export function checkoutSummary(lines: CartLine[]): CheckoutSummary {
  const subtotal = subtotalCents(lines);
  const shipping = shippingCents(subtotal);

  return {
    subtotal: formatAmount(subtotal, "USD"),
    shipping: formatAmount(shipping, "USD"),
    total: formatAmount(subtotal + shipping, "USD"),
  };
}
