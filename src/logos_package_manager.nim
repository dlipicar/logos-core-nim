## liblogos_package_manager: the Package Manager module's library (Tier 5 step 5-6a-1;
## DECISIONS G490, G491). Built `--app:lib`; logosd composes it as the reserved
## `hosted_dynamic` instance `package_manager` from the companion library its hash is
## compiled against, and the Module Host loads it under the host configuration's
## `package_manager` mark. docs/PACKAGE-MANAGER.md §6.

import logos_core/pm/facade
