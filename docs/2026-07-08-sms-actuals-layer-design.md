# SMS Actuals Layer - Split Implementation Index

**Date:** 2026-07-09
**Source before split:** `docs\2026-07-08-sms-actuals-layer-design.md`
**Purpose:** This index replaces the previous long single-file spec with smaller implementation-focused files so agents can work one section at a time.

## Context budget rule

Each split file is intentionally far below the requested ~300k-character context budget. Agents should load this index plus only the part needed for their current task.

## Reading order

1. `docs\2026-07-08-sms-actuals-layer-design\01-product-scope-architecture.md`
   - Product goal, hard requirements, local-only constraints, component responsibilities.
2. `docs\2026-07-08-sms-actuals-layer-design\02-data-ingestion-storage-parser.md`
   - SQLite models, dedup, SMS scan flow, parser rules.
3. `docs\2026-07-08-sms-actuals-layer-design\03-forecast-reconciliation-engine.md`
   - Dated forecast ledger, one-owner/completeness rules, anchors, cash, cards, transfers, P2P, UI why-log.
4. `docs\2026-07-08-sms-actuals-layer-design\04-platform-testing-risks-implementation.md`
   - Android/privacy dependencies, tests, risk register, implementation phases.
5. `docs\2026-07-08-sms-actuals-layer-design\05-planner-gmail-appendix.md`
   - Future planner compatibility and Gmail parser appendix.

## Agent usage guide

- Foundation/persistence/parser work: read parts 01 and 02.
- Forecast/reconciliation/card/cash/accounting work: read parts 01 and 03.
- Platform/privacy/testing/phase planning work: read parts 01 and 04.
- Gmail-specific or future planner work: read parts 01 and 05.
- Cross-cutting changes must re-check part 04 tests and risks.

## Split files

| File | Approx chars | Original lines | Scope |
|---|---:|---:|---|
| docs\2026-07-08-sms-actuals-layer-design\01-product-scope-architecture.md | 19827 | 1-268 | Metadata, goal, north star, hard requirements, scope, constraints, architecture, component responsibilities |
| docs\2026-07-08-sms-actuals-layer-design\02-data-ingestion-storage-parser.md | 15248 | 269-479 | Data model, transactions table, obligations table, dedup, scan flow, parser, Indian SMS parsing techniques |
| docs\2026-07-08-sms-actuals-layer-design\03-forecast-reconciliation-engine.md | 31162 | 480-944 | Dated forecast ledger, coverage lines, owner/completeness reconciliation, anchors, salary, income, cash, transfers, card cycles, annual/P2P, why-log, UI |
| docs\2026-07-08-sms-actuals-layer-design\04-platform-testing-risks-implementation.md | 21648 | 945-1206 | Platform/privacy/permissions, dependencies, test strategy, risks, implementation phases |
| docs\2026-07-08-sms-actuals-layer-design\05-planner-gmail-appendix.md | 7465 | 1207-1308 | Future planner relationship and Gmail parsing appendix |

## Integrity note

The body content of the split files was generated from the previous single-file spec and verified during generation to match the original source content in order. Each split file has a small generated header above its original body lines.

