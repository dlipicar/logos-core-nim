## INTERFACE §3: why the reverse mapper rejects a header set.
##
## [IMPL] Each reason names one condition the specification requires the reverse
## mapper to reject (IF §3.1-§3.7, §3.9.5). The diagnostic text is
## implementation-defined (IF l.2942); the reason is what tests assert.

{.push raises: [].}

type
  RejectReason* = enum
    # The input set and its includes [SPEC INTERFACE §3.2 l.2288-2298]
    rkLogicalName = "logical-name" ## a malformed logical name
    rkDuplicateName = "duplicate-logical-name"
    rkIncludeForm = "include-form" ## not a literal quoted or allowed angle include
    rkIncludeName = "include-name" ## empty, absolute, empty component, backslash
    rkIncludeAboveRoot = "include-above-root"
    rkIncludeMissing = "include-missing" ## no supplied header has that name
    rkIncludeCycle = "include-cycle" ## [IMPL-DECISION G317]
    # The source text [SPEC INTERFACE §3.5 l.2564, §3.9.6]
    rkSourceEncoding = "source-encoding" ## not UTF-8, NUL, trigraph, stray byte
    rkLexical = "lexical" ## no C token, an unterminated literal or comment
    # The allowed subset [SPEC INTERFACE §3.1]
    rkOutsideSubset = "outside-subset"
    rkConditional = "conditional" ## a declaration under a condition other than a guard
    rkStandardMacro = "standard-macro-redefined" ## [SPEC INTERFACE §3.5 l.2569]
    rkRevisionCheck = "revision-check" ## [SPEC INTERFACE §2 l.664]
    rkContextCheck = "context-check" ## [SPEC INTERFACE §2 l.678]
    rkIdentity = "identity" ## [SPEC INTERFACE §3.2 l.2306-2311]
    # Literals [SPEC INTERFACE §3.5 l.2533-2569]
    rkLiteralForm = "literal-form" ## outside the §3.5 forms
    rkLiteralRange = "literal-range" ## a value or macro argument out of range
    rkLiteralText = "literal-text" ## a bad escape, invalid UTF-8, embedded NUL
    rkLiteralKind = "literal-kind" ## the wrong scalar kind for its node
    rkLiteralMissing = "literal-missing"
    # Names and paths [SPEC INTERFACE §2.1 l.786-829, §3.5 l.2520-2531]
    rkName = "name" ## an identifier that does not decode to a namespace or module
    rkPath = "path" ## an inline stem reached by no path, or a type at the wrong path
    rkEscape = "escape" ## an unescaped keyword member or an unnecessary escape
    rkFixedType = "fixed-type-redeclared" ## [SPEC INTERFACE §3.2 l.2335]
    # Groups, roles and binding [SPEC INTERFACE §3.2 l.2373-2387, §3.7]
    rkSelection = "selection" ## no single subject or module to reconstruct
    rkIncompleteGroup = "incomplete-group" ## l.2375
    rkConflictingDefinition = "conflicting-definition" ## l.2376
    rkConflictingGroup = "conflicting-group" ## l.2303
    rkHalfMissing = "method-half-missing" ## l.2377
    rkRoleConstant = "role-constant" ## l.2378: missing or conflicting
    rkRoleMismatch = "role-mismatch" ## l.2379
    rkModuleName = "module-name" ## l.2380: inconsistent runtime module names
    rkImplements = "implements" ## l.2381: no complete matching interface group
    rkDuplicateImplements = "duplicate-implements" ## l.2382
    rkMissingImplements = "missing-implements" ## l.2383
    rkSupportingCallable = "supporting-callable" ## l.2384
    rkUnreferencedDependency = "unreferenced-dependency" ## l.2385
    rkImplementsIndex = "implements-index" ## l.2386, l.2358
    rkCollision = "collision" ## l.2387
    rkSensitive = "sensitive" ## l.2365-2367
    rkLifecycle = "lifecycle" ## [IMPL-DECISION G322] §3.7, §2.6
    # Declarations [SPEC INTERFACE §3.3-§3.6]
    rkFunction = "function" ## not the `_FN_t` or `_CALL_` pattern
    rkProviderMismatch = "provider-mismatch" ## a provider function unlike its typedef
    rkParamOrder = "parameter-order" ## an input after an output, no direction prefix
    rkWrapper = "choice-wrapper" ## l.2420-2433: the wrapper missing, renamed or mixed
    rkPresence = "presence" ## a `has_` member that is not the exact adjacent flag
    rkMember = "member" ## an unmatched length, count, output or reserved member
    rkFieldOrder = "field-order" ## members not in canonical field order
    rkAggregate = "aggregate" ## an aggregate tag's members, `_empty`, an empty struct
    rkChoice = "choice" ## form, discriminant, constants, union members, storage
    rkEvent = "event" ## l.2575-2577
    rkRecursiveEmbedded = "recursive-embedded" ## l.2393
    rkRecursivePointer = "recursive-pointer" ## l.2393
    # The result [SPEC INTERFACE §3.8; IMPL-DECISION G319]
    rkSchema = "schema" ## the reconstructed document is not a valid Logos schema
    rkRestatedFact = "restated-fact" ## l.636: metadata that `H'` does not have
    rkNotCanonical = "not-canonical" ## any other difference from `H'`
    rkDeclareOrder = "declare-before-use" ## [IMPL-DECISION G319] l.891
    # Tooling limits [SPEC INTERFACE §2.1 l.881-882]
    rkLimit = "limit"

  Rejection* = object
    reason*: RejectReason
    header*: string ## the logical name, "" when the whole set is at fault
    line*: int ## 1-based, 0 when not tied to a line
    detail*: string

func reject*(
    reason: RejectReason, header: string, line: int, detail: string
): Rejection =
  Rejection(reason: reason, header: header, line: line, detail: detail)

func `$`*(r: Rejection): string =
  var s = "[" & $r.reason & "] "
  if r.header.len > 0:
    s.add(r.header)
    if r.line > 0:
      s.add(":" & $r.line)
    s.add(": ")
  s & r.detail
