# Gumroad discovery and SEO plan, September 6, 2026

This is a proposal only. Nothing here has been applied to the live listing, the live
page, or the GitHub repository. Every observation below was taken on
2026-09-06 from the Gumroad API, the public product page, and the repository
working tree.

## One correction to the brief

Ping Warden is not an uptime or endpoint monitor, so it should not chase those
terms. An uptime monitor watches whether a remote service answers, and an
endpoint monitor is a fleet-management idea aimed at IT administrators. Ping
Warden holds down a local network interface so one Mac stops stuttering. The
buyers are people playing GeForce Now or Xbox Cloud Gaming on a MacBook, not
administrators, and ranking for monitoring terms would draw traffic that never
converts. The plan below targets the symptom language those buyers actually
type.

## Where the listing stands today

| Field | Live value | Reaches search as |
| --- | --- | --- |
| Product name | `Ping Warden License` | `<title>`, `og:title`, JSON-LD `name` |
| Category | `Other` (taxonomy 266) | Discover placement |
| Tags | macos, gaming, latency, cloud-gaming, wifi | Discover filtering |
| Custom summary | "One-time $15: the Ping Warden app and a license key…" | JSON-LD `description` |
| Description | `docs/gumroad-product-description.html`, 1,847 characters | `<meta name="description">` |
| Permalink | `pingwarden` | canonical URL |
| Covers | one image, the dashboard screenshot | `og:image` |
| Ratings | none, and no reviews from existing buyers | no `aggregateRating` in JSON-LD |
| Lifetime sales | a handful, below the Discover threshold | Discover eligibility |

## The structural finding

The served HTML at `amesconsulting.gumroad.com/l/pingwarden` is a 17 KB shell.
The 267 KB `landing.html` is fetched and rendered by JavaScript afterwards, so
none of its body text appears in the initial response. Searching the served
HTML for "Why it exists", "Game Mode", and "Barlow" returns zero hits, and the
only occurrences of "AWDL" come from the meta description, which Gumroad
generates from the product description rather than from the landing file.

Two consequences follow. First, the head tags inside `landing.html` do nothing,
which the September 5 review already observed from the other direction when
Gumroad's sanitizer stripped five of them. Second, and more important, rewriting
headings inside `landing.html` for search is close to wasted effort, because a
crawler that does not execute the page never sees them. The indexable surface
is the set of Gumroad product fields in the table above, and that is where the
work belongs.

`landing.html` is also 83.5 percent base64 font data, 223 KB of it, against
44 KB of actual markup. That payload lands on the one page that has to convert,
after the shell has already loaded.

## What Gumroad Discover actually requires

Gumroad's help centre sets two tiers of criteria. At the account level the
payout settings must be complete, the account must reach a balance of at least
$100 from genuine sales, and the risk team must clear a review that takes about
three weeks after the threshold is crossed. At the product level the item needs
at least one successful sale, a selected category, and ratings enabled.

The account has not reached the $100 threshold yet, and a balance figure net of
fees sits lower than the gross, so the gap is wider than it first looks. Discover is therefore a lever to prepare for rather than one to pull this
week. Discover sales also carry a 30 percent fee against 10 percent plus 50
cents for direct sales, and products on Discover are opted into the affiliate
program automatically, so it is worth deciding whether the placement is wanted
at all before the threshold arrives.

Gumroad's documentation does not state a maximum number of tags. It says only
that more descriptive and specific tags improve the chance of being found, so
the count below is a judgement call rather than a documented limit.

## Recommendations, ordered by impact against effort

### 1. Rename the product so the page title carries the search terms

Decided on 2026-09-06: use the short form below.

The `<title>` element is the strongest on-page signal Gumroad exposes, and it
currently reads "Ping Warden License". Nobody searches that. Proposed name:

> **Ping Warden: Stop Wi-Fi Lag Spikes on Mac**

The name also appears in the cart, the receipt, and the buyer's library, so
dropping the word "License" makes the purchase slightly less self-describing.
The existing `custom_receipt` already opens with "Your Ping Warden license key
is above", which covers most of that risk. Watch the first receipt after the
rename to confirm it still reads clearly.

### 2. Move the category off "Other"

Set the category to `software-development/software-and-plugins` (ID 77). The
comparison data supports it: that category holds 957 products at a median of
$21.73, and its top listing is Sindre Sorhus's Supercharge at $20, which is the
same kind of Mac utility sold to the same kind of buyer. Gaming holds 5,905
products at a median of $7.58 and is dominated by VRChat avatars, shaders, and
Minecraft maps, so the audience is wrong and the competition is six times
thicker. Choosing a real category is also the product-level gate for Discover,
so this change unblocks that too. It incidentally suggests $15 is at the low end for the software cohort.

### 3. Rewrite the custom summary

This string becomes the JSON-LD description, which is what rich results show. It
currently leads with the price. Proposed:

> Your Mac's Wi-Fi stutters every few seconds because AirDrop keeps waking the
> radio, and Ping Warden holds it down while you play. One-time $15, open source.

### 4. Rewrite the first sentence of the product description

Gumroad flattens the whole description into the meta description, all 1,847
characters of it, and Google truncates near 160. Only the opening survives, and
it currently reads "helps reduce interruptions from wireless sharing", which
contains none of the words a person in this situation would type. Proposed
opening, replacing the first sentence of `docs/gumroad-product-description.html`
and leaving the rest of that file intact:

> If your Mac stutters every few seconds on Wi-Fi, the cause is usually AWDL,
> the interface behind AirDrop and Handoff, grabbing your radio mid-game. Ping
> Warden is an open source macOS menu bar app that holds AWDL down while you
> play, and the source stays MIT.

That opening sentence is 147 characters, so it survives Google's truncation
window intact instead of being cut mid-clause.

### 5. Replace the tag set

The current five tags name the category of thing. They miss the symptom, which
is what people search. Proposed:

`awdl`, `airdrop`, `wifi-lag`, `ping-spikes`, `jitter`, `macos`, `cloud-gaming`,
`geforce-now`, `latency`, `menu-bar-app`

The search evidence for the symptom terms is consistent. The results for a
lay-language query about Mac Wi-Fi lag spikes are a MacRumors thread titled
around jitter and erratic ping, a GitHub project named `mac-wifi-fix`, and two
independent blog posts, one of which calls AWDL "the silent latency killer".
Those are the words in circulation.

### 6. Ask the five existing buyers for a review

Ratings enabled plus at least one review is a Discover prerequisite, and the
JSON-LD currently carries no `aggregateRating`, so no star rating can appear in
any search result. Five buyers is a small enough list to email by hand, and it costs nothing but
the time to write the emails.

### 7. Point the GitHub homepage at something that converts

The repository has 87 stars and 20 well-chosen topics, and its description is
already strong. Its `homepageUrl` points at the releases page. Pointing it at
the Gumroad landing page instead sends the repository's accumulated authority
somewhere that can sell. This one is public-facing, so it needs your go before
anything changes.

### 8. Trim the font payload, later

Subsetting the four embedded faces or dropping to two would cut most of the
223 KB. This is a real improvement to the page people actually land on, but it
is a conversion and Core Web Vitals question rather than a ranking one, given
that the body never reaches the crawler anyway. It belongs after items 1
through 7.

## What I deliberately left alone

I did not touch price, the covers, the permalink, the rich content licence-key
block, or anything in the buyer-facing content. The permalink `pingwarden` is
already clean and changing it would break the links in the README, the badges,
and the existing receipts. The single dashboard cover image is good, though a
second cover showing the menu bar in place would give the gallery something to
scroll to.
