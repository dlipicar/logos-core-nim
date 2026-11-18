## Float width checks for deterministic CBOR (RFC 8949 §4.2.1: the shortest form
## that preserves the value; G38: a longer form is `non-deterministic-cbor`).
## Works on bits only, so NaN payloads are compared exactly.

{.push raises: [].}

import ./value

func toDoubleBits*(width: FloatWidth, bits: uint64): uint64 =
  ## The same value (or NaN payload) as IEEE 754 binary64 bits.
  case width
  of fw64:
    bits
  of fw32:
    let
      sign = (bits shr 31) and 1
      exp = (bits shr 23) and 0xff
      mant = bits and 0x7f_ffff
    if exp == 0xff:
      (sign shl 63) or (0x7ff'u64 shl 52) or (mant shl 29)
    elif exp == 0:
      if mant == 0:
        sign shl 63
      else:
        var p = 22
        while ((mant shr p) and 1) == 0:
          dec p
        let e = uint64(p - 149 + 1023)
        let m = (mant xor (1'u64 shl p)) shl (52 - p)
        (sign shl 63) or (e shl 52) or m
    else:
      (sign shl 63) or ((exp + (1023 - 127)) shl 52) or (mant shl 29)
  of fw16:
    let
      sign = (bits shr 15) and 1
      exp = (bits shr 10) and 0x1f
      mant = bits and 0x3ff
    if exp == 0x1f:
      (sign shl 63) or (0x7ff'u64 shl 52) or (mant shl 42)
    elif exp == 0:
      if mant == 0:
        sign shl 63
      else:
        var p = 9
        while ((mant shr p) and 1) == 0:
          dec p
        let e = uint64(p - 24 + 1023)
        let m = (mant xor (1'u64 shl p)) shl (52 - p)
        (sign shl 63) or (e shl 52) or m
    else:
      (sign shl 63) or ((exp + (1023 - 15)) shl 52) or (mant shl 42)

func fits(double: uint64, mantBits, minExp, maxExp: int): bool =
  let
    exp = int((double shr 52) and 0x7ff)
    mant = double and ((1'u64 shl 52) - 1)
    dropped = 52 - mantBits
  if exp == 0x7ff:
    return (mant and ((1'u64 shl dropped) - 1)) == 0
  if exp == 0:
    return mant == 0
  let e = exp - 1023
  if e > maxExp or e < minExp - mantBits:
    return false
  if e >= minExp:
    return (mant and ((1'u64 shl dropped) - 1)) == 0
  let
    shift = 52 - (e - (minExp - mantBits))
    full = mant or (1'u64 shl 52)
  (full and ((1'u64 shl shift) - 1)) == 0

func fitsHalf*(double: uint64): bool =
  fits(double, 10, -14, 15)

func fitsSingle*(double: uint64): bool =
  fits(double, 23, -126, 127)

func isShortest*(width: FloatWidth, bits: uint64): bool =
  let d = toDoubleBits(width, bits)
  case width
  of fw16:
    true
  of fw32:
    not fitsHalf(d)
  of fw64:
    not fitsSingle(d)

func fromDoubleBits(double: uint64, width: FloatWidth): uint64 =
  let
    sign = double shr 63
    exp = int((double shr 52) and 0x7ff)
    mant = double and ((1'u64 shl 52) - 1)
  case width
  of fw64:
    double
  of fw32, fw16:
    let (mantBits, minExp, expBits) =
      if width == fw32:
        (23, -126, 8)
      else:
        (10, -14, 5)
    let
      dropped = 52 - mantBits
      expMax = (1'u64 shl expBits) - 1
      signOut = sign shl (mantBits + expBits)
    if exp == 0x7ff:
      return signOut or (expMax shl mantBits) or (mant shr dropped)
    if exp == 0 and mant == 0:
      return signOut
    let e = exp - 1023
    if e >= minExp:
      return signOut or (uint64(e - minExp + 1) shl mantBits) or (mant shr dropped)
    let shift = 52 - (e - (minExp - mantBits))
    signOut or ((mant or (1'u64 shl 52)) shr shift)

func cborFloat*(f: float64): CborValue =
  ## The shortest width that preserves `f` exactly.
  let d = cast[uint64](f)
  if fitsHalf(d):
    cborFloatBits(fw16, fromDoubleBits(d, fw16))
  elif fitsSingle(d):
    cborFloatBits(fw32, fromDoubleBits(d, fw32))
  else:
    cborFloatBits(fw64, d)

func toFloat64*(v: CborValue): float64 =
  doAssert v.kind == ckFloat
  cast[float64](toDoubleBits(v.width, v.floatBits))
