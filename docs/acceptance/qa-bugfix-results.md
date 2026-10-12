# QA bug-fix results

Fixes for the defects in the phone UI round 1 report and the Mac manual test guide. Eight stacked PRs, #24 to #31.

**Evidence classes.** UNIT is a passing `swift test`. BUILD is an unsigned build of the app. SIMULATOR is one iPhone 18 Pro on iOS 27, with ATS relaxed in a throwaway copy. None of it is DEVICE evidence. The Mac app was never launched.

## Merge order

Merge #23 first, then #24, #25, #26, #27, #28, #29, #30, #31, each after the one before. Every branch is based on the previous one.

## Phone defects

| ID | Result | PR | Verified | Note |
|---|---|---|---|---|
| D1 nip.io blocked by ATS | Not fixed | – | – | Out of scope: no network settings were touched. |
| D2 no location filter | Fixed | #30 | SIMULATOR | Searchable chooser in the filter menu. |
| D3 shortfall only inside the filter | Fixed | #29 | UNIT | The All list shows the caption. |
| D4 transfer reports an error | Fixed | #24 | UNIT | The spec lacked `transfer_from` and `transfer_to`. |
| D5 unreachable host, no cancel | Fixed | #26 | UNIT, SIMULATOR | 15 s timeout and a Cancel button. |
| D6 no malformed-URL message | Not fixed | – | NOT VERIFIED | The code shows an error path. Not reproduced. |
| D7 greyed rows unexplained | Fixed | #25 | UNIT, BUILD | Rows name the missing permission. |
| D8 unsigned build, no feedback | Not fixed | – | NOT VERIFIED | The Keychain banner exists. Not reproduced. |
| D9 key cannot be cleared | Fixed | #26 | SIMULATOR | Clear button on the key field. |
| D10 wizard wording | Fixed | #31 | BUILD | Says nothing has been shared. |
| D11 demo switch needs a held tap | Not fixed | – | – | Probably a simulator input artifact. |
| D12 default quantity unlabelled | Partly fixed | #31 | BUILD | Label added. The product picker is still unsearchable. |
| D13 Dynamic Type clipping | Fixed | #28 | SIMULATOR | Checked at default and the largest size. |
| D14 tab bar overlaps long forms | Partly fixed | #28 | SIMULATOR | Product screen only. Forms are not changed. |
| Save Password prompt | Not fixed | – | – | Needs a decision. |

## Mac observations

| No. | Result | PR | Verified | Note |
|---|---|---|---|---|
| 1 plain HTTP blocked | Not fixed | – | – | Out of scope, as D1. |
| 2 undo offered without STOCK_EDIT | Fixed | #25 | UNIT | The server needs `STOCK_EDIT`; curl-checked. |
| 3 unchanged count accepted | Fixed | #29 | UNIT | |
| 4 below-minimum shows 0 and no unit | Fixed | #29 | UNIT | Unit comes from the embedded product. |
| 5 parents show own stock only | Fixed | #29 | UNIT, SIMULATOR | List and detail use the aggregate. |
| 6 Measured 0 on every product | Fixed | #29 | BUILD | Hidden when 0. |
| 7 unpriced stock reads 0.00 | Fixed | #29 | UNIT | A value of 0 reads as unknown. |
| 8 negative price, tiny amounts | Fixed | #29 | UNIT | |
| 9 poller never restarts | Fixed | #27 | UNIT | Backs off to five minutes. |
| 10 permissions load once | Fixed | #27 | UNIT | Reloads after a 403 and on change. |
| 11 no commands menu | Fixed | #30 | BUILD | Stock menu with Refresh on Command-R. Not driven. |
| 12 no product-group filter | Not built | – | – | See the questions. |
| 13 due today renders red | Fixed | #31 | BUILD | |
| 14 undo splits lots | Not fixed | – | – | Server behaviour. |
| 15 Cream in two buckets | Not fixed | – | – | Server behaviour. |
| 16 Locations list unsearchable | Not fixed | – | – | The phone chooser is searchable; the Mac sidebar is not. |

## Open questions

1. Where should the Mac product-group filter go, and do groups nest? The instance has none to test with.
2. A `value` of 0 now reads as unknown. That also hides genuinely free stock. Acceptable?
3. The web UI shows a parent's own and aggregated amounts together. The apps show only the aggregate.
4. A key without `STOCK_EDIT` sees the confirmation bar without an Undo button. Hide the bar instead?
5. The 15 s timeout applies to every request. Should it be per operation?
6. ATS: an `NSAllowsArbitraryLoads` entry is ignored while `NSAllowsLocalNetworking` is present. Relevant to the separate ATS discussion.
7. Should the phone Save Password prompt be suppressed?
8. Should long forms get a bottom inset for the floating tab bar?

## Spec repairs added

`Scripts/update-openapi.py` gained three repairs, recorded in `openapi/spec-lock.json`:

- Seven missing transaction types, including `transfer_from` and `transfer_to`.
- The `product` embedded in each `missing_products` entry.
- `stock_amount_aggregated` and `stock_amount_opened_aggregated` on the product detail.
