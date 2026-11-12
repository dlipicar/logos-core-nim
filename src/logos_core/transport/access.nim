## RUNTIME §9.3 l.3013-3029, TRANSPORT §8.1 l.969-979: a route's access, given
## as declaration subtree roots under the selected contract, turned into the
## names the callee's boundary and session enforce.
##
## A method list item is the root of a method declaration the selected contract
## exposes, or the pinned common schema's `logos.schema` root; an event list
## item is the root of an event declaration (COMMITMENT §9.2
## `declarationRoot`). The Runtime validates a route's lists against the
## selected contract (l.3019-3020), so a root that names nothing here cannot
## come from a validated route; it is left out, which narrows the scope (fails
## closed), and is reported in `unknown`. The same resolution as the Runtime's
## (`runtime/routes.nim`), kept here so the transport does not depend on the
## Runtime.

{.push raises: [].}

import std/[sets, tables]
import results
import ../commitment
import ../iface/[names, surface]
import ./[boundary, hello]

export boundary, hello

type RouteScope* = object
  boundary*: Boundary
    ## the selected contract with the route's method and subscription scope
  publishScope*: Opt[HashSet[string]]
    ## the route's publication scope, as event names; none: the whole contract
  unknown*: seq[Digest]
    ## list items that name nothing under the selected contract (left out)

func methodRoots(b: Boundary): Table[Digest, string] =
  ## Every method the selected contract exposes, and the well-known methods of
  ## the pinned common schema, by declaration root.
  let docs = b.contracts.documents
  for m in b.surface.methods:
    let model = docs[m.doc].model
    let d = model.find(m.name)
    if d.isSome:
      result[declarationRoot(model, d.get)] = m.bare
  let ctx = b.contracts.context
  for (name, kind, _) in ctx.common:
    if kind == dkMethod:
      let d = ctx.commonModel.find(name)
      if d.isSome:
        result[declarationRoot(ctx.commonModel, d.get)] =
          bareMethodName(name, ctx.commonModel.namespace)

func eventRoots(b: Boundary): Table[Digest, string] =
  let docs = b.contracts.documents
  for e in b.surface.events:
    let model = docs[e.doc].model
    let d = model.find(e.id)
    if d.isSome:
      result[declarationRoot(model, d.get)] = e.id

func resolve(
    roots: Table[Digest, string], list: seq[Digest], unknown: var seq[Digest]
): seq[string] =
  for r in list:
    if r in roots:
      result.add(roots.getOrDefault(r))
    else:
      unknown.add(r)

func allNames(roots: Table[Digest, string]): seq[string] =
  for _, name in roots:
    result.add(name)

func applyAccess*(b: Boundary, a: RouteAccess): RouteScope =
  ## [SPEC TRANSPORT §8.1; RUNTIME §9.3 l.3013-3029] The boundary and the
  ## publication scope of a session established under a route with access `a`.
  ## An absent list is the whole selected contract (with `logos.schema` for
  ## methods), an empty one nothing.
  var s = RouteScope(boundary: b)
  if a.methods.isSome or a.subscribeEvents.isSome:
    let mr = methodRoots(b)
    let er = eventRoots(b)
    let methods =
      if a.methods.isSome:
        resolve(mr, a.methods.get, s.unknown)
      else:
        allNames(mr)
    let events =
      if a.subscribeEvents.isSome:
        resolve(er, a.subscribeEvents.get, s.unknown)
      else:
        allNames(er)
    s.boundary = b.withAccess(methods, events)
  if a.publishEvents.isSome:
    s.publishScope =
      Opt.some(toHashSet(resolve(eventRoots(b), a.publishEvents.get, s.unknown)))
  s
