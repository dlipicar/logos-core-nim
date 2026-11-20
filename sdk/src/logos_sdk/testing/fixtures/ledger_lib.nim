## The ledger fixture (`ledger_impl.nim`) as a module library whose main
## module imports chronos before the kit, as storage's does. Built with
## `--import:logos_sdk/base/hostsignals` (`kitbuild`, the guide's build line),
## it still leaves its host's `SIGPIPE` disposition as it found it
## (DECISIONS G340; `sdk/tests/test_kit_dylib.nim`).

{.warning[UnusedImport]: off.}
import chronos # first, on purpose
import ./ledger_impl
