---
name: physics-derivation
description: "Derive or audit physics equations with explicit assumptions, conventions, dimensional checks and limiting cases."
version: 1.0.0
author: jack
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Physics, Derivation, Mathematics, SymPy, Analysis]
    related_skills: [physics-numerics, physics-review, arxiv]
---

# Physics derivation

For deriving equations, auditing an argument, connecting formalisms, or
resolving conflicting results.

## Procedure

1. **State the target and its regime.** What result, holding where? List the
   independent variables and the unknowns.

2. **Build a symbol table** before any algebra: symbol, meaning, units,
   and the conventions in force — coordinate handedness, metric signature,
   sign of the exponent in the Fourier transform, normalisation. Most
   irreproducible derivations fail here, not in the algebra.

3. **State assumptions, initial conditions and boundary conditions**, and
   name each approximation *before* using it, with the small parameter that
   justifies it.

4. **Derive in auditable steps.** Explain every non-trivial transformation
   and the condition for its validity. An unexplained step is a defect even
   if the result is right.

5. **Check with SymPy** where a specific algebraic identity is in question.
   Save the script under `derivations/`. A simplifier agreeing with you is
   evidence about one expression, not a proof of a general claim.

   ```
   /sandbox/.hermes/workspace/.venv/bin/python
   ```

6. **Attack the result** before accepting it:
   - dimensions on both sides
   - limiting cases (small/large parameter, non-relativistic, free, static)
   - symmetries and conservation laws
   - a known special case with an independent answer
   Then try to break the step you identified as most consequential — seek a
   counterexample or an independent route to the same result.

7. **Save** to `derivations/<topic>.md`: symbol table, assumptions, the
   derivation, checks performed and their outcomes.

## Completion

Finish with: the result, its conditions of validity, the checks performed, and
the strongest remaining objection you could not dismiss.

Label the conclusion exactly one of: **exact**, **approximate** (with the
controlling parameter), **numerically supported**, or **unresolved**.
