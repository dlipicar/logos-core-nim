# The re-pin's duty sweep (re-pin P9; procedure in docs/SPEC-STATUS.md "When a spec revision lands"): every
# line of the new revision that is new or changed and asks for documentation, for the deployment document's duty
# table (docs/DEPLOYMENT.md, DECISIONS G309). Kept as it ran. No self-test and no gate: a hand tool.
# sweep.py <old raw dir> <new raw dir>  prints file, line and text of each such line
import difflib,re,sys
from pathlib import Path
old,new=Path(sys.argv[1]),Path(sys.argv[2])
PH=re.compile(r"MUST document|MUST be documented|documentation MUST|MUST identify|MUST state|MUST describe|documented",re.I)
for f in sorted(new.glob('spec-*.md')):
    n=f.read_text().splitlines(); o=(old/f.name).read_text().splitlines() if (old/f.name).exists() else []
    eq=set()
    for t,i1,i2,j1,j2 in difflib.SequenceMatcher(None,o,n,autojunk=False).get_opcodes():
        if t=='equal': eq.update(range(j1+1,j2+1))
    for k,l in enumerate(n,1):
        if PH.search(l) and k not in eq:
            print(f"{f.name}\t{k}\t{l[:230]}")
