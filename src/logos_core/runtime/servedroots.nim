## What a provider's endpoint serves (re-pin P8b; plan `tier5-plans/repin/P8.md`
## §2.5, synthesis Q4; DECISIONS G394): the contracts a session may select at
## the endpoint and the construction input each session's boundary is built
## from. The Runtime's endpoint for a direct provider (`engine.servedEndpoint`)
## and a Module Host's endpoint (`host/endpoint.nim`, `host/selected.nim`)
## both take them from here, so a session on an earlier contract is served
## the same way in either.

{.push raises: [].}

import std/strutils
import results
import logos_sdk/cbor
import logos_sdk/hash/hashinput
import logos_sdk/iface/[accept, surface]
import ../transport/io/api

type ServedContracts* = object
  roots*: seq[Digest]
    ## [SPEC RUNTIME l.88-91; INTERFACE l.201] every contract a session may
    ## select: the primary, each implemented interface, then each earlier
    ## contract the binding keeps (`extends`); the Hello tests membership
  primary*: ContractInput
    ## the first root's answer: the boundary of the primary and of each
    ## interface is built from it, as before P8

func systemModule*(module: string): bool =
  ## A Logos-defined module, whose contracts may use reserved names.
  module.startsWith("logos_")

func servedRoots*(b: ModuleBinding): seq[Digest] =
  ## [SPEC RUNTIME l.88-91; INTERFACE l.201] The primary, each implemented
  ## interface, then each earlier contract: the contracts of the validated
  ## surface that a route or a session may select.
  if b.primary.isSome:
    result.add(b.primary.get.root)
  for i in b.interfaces:
    result.add(i.root)
  for e in b.extends:
    result.add(e.root)

proc servedContracts*(b: ModuleBinding): Result[ServedContracts, string] =
  ## The served roots of a validated binding and the primary input. An
  ## earlier contract's input is not built here (`earlierInput`).
  var s = ServedContracts(roots: b.servedRoots)
  if b.primary.isNone and b.interfaces.len == 0:
    return err("the provider has no contract")
  let first = s.roots[0]
  let v = schemaResponse(b, first).valueOr:
    return err("the provider's schema response cannot be built: " & error)
  s.primary =
    ContractInput(root: first, schema: encodeCbor(v), system: systemModule(b.module))
  ok(s)

func isEarlier*(b: ModuleBinding, root: Digest): bool =
  ## `root` is one of the binding's `extends` entries.
  for e in b.extends:
    if e.root == root:
      return true
  false

proc earlierInput*(b: ModuleBinding, root: Digest): Result[ContractInput, string] =
  ## [SPEC INTERFACE §1.2 l.203, §5.1 l.3227-3244; synthesis §3] The
  ## construction input of a session on earlier contract `root`: its own
  ## schema answer, built when a route or session uses it and never kept per
  ## entry by the binding. An answer over 8 MiB is an error, so that view is
  ## not made ready (l.3243-3244).
  if not b.isEarlier(root):
    return err("the root is not an earlier contract of the provider")
  let v = schemaResponse(b, root).valueOr:
    return err("the earlier contract's schema response cannot be built: " & error)
  ok(ContractInput(root: root, schema: encodeCbor(v), system: systemModule(b.module)))
