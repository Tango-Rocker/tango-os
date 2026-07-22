# Issue History

## Recurring Patterns

- ID: P001
  Seen: 7
  Pattern: Broad filesystem searches and unbounded output consume context and
    require interruption.
  Evidence: July 8 extractor reviews 013, 015, 018, 025, 029, 037, and 043.
  Action: Use the AGENTS task router, `rg` path/glob limits, and explicit tool
    output budgets before expanding a search.
  Status: watching

- ID: P002
  Seen: 3
  Pattern: Installed `/usr` paths contaminate source-checkout validation.
  Evidence: July 8 extractor reviews 004, 009, 014, and 030 identified the
    source/installed-path family; `eos-source-test` now clears installed paths.
  Action: Keep source validation behind `eos-source-test <scope>` and retain its
    regression coverage.
  Status: done

- ID: P003
  Seen: 2
  Pattern: Manual live deployment and missing Git disposition create repeated
    rework.
  Evidence: July 8 extractor reviews 013 and 016; committed-range deployment
    and deploy-on-push now own the normal path.
  Action: Keep package-aware `eos dev apply` and the pre-push gate as the
    default finish loop.
  Status: watching

- ID: P004
  Seen: 1 baseline corpus
  Pattern: Long sessions accumulate very large cached and uncached token totals
    without a project-level cost ledger.
  Evidence: The July 22 supervisor baseline reads metadata-only token counters
    from 50 completed Tang-OS sessions: 2,232,994,211 total tokens, 49,012,293
    uncached input tokens, and 77 compactions. Baseline seeding consumed zero
    reviewer tokens.
  Action: Review five-session windows, cap supervisor evidence to one chunk per
    session, and compare post-baseline metrics before claiming improvement.
  Status: watching

## One-Off Issues

- The supervisor timer must remain batch-gated; lowering the threshold below
  five sessions requires explicit cost evidence and user approval.
