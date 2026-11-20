# The re-pin's citation pass, step 2 of 2 (re-pin P9; procedure in docs/SPEC-STATUS.md "When a spec revision
# lands"). Kept as it ran, plus the `bucket` column and --write, which rewrites only the `shift` bucket. Every
# other citation is read by hand. No self-test and no gate: a hand tool.
"""Second pass over cites.py's TSV: decide by text which revision a citation means.
triage.py <scratch> <repo> <in.tsv> <out.tsv> [--write]
<scratch> holds spec-old/ and spec-new/, each a logos-lips checkout with docs/logos-core/raw.
bucket: shift   presumed old by blame, mapped with its length kept (cites.py `shift`), text not against: rewrite
        same    the cited lines read the same in both revisions: nothing to do
        current presumed new by blame and by text: nothing to do
        hand    everything else: no spec, changed or widened old lines, text and blame disagree, or text decides
                nothing on a line the re-pin edited
--write rewrites each `shift` citation in place, at its column, after checking the text there."""
import csv, re, sys, difflib
from pathlib import Path
S, R, inp, outp = sys.argv[1:5]
write = "--write" in sys.argv[5:]

FILES = {"RUNTIME":"spec-module-runtime.md","R":"spec-module-runtime.md","INTERFACE":"spec-module-interface.md","IF":"spec-module-interface.md","TRANSPORT":"spec-module-transport.md","T":"spec-module-transport.md","CA":"spec-module-capability-authority.md","AUTHORITY":"spec-module-capability-authority.md","PM":"spec-module-package-manager.md","MANAGER":"spec-module-package-manager.md","LOADER":"spec-module-loader.md","L":"spec-module-loader.md","CONFIG":"spec-module-configuration.md","CFG":"spec-module-configuration.md","CONFIGURATION":"spec-module-configuration.md","BCP":"spec-module-system-bcp.md","BOOTSTRAP-COMPOSITION-PROFILES":"spec-module-system-bcp.md","SECURITY":"spec-module-security-considerations.md","SEC":"spec-module-security-considerations.md","SECURITY-CONSIDERATIONS":"spec-module-security-considerations.md","COMMITMENT":"spec-module-commitment-model.md","CMT":"spec-module-commitment-model.md","HASH":"spec-module-hash-profile.md","HSH":"spec-module-hash-profile.md","cdCDDLe":"spec-cdcddle.md","CDE":"spec-cdcddle.md","CS":"spec-module-credential-store.md"}
cache={}
def lines(rev, name):
    k=(rev,name)
    if k not in cache:
        try: cache[k]=open(f"{S}/spec-{rev}/docs/logos-core/raw/{name}",encoding="utf-8").read().splitlines()
        except FileNotFoundError: cache[k]=None
    return cache[k]
maps={}
def lmap(name):
    if name not in maps:
        o,n=lines("old",name),lines("new",name); m={}
        if o and n:
            for t,i1,i2,j1,j2 in difflib.SequenceMatcher(None,o,n,autojunk=False).get_opcodes():
                if t=="equal":
                    for k in range(i2-i1): m[i1+k+1]=j1+k+1
        maps[name]=m
    return maps[name]
STOP=set("must that this with from when which their there each have been does into they them only also than then such other shall should more what where while under over after before none same these those used uses once like will would could being same both every either neither".split())
def toks(s): return {w for w in re.findall(r"[a-z_][a-z_-]{3,}", s.lower()) if w not in STOP}
docs={}
rows=list(csv.DictReader(open(inp),delimiter="\t"))
out=[]
for r in rows:
    f=r["file"]
    if f not in docs: docs[f]=open(f"{R}/{f}",encoding="utf-8").read().splitlines()
    d=docs[f]; i=int(r["line"])-1
    ctx=toks(" ".join(d[max(0,i-1):i+2]))
    verdict, mapped = r["status"], r["mapped"]
    if r["spec"]!="?":
        name=FILES[r["spec"]]; o,n=lines("old",name),lines("new",name)
        m=re.match(r"l\.(\d+)(?:-(\d+))?", r["cited"]); a=int(m.group(1)); b=int(m.group(2) or a)
        def txt(L): 
            if L is None or b>len(L): return None
            return " ".join(L[a-1:b])
        to, tn = txt(o), txt(n)
        def score(t):
            if not t or not t.strip(): return 0.0
            ct=toks(t); return len(ct&ctx)/max(1,len(ct))
        so, sn = score(to), score(tn)
        mm=lmap(name); mp=[mm.get(k) for k in range(a,b+1)]
        mapped_rng = None if (o is None or any(x is None for x in mp)) else (f"l.{mp[0]}" if mp[0]==mp[-1] else f"l.{mp[0]}-{mp[-1]}")
        if to is not None and to==tn:
            verdict = "same" if mapped_rng==r["cited"] or mapped_rng is None else "same-text-moved"
        elif so>=sn+0.15 and so>0:
            verdict = "old-shift" if mapped_rng else "old-changed"
            mapped = mapped_rng or ""
        elif sn>=so+0.15 and sn>0:
            verdict = "new"
        else:
            verdict = "ambiguous"
        r["so"]=f"{so:.2f}"; r["sn"]=f"{sn:.2f}"
    else:
        r["so"]=r["sn"]=""; verdict="unknown"
    r["triage"]=verdict; r["mapped2"]=mapped
    if verdict == "same":
        r["bucket"] = "same"
    elif r["presumed"] == "new":
        r["bucket"] = "current" if verdict == "new" and r["status"] == "current" else "hand"
    else:
        r["bucket"] = "shift" if r["status"] == "shift" and verdict in ("old-shift", "ambiguous") else "hand"
    out.append(r)
with open(outp,"w") as fh:
    w=csv.DictWriter(fh,fieldnames=list(out[0].keys()),delimiter="\t"); w.writeheader(); w.writerows(out)
from collections import Counter
for f in sorted({r["file"] for r in out}):
    c=Counter(r["triage"] for r in out if r["file"]==f)
    print(f, sum(c.values()), dict(sorted(c.items())))
print("cross (blame presumed x triage):", Counter((r["presumed"],r["triage"]) for r in out if r["file"]!="docs/DECISIONS.md"))
for f in sorted({r["file"] for r in out}):
    c=Counter(r["bucket"] for r in out if r["file"]==f)
    print("bucket", f, dict(sorted(c.items())))
if write:
    CITE = re.compile(r"l\.(\d+)(?:([–-])(\d+))?")
    def ends(s):
        m = re.fullmatch(r"l\.(\d+)(?:-(\d+))?", s); return int(m.group(1)), int(m.group(2) or m.group(1))
    for f in sorted({r["file"] for r in out if r["bucket"] == "shift"}):
        path = Path(R) / f
        text = path.read_text(encoding="utf-8").split("\n")
        rs = sorted((r for r in out if r["file"] == f and r["bucket"] == "shift"), key=lambda r: (int(r["line"]), -int(r["col"])))
        for r in rs:
            i, c = int(r["line"]) - 1, int(r["col"])
            m = CITE.match(text[i], c)
            if not m or (int(m.group(1)), int(m.group(3) or m.group(1))) != ends(r["cited"]):
                sys.exit(f"{f}:{i + 1}: {r['cited']} is not at column {c}; re-run cites.py")
            na, nb = ends(r["mapped"])
            text[i] = text[i][: m.start()] + (f"l.{na}" if na == nb else f"l.{na}{m.group(2) or '-'}{nb}") + text[i][m.end() :]
        path.write_text("\n".join(text), encoding="utf-8")
        print(f"wrote {f}: {len(rs)} citations")
