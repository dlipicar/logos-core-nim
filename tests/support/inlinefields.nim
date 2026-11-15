## The inline byte arrays of a type (Tier 4b step 4b-3b, W-12; DECISIONS
## G276): every field, in every branch of a case object, through objects,
## tuples and distinct types, that is an `array` held in the value itself.
## Heap parts (`seq`, `string`, `ref`) and pointers stop the walk: a channel
## under orc moves those, and copies only what is inline (`copyMem` of the
## message's size into its queue slot).

import std/[macros, typetraits]

proc walk[T](path: string, acc: var seq[string])

macro expandFields(T: typedesc, path: string, acc: untyped): untyped =
  ## One `walk` per field of the object or tuple `T`, in every branch.
  result = newStmtList()
  var impl = getTypeImpl(T)
  if impl.kind == nnkBracketExpr and impl[0].eqIdent("typeDesc"):
    impl = getTypeImpl(impl[1])

  proc addFields(res, rec, path, acc: NimNode) =
    case rec.kind
    of nnkRecList:
      for c in rec:
        addFields(res, c, path, acc)
    of nnkIdentDefs:
      let ty = rec[^2]
      for i in 0 ..< rec.len - 2:
        let name =
          if rec[i].kind == nnkPostfix:
            $rec[i][1]
          else:
            $rec[i]
        res.add quote do:
          walk[`ty`](`path` & "." & `name`, `acc`)
    of nnkRecCase:
      addFields(res, rec[0], path, acc)
      for i in 1 ..< rec.len:
        addFields(res, rec[i][^1], path, acc)
    of nnkEmpty, nnkNilLit, nnkSym:
      discard
    else:
      error("unexpected " & $rec.kind & " in an object", rec)

  case impl.kind
  of nnkObjectTy:
    if impl[1].kind == nnkOfInherit:
      let parent = impl[1][0]
      result.add quote do:
        walk[`parent`](`path`, `acc`)
    addFields(result, impl[2], path, acc)
  of nnkTupleTy:
    addFields(result, newTree(nnkRecList, impl[0 .. ^1]), path, acc)
  of nnkTupleConstr:
    for i, ty in impl:
      let name = $i
      result.add quote do:
        walk[`ty`](`path` & "." & `name`, `acc`)
  else:
    error("not an object or a tuple: " & impl.repr, T)

proc walk[T](path: string, acc: var seq[string]) =
  when T is array:
    acc.add(path)
  elif T is (seq or string or ref or ptr or pointer or cstring or proc):
    discard
  elif T is distinct:
    walk[distinctBase(T)](path, acc)
  elif T is (object or tuple):
    expandFields(T, path, acc)
  else:
    discard

proc inlineArrays*(T: typedesc): seq[string] =
  ## The paths of `T`'s inline arrays, from `T`'s own name.
  walk[T]($T, result)
