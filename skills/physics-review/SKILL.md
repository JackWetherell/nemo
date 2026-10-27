---
name: physics-review
description: "Bounded adversarial review of a derivation, computation or report before it is treated as settled."
version: 1.0.0
author: jack
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Physics, Review, Verification, Critique]
    related_skills: [physics-derivation, physics-numerics, physics-report]
---

# Physics review

Run this **in a fresh context** before treating a substantive result as
complete. The job is to find what is wrong, not to confirm the conclusion.

## Checklist

**Assumptions** — any unstated assumption, missing boundary or initial
condition, or approximation used outside the regime that justifies it.

**Algebra and dimensions** — sign errors, index errors, dropped factors,
dimensional inconsistency, normalisation and convention mismatches between
sections.

**Numerics** — insufficient convergence, tolerance set looser than the
reported precision, an artefact mistaken for physics, a benchmark that does
not actually constrain the observable claimed.

**Inference** — conclusions broader than the evidence; a numerical example
presented as a general proof; correlation in a sweep read as mechanism.

**Citations** — references that do not support the attached sentence,
abstract-only reading presented as full verification, claimed novelty resting
on an unsuccessful search.

## Method

Find the single strongest conclusion and try to construct a counterexample or
an independent derivation that contradicts it. Report the attempt either way —
a failed attempt to break a result is itself evidence.

## Output

Findings linked to the exact equation, line of code or passage. For each:
what is wrong, why it matters, and what would resolve it.

Then state explicitly: which checks you performed, which you could not, and
what remains unresolved.

**Note on limits:** agreement between two model responses is weak evidence.
The strong evidence is derivations, benchmarks and independent calculation.
Say which kind you are offering.
