import { formatAmount } from "./currency.ts";

export interface RevenueRow {
  month: string;
  revenueCents: number;
  refundsCents: number;
}

/**
 * Render a monthly revenue table.
 *
 * Reporting is always in USD: the finance team reconciles in a single
 * currency and conversion happens upstream of this module.
 */
export function renderRevenueTable(rows: RevenueRow[]): string {
  const header = "MONTH     REVENUE      REFUNDS      NET";

  const body = rows.map((row) => {
    const net = row.revenueCents - row.refundsCents;
    return [
      row.month.padEnd(9),
      formatAmount(row.revenueCents, "USD").padEnd(12),
      formatAmount(row.refundsCents, "USD").padEnd(12),
      formatAmount(net, "USD"),
    ].join("");
  });

  return [header, ...body].join("\n");
}
