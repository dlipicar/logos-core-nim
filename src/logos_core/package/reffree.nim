## The no-reference check (Tier 5 step 5-5-3, DECISIONS G447; step 5-3c-4, G482): whether a
## type holds no `ref`, `ptr`, `pointer`, closure or `cstring` at any depth, so a value of it
## may cross between threads. A message is copied under refc and moved under orc, and a
## reference that may be part of a cycle belongs to one thread's collector. The worker's
## messages (`pm/jobs.nim`) and the resolver's `Inspection` (G482) are held to it.

import std/macros

proc refFreeNode(t: NimNode, depth: int): bool =
  if depth > 48:
    return false # only a reference makes a type this deep
  case t.typeKind
  of ntyBool, ntyChar, ntyString, ntyEnum, ntySet, ntyInt, ntyInt8, ntyInt16, ntyInt32,
      ntyInt64, ntyFloat, ntyFloat32, ntyFloat64, ntyFloat128, ntyUInt, ntyUInt8,
      ntyUInt16, ntyUInt32, ntyUInt64, ntyRange:
    true
  of ntySequence:
    refFreeNode(t.getTypeImpl[1], depth + 1)
  of ntyArray:
    refFreeNode(t.getTypeImpl[2], depth + 1)
  of ntyDistinct:
    refFreeNode(t.getTypeImpl[0], depth + 1)
  of ntyGenericInst, ntyGenericInvocation, ntyGenericBody, ntyGenericParam:
    let impl = t.getTypeImpl
    if impl.kind in {nnkObjectTy, nnkTupleTy, nnkBracketExpr, nnkDistinctTy}:
      refFreeNode(impl, depth + 1)
    else:
      false
  of ntyObject, ntyTuple:
    var impl = t.getTypeImpl
    proc fields(n: NimNode, depth: int): bool =
      case n.kind
      of nnkRecList, nnkTupleTy, nnkTupleConstr:
        for c in n:
          if not fields(c, depth):
            return false
        true
      of nnkRecCase:
        if not fields(n[0], depth):
          return false
        for i in 1 ..< n.len:
          if not fields(n[i][^1], depth):
            return false
        true
      of nnkIdentDefs:
        refFreeNode(n[^2], depth + 1)
      of nnkSym:
        refFreeNode(n.getTypeInst, depth + 1)
      of nnkEmpty, nnkNilLit:
        true
      of nnkRecWhen:
        false
      else:
        refFreeNode(n, depth + 1)

    case impl.kind
    of nnkObjectTy:
      if impl[1].kind == nnkOfInherit and not refFreeNode(impl[1][0], depth + 1):
        return false
      fields(impl[2], depth)
    of nnkTupleTy, nnkTupleConstr:
      fields(impl, depth)
    else:
      false
  else:
    # ref, ptr, pointer, proc (a closure included), cstring, var, openArray and the rest
    false

macro refFree*(T: typedesc): bool =
  ## [G447] Whether `T` holds no `ref`, `ptr`, `pointer`, closure or `cstring` at any depth:
  ## strings, seqs, arrays, sets, enums, numbers, objects and tuples of them only. It errs
  ## on the safe side: a generic object other than `seq` and `array` (`Opt`, `Result`)
  ## reads as not ref-free, so the job types spell such fields out (`abi`, `hasAbi`).
  newLit(refFreeNode(T.getTypeInst[1], 0))

template requireRefFree*(T: typedesc) =
  ## [G447] A compile-time error unless `T` is `refFree`.
  static:
    doAssert refFree(T), $T & " holds a reference and may not cross threads (G447)"
