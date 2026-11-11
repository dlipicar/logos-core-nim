## A native module written with the lcn-gen kit for `shapes_module`
## (tests/kit/shapes_module.cddl): typed provider functions (INTERFACE §2.4)
## that carry every C shape the kit converts.
##
## - `reflect` returns its request as its response, except for `b`:
##   - 13 fails with a message;
##   - 14 returns a response outside its schema (a name over 8 bytes).
## - `pick` finds an entry by id or by name. Id 0 is not found, any other id is
##   the file `/id/<id>`, and a name is a directory listing that name twice.
## - `ping` counts its calls in `pings`, the others in `calls`.

import std/atomics
import ../generated/shapes_module_kit

type Shapes* = ref object
  pings*: Atomic[int]
  calls*: Atomic[int]

proc initModule(_: type Shapes, init: ModuleInit): Result[Shapes, InvocationFailure] =
  ok(Shapes())

proc reflect(
    s: Shapes, request: ShapesReflectRequest
): Result[ShapesReflectResponse, InvocationFailure] =
  s.calls += 1
  case request.b
  of 13:
    err(failure(ecModule, "thirteen"))
  of 14:
    var r = fromChecked(ShapesReflectResponse, toCbor(request))
    r.r = @["much too long"]
    ok(r)
  else:
    ok(fromChecked(ShapesReflectResponse, toCbor(request)))

proc pick(
    s: Shapes, request: ShapesPickRequest
): Result[ShapesPickResponse, InvocationFailure] =
  s.calls += 1
  case request.kind
  of ShapesPickRequestKind.Id:
    let id = request.arm_Id.id
    if id == 0:
      return ok(ShapesPickResponse(kind: ShapesPickResponseKind.False))
    ok(
      ShapesPickResponse(
        kind: ShapesPickResponseKind.True,
        arm_True: ShapesPickResponseARTrueMap(
          entry: ShapesEntry(
            kind: ShapesEntryKind.File,
            arm_File: ShapesEntryARFileMap(path: "/id/" & $id),
          )
        ),
      )
    )
  of ShapesPickRequestKind.Name:
    let name = request.arm_Name.name
    ok(
      ShapesPickResponse(
        kind: ShapesPickResponseKind.True,
        arm_True: ShapesPickResponseARTrueMap(
          entry: ShapesEntry(
            kind: ShapesEntryKind.Dir,
            arm_Dir: ShapesEntryARDirMap(path: "/" & name, entries: @[name, name]),
          )
        ),
      )
    )

proc ping(
    s: Shapes, request: ShapesPingRequest
): Result[ShapesPingResponse, InvocationFailure] =
  s.pings += 1
  ok(ShapesPingResponse())

exportShapesModule(Shapes)
