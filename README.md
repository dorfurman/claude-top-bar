# CrabBar

Claude Code usage in your macOS menu bar. A dark pill showing how much of your 5-hour
limit is gone, read live from claude.ai — not estimated — and a popover with the other
windows and a local activity breakdown behind it.

```
🦀 16% ▬▬▭ 4h53m
```

## Build

```sh
./build.sh          # compiles, ad-hoc signs, runs the self-test
open CrabBar.app
```

No Xcode project, no dependencies — `swiftc` over `Sources/` into an app bundle.
Requires macOS 14+.

## Versioning & updates

`VERSION` is the single source of truth; `build.sh` bakes it into the bundle.
The app checks this repo's latest GitHub release at most every 6 hours: a new
version triggers one notification, an "Update to vX.Y.Z…" item in the
right-click menu, and an update link in the popover footer — clicking any of
them opens the release page. The repo must stay public for the unauthenticated
check to work.

To ship a release:

```sh
./release.sh [major|minor|patch]   # bump, build+test, tag, publish zip to GitHub
```

## What it shows

- **Hero percentage** of the 5-hour limit, with a severity meter (green → yellow → orange →
  red), and the exact reset time. Straight from claude.ai.
- **The other windows** — weekly all-models, weekly Opus, weekly Sonnet — whichever your
  plan actually has, each with its own meter and reset.
- **Projection** — "at this rate you run out in 52m", or "at this rate, ~74% by reset".
- **This session, by model** — which model is eating the window, as shares.
- **Activity per 10 minutes** across the session, once there's enough of it to be a trend.
- **Activity, last 7 days**, as daily bars.
- **Chats** — sessions active in the last 30 minutes, each with a live state: green
  "working" while the agent is mid-turn (read from the transcript tail — a trailing user
  or tool entry means Claude owes a reply), grey "idle Xm" once it's waiting on you.
- Requests, sessions, output tokens, cache reads.

Left-click the pill for the popover, right-click for the menu. Settings covers what the
pill displays, threshold notifications (50/80/95%), and launch at login.

## Where the numbers come from

**The percentages are the real ones.** They come from
`GET https://api.anthropic.com/api/oauth/usage` — the endpoint Claude Code's own `/usage`
uses. Nothing is estimated, back-solved, or inferred from a price table. If the call fails,
the card says so and shows `—`; it never substitutes a guess.

Authentication is CrabBar's own **Sign in with Claude** flow (OAuth + PKCE): the first
launch shows "sign in" in the menu bar pill — click it, approve in the browser, paste the
code back. Tokens live in a keychain item CrabBar owns, so there are no keychain access
prompts, and the app refreshes the token itself from then on.

Polling is deliberately unhurried: every 120 s, plus once when you open the popover (at
most every 20 s). The endpoint rate-limits hard and its 429 is sticky, so a refusal doubles
the interval up to 30 minutes rather than retrying into a wall.

**Everything below the meters is local**, from `~/.claude/projects/**/*.jsonl`, and is
shown as *relative shares only* — no absolute figures, no money. The API reports one number
per window with no breakdown, so splitting it across models, ten-minute buckets and days
needs a per-request weight; published per-token rates are the best available proxy for how
much of a window a request consumes. That weight is never rendered as a dollar amount.

The same trick sharpens the projection. The API's utilization is a running total and can't
say how fast you're going *right now*; the local scan can, in weight units. Scaling the
recent local burn by the window's own points-per-weight gives a rate in real percentage
points per hour. With no local weight to scale by it falls back to the flat average across
the window.

**The local 5-hour block** opens on the first message after a ≥5h gap and runs exactly 5h
from *that message's timestamp* — not aligned to the hour. Finding the anchor requires
tracing back to a real gap, so it comes from the 7-day scan, not from a short window. It
drives the local charts only; the reset time shown is the API's.

## Cost of running it

Local scanning is polling, not watching. The 5-hour view rescans only files modified in the window
(~15 MB / 24 files / ~0.4 s) every 15 s; the 7-day view (~58 MB) runs every 5 minutes.
Measured on a 204 MB transcript directory — cheap enough that an incremental cache and an
FSEvents watcher were both measured, found unnecessary, and not built.

## Tests

`./build.sh` runs `--test` and fails the build if anything breaks. It covers the weighting
tiers (including cache-write tiers, intro pricing and fast mode), dedup of sidechain
copies, block tiling and stale-anchor roll-forward, bucketing, burn rate, the
points-per-hour projection and its flat fallback, and formatting.

Other entry points:

```sh
./CrabBar.app/Contents/MacOS/CrabBar --usage          # print every window + model shares
./CrabBar.app/Contents/MacOS/CrabBar --render out.png # render the popover offscreen
```

## Design

Colours come from a validated palette: status ramp for severity, categorical slots in
fixed order for models. The four-hue set used for the model share bar was checked with the
palette validator against the `#1a1a19` surface — lightness band, chroma floor, adjacent
CVD separation (worst ΔE 8.4), normal-vision separation (worst ΔE 19.8) and 3:1 contrast
all pass. Identity never rests on colour alone: every segment is also named in the legend.

The popover commits to the dark surface in both system appearances so it reads as one
object with the pill.
