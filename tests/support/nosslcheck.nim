## [IMPL-DECISION G409] The flake check `logosd-no-ssl` on the shipped logosd:
##
##   nosslcheck NIMCACHE PROGRAM
##
## NIMCACHE is `sslprobe.nim`'s, compiled with the same compiler; exit 1 when
## PROGRAM holds a symbol only libssl's objects define, or none of libcrypto's
## (`nossl.nim`).

import std/[os, sets]
import ./nossl

let args = commandLineParams()
if args.len != 2:
  quit("usage: nosslcheck NIMCACHE PROGRAM", 2)
let c = checkNoSsl(args[0], args[1])
let p = c.problem
if p.len > 0:
  stderr.writeLine(args[1] & ": " & p)
  quit(1)
echo args[1],
  ": none of the ",
  c.candidates.len,
  " symbols only libssl's ",
  c.objects,
  " objects define is in it; it holds ",
  c.libcrypto,
  " of libcrypto's"
