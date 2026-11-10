## INTERFACE §1.3-§1.5, §2.1 and RUNTIME §1.3: the naming rules of Logos schemas.
##
## Pure checks on names, with no dependency on the schema model: identifier
## grammar, reserved names, field-name reservations, length limits, runtime
## module names and the C namespace projection.

{.push raises: [].}

import std/strutils
import results

export results

const
  MaxNamespaceBytes* = 128 ## [SPEC INTERFACE §1.3]
  MaxMethodNameBytes* = 128 ## [SPEC INTERFACE §1.4] the bare method name
  MaxEventIdBytes* = 128 ## [SPEC INTERFACE §1.5] the complete event identifier
  MaxModuleNameBytes* = 64 ## [SPEC RUNTIME §1.3]

  C17Keywords* = [
    # [SPEC INTERFACE §1.3] the C17 keywords that otherwise satisfy the field-name
    # grammar
    "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
    "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
    "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
    "switch", "typedef", "union", "unsigned", "void", "volatile", "while",
  ]
  StdboolNames* = ["bool", "true", "false"]
    ## [SPEC INTERFACE §1.3] `<stdbool.h>` macros

  ReservedNamePrefixes* = ["logos.", "logos-", "logos_"]
    ## [SPEC INTERFACE §1.3] CDDL names reserved for Logos-defined surfaces.
  CallableSuffixes* = ["_request", "_response", "_event"]
    ## [SPEC INTERFACE §1.3] reserved for callable declarations.
  ReservedNamespaces* = ["call", "publish"]
    ## [IMPL-DECISION G69] namespaces whose C projection would collide with the
    ## `_call_` and `_publish_` symbol separators.

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
  ## [IMPL-DECISION G69] Not `call` or `publish`.
  ?checkQualifiedName(ns)
  if ns.len > MaxNamespaceBytes:
    return err("namespace " & ns & " is longer than 128 bytes")
  if ns in ReservedNamespaces:
    return err("namespace " & ns & " is reserved (G69)")
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
  ## not `…_len`, `…_count` or `…_<digits>`, not a C17 keyword or a
  ## `<stdbool.h>` name.
  if not name.isSchemaIdentifier:
    return err("field " & name & " is not a lowercase snake_case identifier")
  if name.startsWith("has_"):
    return err("field " & name & " begins with has_")
  if name.endsWith("_len") or name.endsWith("_count") or name.endsInDigitsSuffix:
    return err("field " & name & " ends with a reserved suffix")
  if name in C17Keywords:
    return err("field " & name & " is a C17 keyword")
  if name in StdboolNames:
    return err("field " & name & " is a <stdbool.h> name")
  ok()

func checkModuleName*(name: string, system = false): Result[void, string] =
  ## [SPEC RUNTIME §1.3] `[a-z][a-z0-9_]*`, at most 64 bytes, without `_call_`
  ## or `_publish_`. [SPEC INTERFACE §1.3] `logos_…` is reserved for
  ## Logos-defined runtime and system modules (`system`). [IMPL-DECISION G69]
  ## Not ending in `_call` or `_publish` either.
  if name.len == 0 or not name[0].isLower:
    return err("module name \"" & name & "\" does not begin with a lowercase letter")
  for c in name:
    if not (c.isLower or c in '0' .. '9' or c == '_'):
      return err("module name " & name & " has a character outside [a-z0-9_]")
  if name.len > MaxModuleNameBytes:
    return err("module name " & name & " is longer than 64 bytes")
  if "_call_" in name or "_publish_" in name:
    return err("module name " & name & " contains _call_ or _publish_")
  if name.endsWith("_call") or name.endsWith("_publish"):
    return err("module name " & name & " ends in _call or _publish (G69)")
  if name.startsWith("logos_") and not system:
    return err("module name " & name & " is reserved for Logos system modules")
  ok()

func isSimpleNamespace*(ns: string): bool =
  ## [SPEC INTERFACE §2.1] One segment: a lowercase letter, then lowercase
  ## letters or digits, no underscore.
  ns.len > 0 and ns[0].isLower and ns.allCharsInSet({'a' .. 'z', '0' .. '9'})

func projectNamespace*(ns: string): string =
  ## [SPEC INTERFACE §2.1] The C namespace component: each dot becomes one
  ## underscore.
  ns.replace('.', '_')

func localName*(qualified, ns: string): string =
  ## The name below the namespace (`ns.x` -> `x`).
  qualified[ns.len + 1 .. ^1]

func bareMethodName*(base, ns: string): string =
  ## [SPEC INTERFACE §1.4] The method name without its namespace.
  localName(base, ns)
