# Comm-Log Send Reconciliation — Merchant 501, October 2026, Diwali Campaigns

**TL;DR:** Naive count gives 30. Two adjustments — dropping a campaign still stuck in
approval, and collapsing retry-chain duplicates without touching a standalone
campaign's legitimate repeat send — get to Finance's 22. The query needed a recursive
CTE, not a flat join, because one retry chain is 3 levels deep. Full trail below,
plus two edge cases the spec doesn't fully resolve.

## Approach

The exercise hinges on two rules buried in the data dictionary: a campaign isn't
"reported" until *both* its approval and its send pipeline have cleared, and a retry
(`campaign.parent_id`) is a re-attempt of the *same* underlying communication — except
on a campaign with no retry chain, where every send is its own event. Miss either
rule and you land somewhere between 22 and 30, confidently wrong.

I started from the most obvious query, then added one adjustment at a time, checking
the count against the raw rows by hand after each, until it converged on 22.

## Reconciliation Bridge

| Step | Description | Result | Reason |
|---|---|---|---|
| 0 | Naive count — every `communication_log` row joined to campaigns named like `%Diwali%` for merchant 501, no eligibility or dedup logic | 30 | Starting point: the plain "count all sends" query anyone would write first |
| 1 | Excluded campaign 9004 ("Retry C — pending"), whose `creation_status = 'approval_awaiting'` | 26 | The data dictionary is explicit that a campaign not yet cleared through approval doesn't count toward reported sends, *even if* `communication_log` rows already exist for it. I checked and confirmed: the send pipeline had already produced 4 rows (customers C11–C14) for a campaign that hadn't been approved yet |
| 2 | For campaigns linked into a retry chain via `parent_id`, collapsed repeat attempts by the same customer into a single qualifying send | 22 | A retry is a re-attempt of the *same* underlying communication — a customer retried across 9001→9002→9003 (or 9201→9202) should count once, not once per attempt. Customer C2 was sent twice and C3 three times in the first chain; D1 was sent twice in the second — collapsing those removes 4 duplicate rows. I deliberately did **not** apply this to campaign 9101, which has no retry chain — every send there is its own event, including customer C20's legitimate second send |
| **final** | — | **22** | Matches Finance's reported `target_base` |

> **Before this became a production metric, I'd want two things clarified:**
> 1. **What happens if a chain's *root* is the ineligible one, not a leaf?** Here,
>    9004 (ineligible) was a leaf, so excluding it was clean. If 9001 itself had been
>    `approval_awaiting`, my query would treat 9002/9003 as a new standalone "root"
>    instead of a broken-off chain — a real gap this dataset doesn't force me to
>    resolve, but a different one would.
> 2. **"Reached" is ambiguous** — attempted-in-chain vs. delivered-in-chain. It didn't
>    change the answer here (every chain customer eventually got delivered), but I
>    checked that rather than assumed it, and a dataset without that property would
>    force a real decision.

## Final SQL

See [`final_query.sql`](./final_query.sql) for the full query. Run it with:

```
sqlite3 data/comm_log.db < final_query.sql
```

I built it incrementally rather than in one shot — wrote the `eligible` CTE first and
confirmed the count matched Step 1 (26), then added the chain-detection logic on top
and re-checked after each addition until it converged on 22. Since 9001→9002→9003 is a
3-level chain (not just parent→child), a simple one-hop self-join wouldn't have caught
9003 as part of the same family — that's why the query needs a recursive CTE rather
than a flat join.

## What surprised me

The send pipeline had already run for campaign 9004 — 4 rows sitting in
`communication_log` — before it had even cleared approval. Finance's bookkeeping
and the send pipeline aren't synced; a naive count would silently report sends for
something Finance doesn't consider "live" yet. Second: "duplicate customer in the same
campaign" isn't one concept. Inside a retry chain it's the same communication
re-attempted and should collapse to one; on a standalone campaign (9101) it's two
genuinely separate events and shouldn't collapse at all. Treating those the same way
is the easiest trap in this whole exercise. I also tested whether restricting "reached"
to delivered-only attempts would change the final number — it didn't, since every
chain customer eventually got delivered — but I checked that rather than assumed it.

