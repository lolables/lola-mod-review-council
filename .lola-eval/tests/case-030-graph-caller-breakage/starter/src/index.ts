import { checkoutSummary, type CartLine } from "./checkout.ts";
import { renderInvoice, type Invoice } from "./invoice.ts";
import { renderRevenueTable, type RevenueRow } from "./report.ts";

const cart: CartLine[] = [
  { sku: "TEA-001", quantity: 2, unitPriceCents: 1250 },
  { sku: "MUG-114", quantity: 1, unitPriceCents: 1899 },
];

const invoice: Invoice = {
  number: "INV-2026-0041",
  currency: "GBP",
  lines: [
    { description: "Consulting, 4h", amountCents: 48000 },
    { description: "Travel", amountCents: 7350 },
  ],
};

const revenue: RevenueRow[] = [
  { month: "2026-06", revenueCents: 1_204_500, refundsCents: 32_000 },
  { month: "2026-07", revenueCents: 1_388_250, refundsCents: 11_500 },
];

const summary = checkoutSummary(cart);
console.log(`Subtotal: ${summary.subtotal}`);
console.log(`Shipping: ${summary.shipping}`);
console.log(`Total:    ${summary.total}`);
console.log("");
console.log(renderInvoice(invoice));
console.log("");
console.log(renderRevenueTable(revenue));
