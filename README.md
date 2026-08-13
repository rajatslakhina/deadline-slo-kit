# DeadlineSLO

[![CI](https://github.com/rajatslakhina/deadline-slo-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/deadline-slo-kit/actions/workflows/ci.yml)

**A deadline-propagation and client-side SLO layer for Swift — a today-usable backport of the accepted SE-0526 `withDeadline` primitive, plus the per-stage budget engine the proposal deliberately leaves out.**

Your app promises *"the product page renders in 800 ms."* Underneath that promise sit a cache read, a network fetch, an on-device inference call, and render prep — each with its own timeout, none of which knows what the others have already spent. Per-request timeouts don't add up to an SLO: they drift, they double-count, and when the network stage eats 780 ms, the inference stage still cheerfully starts a 300 ms job nobody will wait for.

The distributed-systems world solved this decades ago with **deadline propagation** — one absolute instant, carried through every layer, checked before every expensive step (Go's `context.WithDeadline`, gRPC deadlines). Swift Evolution has now accepted the same primitive for the language as [SE-0526 `withDeadline`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0526-deadline.md) ([accepted with modifications](https://forums.swift.org/t/accepted-with-modifications-se-0526-withdeadline/88645)) — but it targets a future toolchain, and it stops at "cancel this work at instant X."

This library does two things:

1. **Backports `withDeadline`** to Swift 6.0 with SE-0526's semantics wherever they are backportable — and a written justification for every point where they are not (see the divergence table below).
2. **Builds the SLO budget layer on top** — per-stage allowances, reserves for mandatory late stages, admission control that refuses doomed work, a degradation ladder to fallbacks, and an auditable per-stage ledger.

## What's in the box

| Type | Role |
|---|---|
| `Deadline` | Absolute instant on `ContinuousClock`; clamped arithmetic; tighten-only composition |
| `withDeadline(_:stage:tolerance:clock:operation:)` | SE-0526-semantics racing: run a child task, cancel-and-await on expiry |
| `Deadline.current` | Task-local propagation — any layer can ask "how much time is left?" |
| `checkDeadline(stage:)` | Admission-control checkpoint for expensive synchronous sections |
| `StagePolicy` / `StageSpec` | Pure-data budget policy: `minimumViable`, `reserveForRemainder`, `cap` |
| `SLORun` | Actor executing stages under one operation-wide deadline, with a fallback ladder |
| `BudgetLedger` / `StageReport` | The audit trail: what ran, what degraded, what it cost, what was left |
| `SLOObserver` | Per-stage telemetry hook for your metrics pipeline |

## Sixty-second tour

```swift
import DeadlineSLO

// One user-facing operation, one absolute budget.
let run = SLORun(operation: "product-page-load", budget: .milliseconds(800))

// Cache: fast or not at all.
let snapshot = try await run.run(
    StageSpec(name: "cache-read", policy: StagePolicy(cap: .milliseconds(100)))
) {
    try await cache.read()
} fallback: {
    CachedPage.empty
}

// Network: whatever is left, minus a 200 ms reserve for inference + render prep.
let page = try await run.run(
    StageSpec(name: "network-fetch", policy: StagePolicy(
        minimumViable: .milliseconds(50),
        reserveForRemainder: .milliseconds(200)
    ))
) {
    try await api.fetchPage()
} fallback: {
    snapshot.asPage()
}

// On-device inference: full model if the budget survived, lite model otherwise.
let ranked = try await run.run(
    StageSpec(name: "on-device-rerank", policy: StagePolicy(minimumViable: .milliseconds(40)))
) {
    try await fullModel.rerank(page)
} fallback: {
    try await liteModel.rerank(page)
}

// Where did the 800 ms actually go?
let ledger = await run.ledger()   // per-stage outcome, elapsed, remaining-after
```

The primitive underneath is available on its own, and propagates through structured concurrency:

```swift
let value = try await withDeadline(in: .milliseconds(500), stage: "search") {
    try await index.query(term)           // any layer below may call
}                                          // checkDeadline() or read Deadline.current
```

## Design decisions — and what was rejected

### 1. Absolute deadlines, not duration timeouts

A duration re-interpreted at each layer drifts: scheduling delay, queueing, function prologues all silently erode it, and two sibling calls given "500 ms each" can spend a full second. An absolute instant survives any number of hops unchanged. This is SE-0526's own core argument (its earlier `withTimeout` shape was rejected for exactly this), and it is why `Deadline` wraps a `ContinuousClock.Instant`, not a `Duration`.

### 2. SE-0526 fidelity where possible, documented divergence where not

The backport preserves the accepted proposal's observable semantics: the operation runs as a **child task** (structured, never leaked, cancel-and-await on expiry — `withDeadline` may return *later* than the deadline if the operation is slow to acknowledge cancellation, and that is correct); nested scopes compose to the **minimum** deadline; and — the subtle one — **the operation's response to cancellation decides the outcome**: a value produced while unwinding is returned, an error thrown while unwinding propagates. A naive "race and throw when the timer wins" implementation gets this wrong; the test suite feeds one exactly that scenario and would catch it.

Four divergences were forced, not chosen:

| # | SE-0526 | This backport | Why |
|---|---|---|---|
| D1 | Expiry = `CancellationError` with new `reason: .deadlineExpired` | Distinct `DeadlineExceededError` | A package cannot add stored properties to the standard library's resilient `CancellationError`; a distinct type is the only honest signal available to a library |
| D2 | Non-escaping `nonisolated(nonsending)` closure | `@escaping @Sendable` closure | The accepted closure shape needs SE-0461 caller's-executor semantics (Swift 6.2+); a task-group child on 6.0 requires escaping + Sendable |
| D3 | Runtime accessors `Task.activeDeadline(for:)` | `Deadline.current` task-local | The runtime accessors can only be implemented inside the standard library; the task-local is the library-land equivalent, and is what the SLO layer reads |
| D4 | Operation starts even if already expired (born cancelled) | Admission control: never starts | For SLO budgeting, refusing provably-doomed work is the point; this strengthening is deliberate and tested |

### 3. Nested deadlines can only tighten

`withDeadline` computes `min(enclosing, supplied)` via the task-local and publishes the result. An inner scope asking for "an hour" inside a 150 ms scope gets 150 ms. Without this rule, any library you call could silently extend your SLO.

### 4. Cancellation is not a deadline

If the surrounding task is cancelled, callers see `CancellationError`, never `DeadlineExceededError` — and `SLORun` **refuses to run fallbacks on cancellation**. A user who left the screen is not an SLO violation, and degrading on abandonment burns budget on work nobody is waiting for. Conflating the two poisons error-rate dashboards; the discrimination is tested in both layers.

### 5. Reserves and admission control, not proportional splitting

The SLO layer carves each stage's allowance as `min(cap, remaining − reserveForRemainder)`, refusing stages whose allowance falls below `minimumViable`. A proportional split ("network gets 60%, inference 25%…") was rejected: proportions starve mandatory late stages precisely when the budget is under pressure, which is the only time the policy matters. A reserve states the invariant directly: *whatever happens upstream, inference + render prep keep 200 ms.*

### 6. `ContinuousClock`, concretely — not generic clocks

SE-0526 is generic over `Clock & Identifiable` (with per-clock composition rules). This library pins `Deadline` to `ContinuousClock`: the task-local composition model needs one concrete instant type, and monotonic time is the only defensible basis for latency SLOs. Trade-off documented on the type: `ContinuousClock` keeps counting through device sleep, so a deadline spanning suspension has usually expired on wake — for user-facing budgets that is the desired reading. A `SuspendingClock` variant was considered and deferred rather than made generic.

### 7. An actor ledger that documents its reentrancy story

`SLORun` is an actor; stages are intended to run sequentially from one task. Concurrent `run` calls are memory-safe and their budget math stays correct (allowances always derive from the immutable deadline and the clock), but ledger entries append in settlement order — which is the honest order for an audit trail. That behavior is written down instead of discovered in production.

### 8. Rejected for v1: hedged requests

Hedging (start a backup attempt after a delay, race the two) composes naturally with `withDeadline` and reserves, but it is a policy with real cost implications (duplicate load) that deserves its own design pass rather than a checkbox feature.

## Where the AI angle is real

Hybrid on-device/cloud AI features are the canonical multi-stage budget consumer: a cloud model behind a network call, an on-device model as the degraded path, and a hard product promise about responsiveness. The reserve + fallback ladder is exactly the shape of that problem — *guarantee the on-device path its floor, spend whatever survives the network on quality, and record which model actually answered.* The companion demo app simulates precisely this pipeline.

## Testing philosophy

46 XCTest cases, and none of them are decorative. The suite is built around tests that a plausibly-broken implementation would **fail**:

- The SE-0526 fidelity pair: an operation that swallows cancellation and returns a value after expiry must have that value **returned** (a naive race throws — and fails); an error thrown while unwinding must propagate.
- Composition: an inner scope observes the outer scope's exact instant (`XCTAssertEqual` on instants — an implementation that lets inner deadlines loosen outer ones observes an instant an hour out).
- Policy math asserted with exact durations: ignore the reserve and `1000 − 300 = 700` becomes 1000; ignore the cap and 500 becomes 700.
- Admission control: flags prove doomed primaries **never started**, in both the primitive (D4) and the SLO layer.
- Discrimination: external cancellation surfaces as `CancellationError` and must **not** trigger fallbacks; timing bounds prove the 30 s sleep was actually cancelled (~0.15 s observed) rather than awaited.
- Every clamp (negative durations, zero budgets, zero allowances, division by zero in `spentFraction`) has a test pinning the non-trapping behavior.

Timing assertions use deliberately wide margins (correct ≈ 0.15 s, bound = 10 s, broken ≥ 30 s), so slow CI cannot flake them and a broken implementation cannot sneak past them.

## Using it

```swift
dependencies: [
    .package(url: "https://github.com/rajatslakhina/deadline-slo-kit", from: "1.0.0")
]
```

Then depend on the `DeadlineSLO` product. iOS 17+ / macOS 14+ / any Linux with Swift 6.0.

## Demo app

Demo app: (added after the companion repo is pushed — see below)

## Verification

What was actually verified, stated exactly:

- `swift build -Xswiftc -warnings-as-errors` from a clean `.build` on Swift 6.0.3 (Linux, aarch64): **Build complete, zero warnings.**
- `swift test` on the same toolchain: **46 tests, 0 failures, 1.65 s.**
- [CI](https://github.com/rajatslakhina/deadline-slo-kit/actions) runs on every push: a Linux job (swift:6.0 container) repeating the clean warnings-as-errors build plus the full test suite, and a macOS job running the test suite and a compile check for `generic/platform=iOS Simulator`.
- This repository contains **no app target**; the runnable demo lives in the companion repo, which consumes this package as a version-pinned remote dependency.

## License

MIT — see [LICENSE](LICENSE).
