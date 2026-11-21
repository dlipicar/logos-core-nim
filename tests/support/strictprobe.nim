# The no-test-hooks flake check builds this with -d:lcnKitStrictDestroy and requires the strict
# destroy marker the confined kit's runtime holds under that define (DECISIONS G438).
import logos_sdk/codegen/confinedrt
