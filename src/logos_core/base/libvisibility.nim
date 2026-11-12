## A Nim shared library exports only what it marks `dynlib` [IMPL].
##
## Importing this module compiles every C file of the build with hidden
## visibility, so a library's dynamic symbol table holds its `exportc, dynlib`
## procedures, its `NimMain` and `NimDestroyGlobals`, the sanitizer hooks of a
## sanitizer build, and BLAKE3's functions, whose C and assembly mark
## themselves for export (they keep no state, so a library that binds to
## another's copy computes the same). Nim emits some of its own globals
## with default visibility (DECISIONS I81, Linux fixes): under 2.2.14 the
## case-object discriminator tables (`NimDT_…`), which refc's channel copies
## read their type information from, and from 2.4 also the load-time
## constructor. On ELF systems a library mapped later binds its references to
## those names to the copies already in the global scope, so its start-up
## overwrites another library's tables. A host that links `liblogos_runtime` at
## load time, and a module library the Runtime maps afterwards, are such a pair.
## Hidden definitions are bound inside their own library when it is linked, so
## neither side can reach the other's.
##
## `liblogos_runtime` and the module kit's runtime (`codegen/kitrt`) import it.
## Executables export nothing by default, so for them it changes nothing.
## Windows exports only what a library marks for export anyway. Nim does not
## recompile a C file whose text is unchanged when only a C flag changes: a
## build cache from before this module keeps objects without the flag.

when not defined(windows):
  {.passc: "-fvisibility=hidden".}
