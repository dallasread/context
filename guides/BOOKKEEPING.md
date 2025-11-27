# Semi-Monthly Bookkeeping Process

## Overview

Import scraped bank transactions into the ledger file.

## File Locations

- **Ledger file**: `data/` directory
- **Categorization rules**: `rules/` directory
- **Raw scraped output**: `tmp/YY-MM-DD.dat`

## Workflow

### 1. Merge into ledger

Add new transactions after the `--- CLAUDE ---` marker in the ledger file.

**Important:**
- Comment out duplicates with `; DUPLICATE:` prefix (preserve for audit trail)
- Mark uncategorized transactions with `!` and `(NEEDS CATEGORY)` in payee
- Transactions with `CATEGORY` or `ELIDED` placeholders need manual categorization

### 2. Identify duplicates

Compare by:
- Date
- Payee (normalized)
- Amount

The scraper returns ~60 days of history, so most will be duplicates from previous imports.

### 3. Categorize remaining transactions

Look for `CATEGORY` or `ELIDED` in the posting lines. Common uncategorized sources:
- One-off purchases (Amazon, eBay, PayPal)
- Transfers with cryptic descriptions
- New vendors not in rules

**NEVER create a new category.** Always use an existing category from the ledger. If unsure, ask the user which existing category to use.

## Categorization Rules Structure

Rules are in `rules/*.js` files. Each rule has:

```javascript
{
  matcher: /regex/i,        // Match against raw description
  payee: 'Clean Name',      // Normalized payee name
  category: 'Expenses:...', // Expense/Income account
  elided: 'Assets:...'      // Optional: override default balance account
}
```

If a vendor appears frequently, add a rule to the appropriate file.

## Ledger Entry Format

```
YYYY/MM/DD  * Payee Name
  Category:Account      AMOUNT.00 CAD
  Balance:Account
```

- `*` = cleared, `!` = pending/needs review
- Two spaces before account name
- Amount right-aligned, followed by currency
- Second line can omit amount (auto-balanced)

## Validation

After merging, validate with:

```bash
ledger -f <ledger-file> balance
```

This catches syntax errors and unbalanced transactions.
