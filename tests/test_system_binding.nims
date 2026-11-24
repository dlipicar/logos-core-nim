# The system-service binding's suite (Tier 5 step 5-6a-2; plan §10.2; DECISIONS G493): the shared
# call-worker pool lowered to two workers and two nested ones, so the case that fills it holds four
# calls. Test builds only; every other build keeps the defaults (`runtime/plumbing.nim`).
switch("define", "lcnMaxCallWorkers=2")
switch("define", "lcnMaxNestedCallWorkers=2")
