## The parity pass (step 4b-4; DECISIONS I93): `test_permissions` with a
## Capability Authority bound in place of the internal policy
## (`support/routefixture`, the fake authority of `support/fakeca`), and the
## cases a decision needs: a narrowed, broadened or uncovered permission scope,
## a revoked grant, and a replacement while the decision is pending.

const caParity = true

include ./test_permissions
