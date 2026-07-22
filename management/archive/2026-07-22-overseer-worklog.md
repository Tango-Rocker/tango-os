# Overseer Worklog - 2026-07-22

## Session Extractor

- Status: completed
- Source: `/home/dev/codex-extractor` and installed `codex-insights 0.2.0`
- Notes: The earlier July 8 corpus run reviewed 46 sessions. The new supervisor
  seeds existing completed sessions as its baseline and does not pay to review
  them again.

## New Issues

- P004: project-level token usage and supervisor overhead were not measured.

## Matched Historic Patterns

- P001: broad searches and oversized output repeatedly wasted context.
- P002: installed paths repeatedly contaminated source checks.
- P003: manual deployment and incomplete Git disposition caused rework.

## Actions

- process change: batch reviews every five completed sessions.
- cost control: review one 160-line evidence chunk per session with the locally
  proven `gpt-5.4-mini` model at low reasoning.
- measurement: store metadata-only token windows and reviewer-token overhead.
- automation: run a bounded one-shot supervisor from a six-hour user timer.

## Validation

- Baseline: 50 completed sessions, 2,232,994,211 total tokens, 49,012,293
  uncached input tokens, and 77 compactions.
- Recent historical window: five sessions averaging 34,997,816 total tokens,
  1,089,151 uncached input tokens, 84,101 output tokens, and two compactions;
  configured budget status is `pass`.
- Contract: initialization, five-session gating, bounded extractor arguments,
  metadata privacy, reviewer accounting, and explicit failure propagation pass.
- Integration: installed `codex-insights watch` processed five synthetic
  sessions through a fake reviewer with five one-chunk calls and no raw archive.
- Live: `engineos-tools 0.1.0-70` is installed; the user timer is enabled and
  active, the one-shot service result is `success`, and the next run is
  scheduled for 2026-07-22 16:12 local.
- Cost: baseline seeding used zero reviewer tokens. Post-change comparison is
  pending five future completed sessions and no savings claim is made yet.

## Next Overseer Step

- After five new completed sessions, compare the first post-baseline window
  against the baseline and update issue counts from the generated report.
