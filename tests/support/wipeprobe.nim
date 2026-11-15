# The no-test-hooks flake check builds this with -d:lcnWipeAudit alone (-u:lcnTestHooks)
# and requires the marker: the erasure tests' free scan carries it (base/wipeaudit.nim).
import ../../src/logos_core/base/wipeaudit
