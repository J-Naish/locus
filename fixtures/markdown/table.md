# Table Syntax Cases

Simple table:

| Category | January | February |
| --- | ---: | ---: |
| Software | 120 | 95 |
| Travel | 0 | 340 |
| Meals | 48 | 52 |

Alignment table:

| Left | Center | Right |
| :--- | :---: | ---: |
| alpha | beta | 12 |
| long left value | centered | 1,234.56 |
| x | y | -7 |

Inline formatting in cells:

| Field | Example |
| --- | --- |
| Link | [brief](../../docs/product/brief.md) |
| Code | `status: draft` |
| Emphasis | **important** and *quiet* |
| Strike | ~~removed~~ |

Empty cells and spacing:

| Field | Value | Notes |
| --- | --- | --- |
| Empty middle |  | Should keep the empty cell |
| Empty end | value |  |
| Spaces |   padded   | trim or preserve visibly |

Escaped pipes:

| Pattern | Meaning |
| --- | --- |
| `a \| b` | Escaped pipe in inline code |
| A \| B | Escaped pipe in text |

Table without outer pipes:

Name | Role | Status
--- | --- | ---
Nishi | Reviewer | Draft
Aoki | Approver | Done

Malformed table-like text should stay readable:

| Missing delimiter row | should not become a table |
| Just | pipes |

| Header | Header |
| --- |
| Too many | cells | here |
| Too few |

Paragraph with | pipes | but no delimiter row should remain a paragraph.

## Quarterly Operating Review

This large table is intentionally business-like and row-heavy. It is useful for
checking row rhythm, numeric alignment, and long cell content.

| Team | Owner | Region | Priority | Status | Budget | Actual | Delta | Risk | Next Step |
| :--- | :--- | :--- | :---: | :---: | ---: | ---: | ---: | :---: | :--- |
| Sales | Nishi | Japan | P0 | Draft | 120,000 | 118,400 | -1.3% | Medium | Confirm enterprise pipeline assumptions before Friday. |
| Finance | Aoki | Global | P1 | Review | 80,000 | 83,250 | +4.1% | Low | Reconcile vendor accruals and update the closing memo. |
| Operations | Tanaka | APAC | P2 | Done | 64,500 | 61,800 | -4.2% | Low | Archive the implementation notes and link the final checklist. |
| Support | Ito | Japan | P1 | Draft | 42,000 | 45,900 | +9.3% | High | Split backlog by customer tier and assign owners for blockers. |
| Product | Sato | Global | P0 | Review | 150,000 | 147,250 | -1.8% | Medium | Review roadmap changes with design and engineering leads. |
| Marketing | Kimura | US | P2 | Waiting | 95,000 | 87,120 | -8.3% | Low | Wait for campaign analytics export from the vendor portal. |
| Legal | Mori | Global | P1 | Review | 30,000 | 34,700 | +15.7% | High | Escalate contract language around data retention. |
| People | Abe | Japan | P3 | Done | 22,500 | 22,400 | -0.4% | Low | Publish the manager FAQ and close the review thread. |
| Security | Kato | Global | P0 | Draft | 110,000 | 126,300 | +14.8% | High | Finish incident tabletop notes and schedule remediation review. |
| Data | Yamada | APAC | P1 | Review | 72,000 | 69,600 | -3.3% | Medium | Validate warehouse usage numbers against billing exports. |
| Design | Watanabe | Global | P2 | Draft | 38,000 | 39,250 | +3.3% | Low | Replace placeholder screenshots with production captures. |
| QA | Suzuki | Japan | P1 | Done | 44,000 | 41,900 | -4.8% | Low | Attach test run summary and known issues appendix. |
| Customer Success | Hayashi | US | P0 | Review | 88,000 | 92,450 | +5.1% | Medium | Confirm renewal risk list with account directors. |
| Platform | Kobayashi | Global | P0 | Draft | 175,000 | 181,300 | +3.6% | High | Decide whether the migration window can move by one week. |
| Research | Fujii | Global | P3 | Waiting | 28,000 | 21,750 | -22.3% | Low | Wait for participant scheduling before updating the forecast. |
| Documentation | Endo | Japan | P2 | Draft | 18,500 | 19,100 | +3.2% | Low | Merge the SKILL.md front matter examples into the handbook. |
| Enablement | Inoue | APAC | P2 | Review | 33,000 | 36,750 | +11.4% | Medium | Check whether translated slides match the latest messaging. |
| Partnerships | Okada | US | P1 | Draft | 54,000 | 57,200 | +5.9% | Medium | Clarify partner launch criteria and update the milestone table. |
| Infrastructure | Maeda | Global | P0 | Review | 210,000 | 205,500 | -2.1% | Medium | Add cost anomaly notes and confirm reserved capacity assumptions. |
| Analytics | Shimizu | Japan | P1 | Done | 48,000 | 47,950 | -0.1% | Low | Publish dashboard links and mark stale metrics as deprecated. |

## Wide Table With Inline Content

This table stresses horizontal width, inline Markdown in cells, and escaped
pipes.

| ID | Document | Author | Links | Tags | Markdown | Notes | Escaped Pipe | Date | Decision |
| ---: | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :---: | :--- |
| 1 | Product brief | nishi | [brief](../../docs/product/brief.md) | `product`, `mvp` | **bold**, *italic*, `code` | Long note that should reveal whether table cells wrap, clip, or force the document column wider than expected. | A \| B | 2026-01-15 | Keep |
| 2 | Requirements | aoki | [requirements](../../docs/requirements.md) | `scope`, `docs` | ~~removed~~ and **kept** | This row intentionally contains more prose than the others so row height and text overflow are easy to inspect. | C \| D | 2026-02-03 | Revise |
| 3 | Roadmap | tanaka | [roadmap](../../docs/product/mvp-roadmap.md) | `planning` | `Phase 2` | Short note. | E \| F | 2026-03-22 | Keep |
| 4 | Architecture | sato | [technical direction](../../docs/architecture/technical-direction.md) | `native`, `core` | **native** and `Rust` | Check that inline code chips do not overlap table chrome. | G \| H | 2026-04-08 | Review |
| 5 | UX direction | kimura | [ux](../../docs/product/ux-direction.md) | `design`, `tone` | *quiet*, **calm** | Verify that emphasis remains readable in dense table rows. | I \| J | 2026-05-19 | Keep |
| 6 | Performance budget | mori | [budget](../../docs/specs/performance-budget.md) | `perf`, `size` | `open`, `scroll`, `edit` | Numeric-looking tokens should remain left aligned in text columns. | K \| L | 2026-06-27 | Update |

## Matrix

This compact matrix checks empty cells, very long headers, inline content, and
symbol-heavy columns.

| Case | Empty | Very Long Header Name For Width Stress | Centered | Right Number | Symbol |
| :--- | :--- | :--- | :---: | ---: | :---: |
| Empty value |  | The middle cell is present but the second column is empty. | yes | 0 | - |
| Long value | filled | This is a deliberately long cell with repeated business prose about quarterly planning, document review, agent-generated drafts, and local-first editing. | maybe | 123,456.78 | * |
| Inline value | filled | Contains [a link](https://example.com), `inline code`, **bold text**, and an escaped pipe A \| B. | no | -987.65 | + |
| Short | x | y | z | 1 | = |
