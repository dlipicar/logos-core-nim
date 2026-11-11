| Typed path | Disclosed value | Proof payloads, in order |
|------------|-----------------|--------------------------|
| `[{0: "field", 1: "amount"}, {0: "field", 1: "value"}]` | `uint64` value `5`, payload `n` | `v, b, ar, af, am, a0` |
| `[{0: "field", 1: "amount"}, {0: "field", 1: "detail"}]` | Reference value containing `bstr` value `h'00'`, subtree `r` | `d, b, ar, af, am, a0` |
| `[{0: "field", 1: "amount"}, {0: "field", 1: "detail"}, {0: "bstr-range", 1: 0, 2: 1}]` | Byte range `h'00'` | `e, r, d, b, ar, af, am, a0` |
| `[{0: "field", 1: "z"}]` | `uint64` value `7`, payload `az` | `aq, am, a0` |
