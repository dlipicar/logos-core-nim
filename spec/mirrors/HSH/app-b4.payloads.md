| Name | Payload | Digest, hexadecimal |
|------|---------|---------------------|
| `e` | `P("bstr-direct", L, S("logos.error_detail"), {3: 1, 4: h'00'})` | `866b00f6b2fa598cba282173e8cbb091b42f0f9fa2a986f031901ac4a3d67654` |
| `r` | `P("reference-value", B, S("types.record", "detail"), {3: L, 4: S("logos.error_detail"), 5: R(e)})` | `4cbbdabd1225ee32d73b7cd1d98ff95f0229494b4c942152eaf1ae7c6b4402c6` |
| `d` | `P("field", B, S("types.record", "detail"), {3: "detail", 4: R(r)})` | `c8f9628164ee88bd6b835aa6c834643d292e79299085c9b763616286bd8f6ade` |
| `n` | `P("scalar", B, S("types.count"), {3: "uint64", 4: 5})` | `dd70050599e53badc184347edb91c185d231180028273f1e81adff3e0bbe84ba` |
| `v` | `P("field", B, S("types.record", "value"), {3: "value", 4: R(n)})` | `bdddd74eaadcde4c8046879f9bd7cdf5bafd535300ccb6b9beb7a89775f7ee22` |
| `b` | `P("map", B, S("types.record"), {3: 2, 4: [F("detail", d), F("value", v)]})` | `fdabde59238e10c0fc1dfb965e4459ece9aaf298c1b9f5d17da3adf096f14ff4` |
| `b0` | `P("value-root", B, S("types.alias"), {3: R(b)})` | `9337bfbdfa1d8bb0bc8fcf58a1ff2db1dad4a920a0e146d45b77090eb5f0ebe2` |
| `ar` | `P("reference-value", A, S("a.import"), {3: B, 4: S("types.alias"), 5: R(b)})` | `9ecbd8b41e7f406f48894c4ccb573ea041845f8af61703d4535ec8d35476f6ea` |
| `af` | `P("field", A, S("a.value", "amount"), {3: "amount", 4: R(ar)})` | `2dd1504f6b9b0ef9a3ee58e16372e773ad63f088577f9a53a9421d4342d66ede` |
| `az` | `P("scalar", A, S("a.value", "z"), {3: "uint64", 4: 7})` | `591a4fa4aaae426c7a3388468de1a20bc51946f77cb4c3ca63a4f866b3086d86` |
| `aq` | `P("field", A, S("a.value", "z"), {3: "z", 4: R(az)})` | `211be949b703f72e93faf563b8f1bc2eb203b30354ff3bd0d703ddb649bb30e7` |
| `am` | `P("map", A, S("a.value"), {3: 2, 4: [F("amount", af), F("z", aq)]})` | `ea4239c2b05070b397a8158c4c8fbc1547a5060e63391cc02e0155fdc7537800` |
| `a0` | `P("value-root", A, S("a.value"), {3: R(am)})` | `9257722a3eb401a86000ff65371d751636d1f6e6a0771a1c5e4786d98d56147e` |
| `cr` | `P("reference-value", C, S("c.value", "amount"), {3: B, 4: S("types.alias"), 5: R(b)})` | `96a19fd543b430c941f684f88864927c93d11cd640a6396caa236ee3d9ebab75` |
| `cf` | `P("field", C, S("c.value", "amount"), {3: "amount", 4: R(cr)})` | `e0f45fa6cf6dacfa5e6d2bcfd981b62b823bc25cebf0f12288c382a8855b3d14` |
| `cz` | `P("scalar", C, S("c.value", "z"), {3: "uint64", 4: 7})` | `62a370e9d9d8ca45d8f8defc781e1ecd39510e5fc78d2f98803ac7972d411330` |
| `cq` | `P("field", C, S("c.value", "z"), {3: "z", 4: R(cz)})` | `f3f369b1d4f4e5a4e3b43195b1f3d2295ee5af2859109e156f49a972e5d9d632` |
| `cm` | `P("map", C, S("c.value"), {3: 2, 4: [F("amount", cf), F("z", cq)]})` | `3e77b5b8666bdfd08bc1d78cd4171c6c007bfd70caa195a3da903122e92ea0ec` |
| `c0` | `P("value-root", C, S("c.value"), {3: R(cm)})` | `58bf0541f221388df4e0f27b4af618859b44e9d142fc80ebf5d189fbec7a1982` |
