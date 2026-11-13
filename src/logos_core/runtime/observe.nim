## Step 7 (DECISIONS I86): what one Runtime Control observation exposes about
## its subject, and whether an allowed observation admits that subject.
##
## [G161 extension (TF-09)] A list method and a Runtime Control event are
## authorized once, without a subject (`AuthzRequest.filters`); the allow is
## then applied to each subject they observe. A Capability Authority allow
## admits a subject when one of its allowed scopes covers, whole, the exact
## scope of observing that subject: the method or event, and one selector per
## fact the observation exposes (CA l.306-308, l.565-567; alternatives are
## never combined, CAP-0117). The internal policy admits a subject when its
## rules allow the request naming it (`Authorizer.permits`).
##
## [G226 interim (TF-34)] The facts are those the observation itself
## exposes: a module record's module, instance and, when the record carries
## it, provider; an instance event's module and instance, never a provider
## (RUNTIME l.3496); a route record's route, provider module, provider
## instance and target provider, never its consumer; a route event's route,
## module and provider. A selector naming a fact the observation lacks does
## not match it.

{.push raises: [].}

import results
import ../authority/scopes
import ./[authscopes, authz, plumbing]

type Subject* = object
  ## The facts kept with an observed record or event, so a later page or
  ## delivery can be judged after the record ceased to be current (RUNTIME
  ## l.3402, l.3420; RUN-0969, RUN-0980).
  module*: string
  instance*: string
  provider*: string ## a provider id, only when the observation exposes it
  route*: string

func instanceSubject*(module, instance: string, provider = ""): Subject =
  Subject(module: module, instance: instance, provider: provider)

func routeSubject*(route, module, instance, provider: string): Subject =
  Subject(route: route, module: module, instance: instance, provider: provider)

func providerSubject*(provider: string): Subject =
  Subject(provider: provider)

func factBytes*(s: Subject): int =
  ## What the facts cost to retain, for snapshot accounting.
  s.module.len + s.instance.len + s.provider.len + s.route.len

proc subjectScope(s: Subject, runtimeId: string, methods, events: seq[Root]): Scope =
  var r = RuntimeControlScope(
    runtime: runtimeId,
    contract: rcContract(),
    methods: Opt.some(methods),
    events: Opt.some(events),
  )
  if s.module.len > 0:
    r.modules = Opt.some(@[s.module])
  if s.instance.len > 0:
    r.instances = Opt.some(@[s.instance])
  if s.provider.len > 0:
    r.providers = Opt.some(
      @[ProviderAddress(provider: s.provider, runtime_instance_id: Opt.some(runtimeId))]
    )
  if s.route.len > 0:
    r.routes = Opt.some(@[s.route])
  toScope(r)

proc methodScope*(operation: string, s: Subject, runtimeId: string): Scope =
  ## Observing `s` through one Runtime Control method, and no event (an
  ## empty event list permits none, CA l.126).
  subjectScope(s, runtimeId, @[rcMethodRoot(operation)], @[])

proc eventScope*(event: string, s: Subject, runtimeId: string): Scope =
  ## Observing `s` through one Runtime Control event (its bare name, without
  ## `_event`), and no method.
  subjectScope(s, runtimeId, @[], @[rcEventRoot(event)])

proc subjectRequest*(q: AuthzRequest, s: Subject): AuthzRequest =
  ## The internal-policy request naming one subject of an observation.
  result = q
  result.filters = false
  result.module = s.module
  result.instance = s.instance
  result.provider = s.provider
  result.route = s.route
  result.target =
    if s.route.len > 0:
      s.route
    elif s.instance.len > 0:
      s.instance
    else:
      s.provider

proc admitsScope*(x: AuthzAnswer, exact: Scope, runtimeId: string): bool =
  ## [SPEC CA l.565-567] A Capability Authority allow: one allowed scope
  ## covers the exact observation whole.
  for a in x.allowedScopes:
    if covers(a, exact, runtimeId):
      return true
  false

# Reasons ------------------------------------------------------------------------------

func reasonText*(s: string): string =
  ## `logos.runtime_control.reason`: at most 512 bytes, cut at a character
  ## boundary.
  if s.len <= 512:
    return s
  var n = 512
  while n > 0 and (uint8(s[n]) and 0xC0'u8) == 0x80'u8:
    dec n
  s[0 ..< n]

func disclosedReason*(f: Failure): Opt[string] =
  ## [SPEC RUNTIME l.1901-1904; RUN-0870 to RUN-0873; IMPL] The `reason` an
  ## observation discloses with a failure: none for a realizer error, whose
  ## message may name host paths; otherwise the Runtime's or the module's
  ## text, cut at 512 bytes.
  if f.internal or f.reason.len == 0:
    return Opt.none(string)
  Opt.some(reasonText(f.reason))
