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
