---
name: physics-report
description: "Turn an investigation into a technical report where every quantitative claim is traceable to evidence."
version: 1.0.0
author: jack
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Physics, Writing, Reports, Citations]
    related_skills: [grounded-citations, physics-review, physics-numerics]
---

# Physics report

Output is **Markdown with LaTeX math** (`$$ … $$`) under `reports/`. There is
no LaTeX compiler in this sandbox; do not attempt a typeset PDF.

## Structure

1. **Question and finding** — both in the first paragraph. A reader who stops
   there should know what was asked and what was concluded.
2. **Context** — what was already known, with citations.
3. **Assumptions and methods** — including the regime of validity.
4. **Evidence** — the derivation, the computation, or both.
5. **Interpretation and limitations** — what this does *not* establish.
6. **Reproduction** — exact commands, parameters, environment.
7. **References** — from `references.bib`.

## Traceability rule

Every substantive quantitative claim traces to one of:
a cited source, a saved derivation in `derivations/`, or a saved run in
`runs/`. If it traces to none of these, either generate the evidence or
remove the claim.

Use the `grounded-citations` skill for source grounding.

## Checks before finishing

- Figures: axis labels carry units; captions state what is plotted and under
  what parameters; the figure is regenerated from saved data.
- Citations: each supports the specific sentence it is attached to — not the
  general topic.
- Reproduced vs new: the report distinguishes results reproduced from the
  literature from analysis original to this work.
- Numbers: significant figures match the error budget.
