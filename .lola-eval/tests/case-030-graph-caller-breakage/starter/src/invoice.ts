import { formatAmount } from "./currency.ts";

export interface InvoiceLine {
  description: string;
  amountCents: number;
}

export interface Invoice {
  number: string;
  currency: string;
  lines: InvoiceLine[];
}

/** Total an invoice, in minor units. */
export function invoiceTotalCents(invoice: Invoice): number {
  return invoice.lines.reduce((running, line) => running + line.amountCents, 0);
}

/**
 * Render an invoice as plain text.
 *
 * The currency comes off the invoice rather than being hardcoded, because
 * invoices are issued in the customer's billing currency.
 */
export function renderInvoice(invoice: Invoice): string {
  const header = `Invoice ${invoice.number}`;
  const body = invoice.lines.map(
    (line) =>
      `  ${line.description}: ${formatAmount(line.amountCents, invoice.currency)}`,
  );
  const total = `  TOTAL: ${formatAmount(invoiceTotalCents(invoice), invoice.currency)}`;

  return [header, ...body, total].join("\n");
}
