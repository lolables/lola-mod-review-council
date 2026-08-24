# Storefront Billing

Billing and reporting helpers for the storefront.

## Money representation

Every monetary value crossing a function boundary in this package is an
**integer count of minor units** — cents for USD and EUR, pence for GBP.
Floats are never used for money.

`src/currency.ts` owns formatting and parsing. Three modules consume it:

| Module              | Uses                                        |
|---------------------|---------------------------------------------|
| `src/checkout.ts`   | cart subtotal, shipping, total              |
| `src/invoice.ts`    | per-line amounts and the invoice total      |
| `src/report.ts`     | the monthly revenue table                   |

## Commands

```bash
npm test         # run the currency assertions
npm run typecheck
npm start        # print a sample checkout, invoice and report
```
