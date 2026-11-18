## What generated module kits import [IMPL]: the kit runtime, the common mirrors and the common
## types. The Runtime Control client (`kit/rcclient`) stays out, because it carries the whole
## Runtime Control contract: code that needs it imports it directly.

import ./codegen/[kitrt, common_mirrors, common_types]

export kitrt, common_mirrors, common_types
