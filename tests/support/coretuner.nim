## The tuner configuration fixture as the Runtime accepts it (DECISIONS I87). Apart from
## `tunerconfig` because the acceptance is core's and the kit suites use the fixture without it.

import results
import ../../src/logos_core/runtime/configcheck
import ./tunerconfig

export tunerconfig

proc tunerAccepted*(
    default = Opt.none(seq[byte]), provisioned = Opt.none(seq[byte]), live = false
): AcceptedConfiguration =
  acceptConfiguration(tunerDecl(default, live), provisioned).tryGet
