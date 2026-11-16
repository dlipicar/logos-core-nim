# Windows AF_UNIX probes (step 5-4, G107)

What TRANSPORT §8.2.1 (T l.1148-1172) makes Windows support depend on, measured. These are `[IMPL]`
tools, not tests: nothing here is part of `nimble test`, and nothing here builds on POSIX.

| File | Measures |
|---|---|
| `winprobe.c` | Q1-Q10, Q12-Q15 of the step 5-4 plan: AF_UNIX basics and paths, peer-query attribution, listener transfer and handle hygiene, the held process reference, DACLs, the reparse-tag check, ancestors, the G108 carrier, Job Objects, the build |
| `loopprobe.nim`, `loopprobe.c` | Q11: four ways to drive AF_UNIX sockets from chronos 4.4.1's Windows dispatcher without a fork |
| `facts/<build>-<machine>-<probe>.txt` | The raw output per qualified build. G333 points here: unix-stream is offered on Windows only on a build with committed facts |

## Running

On Windows, with the MinGW-w64 gcc and Nim 2.2.14:

```bat
gcc -O1 -Wall -o winprobe.exe tools\winprobe\winprobe.c -lws2_32 -ladvapi32 -lversion
winprobe.exe > winprobe-facts.txt
nim c -d:release --path:<chronos> --path:<results> --path:<stew> tools\winprobe\loopprobe.nim
tools\winprobe\loopprobe.exe <short scratch dir> > loopprobe-facts.txt
```

- **Rights.** `winprobe` needs no administrator rights and changes no system setting.
- **Two columns.** Run elevated, it runs every question as it is (`elevated`), then again under a filtered
  token (`standard`).
- **Output.** Each line is `fact <run>:<question>.<name> <value>`, so two builds diff line by line.
- **Before committing.** Replace the machine part of the user SID and the user name (`<machine>`,
  `<user>`), since the repository is public.

Do not import user32.dll into `winprobe.c`. A restricted child that imports it does not start under an ssh
logon (0xc0000142).
