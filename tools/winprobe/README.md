# Windows AF_UNIX probes (step 5-4, G107)

What TRANSPORT §8.2.1 (T l.1148-1172) makes Windows support depend on, measured. These are `[IMPL]`
tools, not tests: nothing here is part of `nimble test`, and nothing here builds on POSIX.

| File | Measures |
|---|---|
| `winprobe.c` | Q1-Q10, Q12-Q15 of the step 5-4 plan: AF_UNIX basics and paths, peer-query attribution, listener transfer and handle hygiene, the held process reference, DACLs, the reparse-tag check, ancestors, the G108 carrier, Job Objects, the build |
| `loopprobe.nim`, `loopprobe.c` | Q11: four ways to drive AF_UNIX sockets from chronos 4.4.1's Windows dispatcher without a fork |
| `facts/<build>.<ubr>-<machine>-<probe>.txt` | The raw output per measured build: the evidence TRANSPORT l.1170 asks for before support is claimed on a build. How builds qualify is not decided yet (the step 5-4 report's G333, with the owner) |

## Running

The CI leg's `probe` step builds and runs both, writes `build\winprobe\facts\<build>.<ubr>-<machine>-<probe>.txt`
(the SID and user name already replaced) and compares each with the committed file for the same OS build,
ignoring pids, handle values, timings and the scratch path (DECISIONS G334). By hand, from a checkout:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\windows.ps1 toolchain -ToolDir <dir>
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\windows.ps1 setup -ToolDir <dir>
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\windows.ps1 probe -ToolDir <dir> -Machine <name>
```

Or directly, with the MinGW-w64 gcc and Nim 2.2.14:

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
