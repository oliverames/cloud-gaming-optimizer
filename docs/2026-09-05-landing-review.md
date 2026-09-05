# Landing page review, September 5, 2026

The second landing pass is published at [Ping Warden on Gumroad](https://amesconsulting.gumroad.com/l/pingwarden). This is a website and product-copy update. The signed app remains version 4.0.3.

## Findings and fixes

| Finding | Fix |
| --- | --- |
| The icon competed with the title and compressed the heading. | Place the original app icon above a single-line title, with consistent spacing. |
| The desktop hero was too tall, and its fixed screenshot minimum squeezed intermediate widths. | Reduce padding and copy, allow both columns to shrink, and stack them below 896 pixels. |
| Phone navigation concealed links in a horizontal scroller. | Show four section links in a complete second header row. |
| A floating purchase button covered page content. | Move the persistent purchase action into the header. |
| Sections depended on a reveal observer and timer to become visible. | Remove custom JavaScript and hidden initial states. Native disclosure controls remain interactive. |
| The free download was difficult to find beside the paid offer. | Add a direct download action and explain that the dashboard is free. |
| Game Mode and widget labels implied that enabling protection was free. | Identify the license requirement alongside the existing transition explanation. |
| Small colored text, step numbers, hover buttons, and focus rings needed better contrast. | Use darker gold for light surfaces, darken red button backgrounds, and use a light focus ring on dark sections. |
| The transition disclosure inherited an isolated checklist marker and redundant copy. | Separate the disclosure from the list and remove the duplicate product introduction. |
| The checkout description retained a relative donor cutoff and incomplete setup instructions. | Specify donations before version 4, retain the original transition deadline, and match the app's Verify and setup labels. |

## Verification

- Rendered the prepared page at 320 × 700, 390 × 844, 820 × 1000, 1280 × 720, and 1440 × 900. Document width equals viewport width at every size. Both hero actions fit within the initial 320 × 700 and 390 × 844 phone views and the 1280 × 720 desktop view.
- Reviewed the live Gumroad wrapper at 1280 × 720 and 390 × 844. The icon sits above the heading, images load, and the phone navigation remains visible. Saved local screenshots outside the repository. A stale preview capture initially showed incorrect scaling; reloading after each viewport change produced the correct render.
- Verified section anchors below the sticky header, native disclosure activation by keyboard, the skip link, and visible keyboard focus on the hero purchase action. The preview console reported no warnings or errors.
- Verified dark appearance and reduced motion. The latter produces zero-duration transitions. Restored browser emulation afterward.
- Calculated contrast using sRGB relative luminance: darker gold on the light card is 6.19:1, button hover text is approximately 5.24:1, and the focus ring on the dark surface is 10.55:1. The former button hover was 3.99:1.
- Gumroad's sanitizer removed only five unsupported head tags. It removed no attributes and did not truncate content. All IDs are unique, all local anchors resolve, and all four purchase controls survive.
- Published HTML exactly matches the sanitizer result. SHA-256: `052fe00de61c2033d692b490832ef09927a60bbfc66dc3435ceeef3e3fb29a7b`.
- The checkout description exactly matches `gumroad-product-description.html`. Price, currency, publication, shipping, purchase-limit, and refund settings are unchanged.
- Buyer content is unchanged: the single visible app embed points to `PingWarden-4.0.3.dmg` (5,768,408 bytes), followed by activation instructions and the license-key block. Older stored attachments are not embedded in buyer content.
- The published phone purchase button reaches Gumroad checkout with one Ping Warden License at US$15. No payment was submitted, and the test cart entry was removed.

## Brand review

The page retains the Ames Consulting web family: Barlow Condensed headings, Lora body text, warm light surfaces, and a cool dark hero. Gold marks actions at rest, while red appears on hover. The existing macOS window controls and footer stripe remain intentional exceptions. The original app icon and dashboard asset are unchanged.

## Release and purchase follow-through

GitHub Build Verification and CodeQL passed for the earlier documentation commit `6125e2b` and the landing synchronization commit `2551158`. The app's release and notarization evidence remains in [the September 4 review](2026-09-04-bug-review.md).

After Oliver requested verification of a new purchase, a read-only Gumroad check confirmed that payment, key issuance, access, and non-incrementing license verification succeeded. The response matched the purchase and the exact product ID used by the app. The use count was unchanged. Buyer identity, order identifiers, and the key are excluded from this public record. The sale API does not expose inbox delivery, download completion, or activation on the buyer's Mac, so those steps are not claimed as verified.
