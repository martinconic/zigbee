# zigbee — docs

Long-form documentation. The top-level `README.md` is the project
front page; everything else lives here.

## Operational docs

| File | What it is |
|---|---|
| [`usage.md`](usage.md) | Copy-pasteable command sequences for the common scenarios — daemon-mode against testnet bootnodes, single-shot retrieval, large-file flow, SWAP-paid retrieval. |
| [`architecture.md`](architecture.md) | Single-page mental model: what zigbee is (ultra-light client), threading model, the accounting wall and how 0.5c's SWAP issuance removes it. |
| [`plan.md`](plan.md) | Multi-phase roadmap with a phase-status tracking table at the bottom (§9). The source of truth for what's done, in progress, and not started. |
| [`status.md`](status.md) | Operational snapshot: current release, what's done per release, where everything lives, smoke-test command. The most likely doc to be stale, dated at the top. |

## Release notes

One file per shipped release in [`release-notes/`](release-notes/).
Latest: [`0.5.0`](release-notes/0.5.0.md) (retrieval-maturity —
local store, encrypted refs, SWAP cheques).

## Strategic / decision-record docs

| File | What it is |
|---|---|
| [`strategy.html`](strategy.html) | Strategy dossier captured 2026-04-28 — research findings (vertex / weeb-3 / bee PR #5321), zigbee's environmental constraint surfaces, three strategic options analysed, the agreed four-milestone roadmap (0.5 retrieval-maturity → 0.6 push → 0.7 embedded → 0.8 browser), chain-integration model per target, and a concrete ESP32 push walkthrough. Single-file, no external assets — open it directly in a browser. |
| [`iot-roadmap.html`](iot-roadmap.html) | IoT-roadmap captured 2026-04-28 — re-framing of the strategy with **IoT / embedded as the headline focus**. Annotated task table (every work unit tagged for IoT relevance), three gaps closed (ESP32 spike re-classed from "gated" to "planned", five cross-cutting operability items added, three demo tracks added), and a sketch of what an actual IoT deployment looks like (solo maker / small fleet / high-security). Read alongside `strategy.html`. |

These two HTMLs are reference / decision-record documents written at
moments when there was a strategic conversation worth preserving.
They don't replace the operational docs above (which are kept
current); they supplement them with the *why*.
