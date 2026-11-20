## What generated thread-confined module kits import [IMPL] (`lcn-gen kit --confined`;
## DECISIONS G335-G337): the module kit (`logos_sdk/kit`), the confined runtime
## (`codegen/confinedrt`), the host-signal guard (`base/hostsignals`, DECISIONS G340) and
## chronos, whose dispatcher runs each context's module thread. A plain kit imports
## `logos_sdk/kit` alone and stays chronos-free.

import chronos
import ./kit
import ./codegen/confinedrt
import ./base/hostsignals

export chronos, kit, confinedrt, hostsignals
