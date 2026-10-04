"""gchp_aws — GCHP -> AWS provisioning calculator.

Given a GCHP simulation intent (resolution, mechanism, sim length, HISTORY level,
and a goal like cheapest/fastest/fits-in-N-nodes), estimate the AWS provisioning
answer: per-node memory, valid grid layouts, which instance types fit, throughput
(sim-days/day) and $/sim-day, and the derived config guardrails.

Design principle: HONESTY. Every numeric output is tagged
MEASURED / INTERPOLATED / EXTRAPOLATED / UNKNOWN with a source (file:line+date).
Where there is no basis, the tool returns UNKNOWN and refuses to guess.

Shares its grid-constraint core with scripts/validate_gchp_config.py (the backward
validator); this package is the forward counterpart.
"""

__version__ = "1.0.0"
