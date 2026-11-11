## INTERFACE §1.3-§1.5, §2.1 and RUNTIME §1.3: the naming rules of Logos schemas
## and their C projections.
##
## Pure checks on names, with no dependency on the schema model: identifier
## grammar, reserved names, field-name reservations, length limits, runtime
## module names, and the C namespace, module-name and capitalization projections
## with the C keyword escape.

{.push raises: [].}

import std/strutils
import results

export results

const
  MaxNamespaceBytes* = 128 ## [SPEC INTERFACE §1.3]
  MaxMethodNameBytes* = 128 ## [SPEC INTERFACE §1.4] the bare method name
  MaxEventIdBytes* = 128 ## [SPEC INTERFACE §1.5] the complete event identifier
  MaxModuleNameBytes* = 64 ## [SPEC RUNTIME §1.3]

  CEscapedIdentifiers* = [
    # [SPEC INTERFACE §2.1] the fixed set of identifier spellings that take a
    # trailing underscore (C and C++ keywords and their alternative tokens);
    # tests compare it with spec/mirrors/IFC/2.1.keywords.txt
    "alignas", "alignof", "and", "and_eq", "asm", "auto", "bitand", "bitor", "bool",
    "break", "case", "catch", "char", "char16_t", "char32_t", "char8_t", "class",
    "co_await", "co_return", "co_yield", "compl", "concept", "const", "const_cast",
    "consteval", "constexpr", "constinit", "continue", "decltype", "default", "delete",
    "do", "double", "dynamic_cast", "else", "enum", "explicit", "export", "extern",
    "false", "float", "for", "friend", "goto", "if", "inline", "int", "long", "mutable",
    "namespace", "new", "noexcept", "not", "not_eq", "nullptr", "operator", "or",
    "or_eq", "private", "protected", "public", "register", "reinterpret_cast",
    "requires", "restrict", "return", "short", "signed", "sizeof", "static",
    "static_assert", "static_cast", "struct", "switch", "template", "this",
    "thread_local", "throw", "true", "try", "typedef", "typeid", "typename", "typeof",
    "typeof_unqual", "union", "unsigned", "using", "virtual", "void", "volatile",
    "wchar_t", "while", "xor", "xor_eq",
  ]

  ReservedNamePrefixes* = ["logos.", "logos-", "logos_"]
    ## [SPEC INTERFACE §1.3] CDDL names reserved for Logos-defined surfaces.
  CallableSuffixes* = ["_request", "_response", "_event"]
    ## [SPEC INTERFACE §1.3] reserved for callable declarations.

func isLower(c: char): bool =
  c in 'a' .. 'z'

func isSchemaIdentifier*(s: string): bool =
  ## [SPEC INTERFACE §1.3] Lowercase ASCII letters, digits and underscores;
  ## begins with a letter, ends with a letter or digit, no consecutive
  ## underscores.
  if s.len == 0 or not s[0].isLower or s[^1] == '_':
    return false
  for i, c in s:
    if not (c.isLower or c in '0' .. '9' or c == '_'):
      return false
    if c == '_' and i > 0 and s[i - 1] == '_':
      return false
  true

func checkQualifiedName*(name: string): Result[void, string] =
  ## [SPEC INTERFACE §1.3] Every dot-separated segment is a schema identifier.
  for seg in name.split('.'):
    if not seg.isSchemaIdentifier:
      return err(
        name & ": segment \"" & seg &
          "\" is not a lowercase snake_case identifier (INTERFACE §1.3)"
      )
  ok()

func checkNamespace*(ns: string): Result[void, string] =
  ## [SPEC INTERFACE §1.3] Identifier segments, at most 128 bytes in all.
  ?checkQualifiedName(ns)
  if ns.len > MaxNamespaceBytes:
    return err("namespace " & ns & " is longer than 128 bytes")
  ok()

func isReservedName*(name: string): bool =
  ## [SPEC INTERFACE §1.3] Begins with `logos.`, `logos-` or `logos_`.
  for p in ReservedNamePrefixes:
    if name.startsWith(p):
      return true
  false

func hasCallableSuffix*(name: string): bool =
  for s in CallableSuffixes:
    if name.endsWith(s):
      return true
  false

func endsInDigitsSuffix(name: string): bool =
  ## `_` followed by one or more decimal digits at the end.
  var i = name.high
  while i >= 0 and name[i] in '0' .. '9':
    dec i
  i < name.high and i >= 0 and name[i] == '_'

func checkFieldName*(name: string): Result[void, string] =
  ## [SPEC INTERFACE §1.3] A map field name: a schema identifier, not `has_…`,
  ## not `…_len`, `…_count` or `…_<digits>`. It may equal a C or C++ keyword:
  ## the C mapping escapes the members derived from it (`escapeC`).
  if not name.isSchemaIdentifier:
    return err("field " & name & " is not a lowercase snake_case identifier")
  if name.startsWith("has_"):
    return err("field " & name & " begins with has_")
  if name.endsWith("_len") or name.endsWith("_count") or name.endsInDigitsSuffix:
    return err("field " & name & " ends with a reserved suffix")
  ok()

func checkModuleName*(name: string, system = false): Result[void, string] =
  ## [SPEC RUNTIME §1.3] `[a-z][a-z0-9_]*`, at most 64 bytes, without `_call_`
  ## or `_publish_`. [SPEC INTERFACE §1.3] `logos_…` is reserved for
  ## Logos-defined runtime and system modules (`system`).
  if name.len == 0 or not name[0].isLower:
    return err("module name \"" & name & "\" does not begin with a lowercase letter")
  for c in name:
    if not (c.isLower or c in '0' .. '9' or c == '_'):
      return err("module name " & name & " has a character outside [a-z0-9_]")
  if name.len > MaxModuleNameBytes:
    return err("module name " & name & " is longer than 64 bytes")
  if "_call_" in name or "_publish_" in name:
    return err("module name " & name & " contains _call_ or _publish_")
  if name.startsWith("logos_") and not system:
    return err("module name " & name & " is reserved for Logos system modules")
  ok()

# C projections ---------------------------------------------------------------------

func projectNamespace*(ns: string): string =
  ## [SPEC INTERFACE §2.1] The C namespace component: each dot becomes `_NS_`;
  ## underscores and every segment are kept.
  ns.replace(".", "_NS_")

func projectModule*(name: string): string =
  ## [SPEC INTERFACE §2.1] The `<module-C>` component of a runtime module name:
  ## an underscore followed by another underscore or ending the name becomes
  ## `_U`; every other character is kept (`a__b` -> `a_U_b`, `a_` -> `a_U`).
  var s = ""
  for i, c in name:
    if c == '_' and (i == name.high or name[i + 1] == '_'):
      s.add("_U")
    else:
      s.add(c)
  s

func decodeNamespace*(component: string): Result[string, string] =
  ## [SPEC INTERFACE §2.1] The reverse namespace projection: each `_NS_` back to a
  ## dot; the result must be a valid namespace whose projection is `component`.
  let ns = component.replace("_NS_", ".")
  ?checkNamespace(ns)
  if projectNamespace(ns) != component:
    return err(component & " is not a canonical C namespace component")
  ok(ns)

func decodeModule*(component: string): Result[string, string] =
  ## [SPEC INTERFACE §2.1] The reverse module-name projection: each `_U` back to
  ## one underscore; the result must be a valid runtime module name whose
  ## projection is `component` (`a_Ub` is not canonical).
  let name = component.replace("_U", "_")
  ?checkModuleName(name, system = true)
  if projectModule(name) != component:
    return err(component & " is not a canonical module-name component")
  ok(name)

func capitalize*(atom: string): string =
  ## [SPEC INTERFACE §2.1] The first ASCII letter uppercased, the rest kept.
  if atom.len == 0:
    atom
  else:
    atom[0].toUpperAscii & atom[1 .. ^1]

func escapeC*(identifier: string): string =
  ## [SPEC INTERFACE §2.1] A complete schema-derived C identifier, with one
  ## trailing underscore when it is in the fixed escape set. The same in every
  ## language mode.
  if identifier in CEscapedIdentifiers:
    identifier & "_"
  else:
    identifier

func localName*(qualified, ns: string): string =
  ## The name below the namespace (`ns.x` -> `x`).
  qualified[ns.len + 1 .. ^1]

func bareMethodName*(base, ns: string): string =
  ## [SPEC INTERFACE §1.4] The method name without its namespace.
  localName(base, ns)
