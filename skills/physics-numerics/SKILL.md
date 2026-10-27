---
name: physics-numerics
description: "Run trustworthy physics computations: method choice, analytical benchmarks, convergence tests, and reproducible runs."
version: 1.0.0
author: jack
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Physics, Numerics, Simulation, SciPy, Reproducibility]
    related_skills: [physics-derivation, physics-review]
---

# Physics numerics

For simulation, integration, fitting, optimisation, parameter sweeps and
reproducing figures.

Interpreter: `/sandbox/.hermes/workspace/.venv/bin/python`
(numpy, scipy, sympy, matplotlib, pandas, pint). A GPU is available if the
problem size justifies it.

## Procedure

1. **State the mathematics first**: the equations, the observable you want,
   its units, and the parameter ranges of interest.

2. **Justify the method.** Why this integrator, solver or discretisation for
   this problem — stiffness, conservation, boundary behaviour, conditioning.
   Name the method's known failure mode.

3. **Write the run as a script** under `src/`, parameters in a file rather
   than inline constants. Record the exact command. No calculation that
   matters should exist only in a shell history.

4. **Benchmark against something you can check.** An analytical limit, a
   conserved quantity, a published value, or a second independent
   implementation. Without this you have output, not a result.

5. **Demonstrate convergence.** Vary step size, grid resolution or tolerance
   and show the observable settling. "The solver returned" and "the answer is
   converged" are different claims — only the second is reportable.

6. **Separate the error budget**: numerical (discretisation, round-off,
   tolerance), model (the physics you left out), and parametric (uncertain
   inputs). Do not report a precision the error budget cannot support.

7. **Save** raw output to `runs/<run-id>/` with parameters, seeds, package
   versions and logs. Figures go to `figures/`, regenerated from the saved
   data by a script — never from numbers pasted by hand.

## Completion

Report: the observable with its uncertainty, the benchmark result, the
convergence evidence, and the dominant error term. State what would change the
answer most.
