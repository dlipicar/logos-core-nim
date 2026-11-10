## Value trees of tests/vectors/hash/layout.cbor (oracle/gen_hash_vectors.py): the
## COMMITMENT §9.3 shape plus the list annotations 100 (element schema identity) and
## 101 (packable scalar kind), and the generators that file names for large trees.

import std/[sequtils, strformat]
import ../../src/logos_core/[cbor, hash]

proc ident*(b: byte): Digest =
  for i in 0 ..< DigestLen:
    result[i] = b

proc at(v: CborValue, k: uint64): CborValue =
  v.lookup(k).get

proc digestAt(v: CborValue, k: uint64): Digest =
  toDigest(v.at(k)).get

proc vectorNode*(v: CborValue): ValueNode

proc scalarData(kind: ScalarKind, v: CborValue): ScalarData =
  case kind
  of skBool:
    boolScalar(v.getBool.get)
  of skUint8 .. skUint64:
    uintScalar(kind, v.getUint64.get)
  of skInt8 .. skInt64:
    intScalar(kind, v.getInt64.get)
  of skTstr:
    textScalar(v.getText.get)
  of skBstr:
    bytesScalar(v.getBytes.get)

proc vectorNode*(v: CborValue): ValueNode =
  let kind = v.at(0).getText.get
  # Field 1 is the schema identity everywhere but in a field (its name).
  let schema =
    if kind == "field":
      default(Digest)
    else:
      v.digestAt(1)
  case kind
  of "map":
    mapNode(schema, v.at(2).items.mapIt(vectorNode(it)))
  of "field":
    fieldNode(v.digestAt(2), v.at(1).getText.get, vectorNode(v.at(3)))
  of "absent":
    ValueNode(kind: vkAbsent, schema: schema)
  of "list":
    let pack =
      if v.lookup(101'u64).isSome:
        Opt.some(parseScalarKind(v.at(101).getText.get).get)
      else:
        Opt.none(ScalarKind)
    listNode(schema, v.digestAt(100), v.at(3).items.mapIt(vectorNode(it.at(3))), pack)
  of "tuple":
    tupleNode(schema, v.at(3).items.mapIt((it.digestAt(2), vectorNode(it.at(3)))))
  of "choice":
    choiceNode(schema, v.at(2).getUint64.get, v.digestAt(3), vectorNode(v.at(4)))
  of "scalar":
    let kind = parseScalarKind(v.at(2).getText.get).get
    scalarNode(schema, scalarData(kind, v.at(3)))
  of "reference-value":
    referenceNode(schema, v.digestAt(2), v.digestAt(3), vectorNode(v.at(4)))
  else:
    raiseAssert "unexpected node " & toDiag(v)

proc vectorRoot*(v: CborValue): ValueRoot =
  ValueRoot(
    modelId: v.at(1).getText.get,
    schemaRoot: v.digestAt(2),
    subtreeRoot: v.digestAt(3),
    node: vectorNode(v.at(4)),
  )

proc generated*(name: string, n: int): ValueRoot =
  ## The large trees of oracle/gen_hash_vectors.py `generated`.
  let
    root = ident(0x10)
    list = ident(0x11)
    elem = ident(0x12)
    bstr = ident(0x13)
    pos = ident(0x14)
    field = ident(0x15)
  var (subtree, node) = (list, ValueNode(nil))
  case name
  of "packed-uint8-list":
    node = listNode(
      list,
      elem,
      toSeq(0 ..< n).mapIt(scalarNode(elem, uintScalar(skUint8, uint64(it mod 256)))),
      Opt.some(skUint8),
    )
  of "tstr-list":
    node =
      listNode(list, elem, toSeq(0 ..< n).mapIt(scalarNode(elem, textScalar(&"s{it}"))))
  of "bstr":
    subtree = bstr
    node = scalarNode(bstr, bytesScalar(toSeq(0 ..< n).mapIt(byte(it mod 251))))
  of "uint8-tuple":
    node = tupleNode(
      list,
      toSeq(0 ..< n).mapIt(
        (pos, scalarNode(pos, uintScalar(skUint8, uint64(it mod 256))))
      ),
    )
  of "uint8-map":
    node = mapNode(
      list,
      toSeq(0 ..< n).mapIt(
        fieldNode(
          field,
          &"f{it:06d}",
          scalarNode(field, uintScalar(skUint8, uint64(it mod 256))),
        )
      ),
    )
  else:
    raiseAssert "unknown generator " & name
  ValueRoot(
    modelId: CommitmentModelId, schemaRoot: root, subtreeRoot: subtree, node: node
  )

proc hashAppB1*(): ValueRoot =
  ## [SPEC HASH App B.1] a `uint16` list holding 0 through 256, under the synthetic
  ## identities 0x10 (schema root), 0x11 (list schema) and 0x12 (element schema).
  let values =
    toSeq(0'u64 .. 256'u64).mapIt(scalarNode(ident(0x12), uintScalar(skUint16, it)))
  ValueRoot(
    modelId: CommitmentModelId,
    schemaRoot: ident(0x10),
    subtreeRoot: ident(0x11),
    node: listNode(ident(0x11), ident(0x12), values, Opt.some(skUint16)),
  )

proc hashAppB2*(): ValueRoot =
  ## [SPEC HASH App B.2] 4097 bytes; byte `i` is `i` modulo 251. Byte-string schema
  ## identity 0x13.
  ValueRoot(
    modelId: CommitmentModelId,
    schemaRoot: ident(0x10),
    subtreeRoot: ident(0x13),
    node:
      scalarNode(ident(0x13), bytesScalar(toSeq(0 ..< 4097).mapIt(byte(it mod 251)))),
  )
