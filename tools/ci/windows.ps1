# The Windows leg's steps (A6, G334), one script so that `.github/workflows/ci.yml`, a Windows
# machine by hand and the repositories split from this one later run the same commands. It runs
# under Windows PowerShell 5.1 and PowerShell 7 alike (the runner's `shell: pwsh`).
#
#   windows.ps1 toolchain [-ToolDir D]   pinned Nim and MinGW-w64 into D, hashes checked, on PATH
#   windows.ps1 setup                    Nimble's package list, then `nimble setup -l`
#   windows.ps1 test                     `nimble test`, sharded by LCN_SHARD as on Linux and macOS
#   windows.ps1 probe [-OutDir O]        tools/winprobe on this build, compared with the committed facts
#
# Every step after `toolchain` puts D's tools first on PATH itself, so each step also runs alone.
# Nothing is installed system-wide: D and the repository's build/ and nimbledeps/ are all it writes.
# Under GitHub Actions, `toolchain` also appends D's tools to GITHUB_PATH, and `probe` writes to the
# job summary. nasm is not fetched: nothing on Windows compiles assembly (5-2 builds BoringSSL
# without it there for now, I45, I68).

param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('toolchain', 'setup', 'test', 'probe')]
  [string]$Step,
  [string]$ToolDir = '',
  [string]$OutDir = 'build\winprobe',
  [string]$Machine = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# The pins. The sums are the ones nim-lang.org publishes beside each file (`<file>.sha256`).
# mingw64.7z is the gcc 11.1.0 (MinGW-w64 x86_64-posix-seh) that choosenim installs.
$NimVersion = '2.2.14'
$Archives = @(
  @{
    Name = "nim-$NimVersion`_x64.zip"
    Url = "https://nim-lang.org/download/nim-$NimVersion`_x64.zip"
    Sha256 = '204f1272946acd3786a5abb4b91fc2f3e27355e8b148c4ea1ad05ac0cb5627c8'
    Dir = "nim-$NimVersion"
    Bin = "nim-$NimVersion\bin"
  },
  @{
    Name = 'mingw64.7z'
    Url = 'https://nim-lang.org/download/mingw64.7z'
    Sha256 = '04a535d1e0880364ca9609713744f1a9a36835c4ced834cf435c4dc4eca2159a'
    Dir = 'mingw64'
    Bin = 'mingw64\bin'
  }
)

$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ($ToolDir -eq '') {
  if ($env:RUNNER_TEMP) { $ToolDir = Join-Path $env:RUNNER_TEMP 'lcn-toolchain' }
  else { $ToolDir = Join-Path $Repo 'build\toolchain' }
}
$ToolDir = [IO.Path]::GetFullPath($ToolDir)

function Invoke-Native([string]$What, [scriptblock]$Block) {
  & $Block
  if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" }
}

function Test-Sha256([string]$Path, [string]$Want) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() -eq $Want
}

function Expand-Into([string]$Archive, [string]$Dest) {
  # 7-Zip where it exists (the runner has it), else the tar.exe that ships with Windows (libarchive),
  # never a tar earlier on PATH (Git's GNU tar reads neither format).
  $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
  if (-not $sevenZip -and (Test-Path 'C:\Program Files\7-Zip\7z.exe')) {
    $sevenZip = Get-Command 'C:\Program Files\7-Zip\7z.exe'
  }
  if ($sevenZip) {
    Invoke-Native "7z x $Archive" { & $sevenZip.Source x -y -bso0 -bsp0 "-o$Dest" $Archive }
  } else {
    Invoke-Native "tar -xf $Archive" { & "$env:SystemRoot\System32\tar.exe" -xf $Archive -C $Dest }
  }
}

function Use-Toolchain {
  foreach ($a in $Archives) {
    $bin = Join-Path $ToolDir $a.Bin
    if (-not (Test-Path $bin)) { throw "$bin is missing: run the toolchain step first" }
    if (-not (($env:PATH -split ';') -contains $bin)) { $env:PATH = "$bin;$env:PATH" }
  }
}

function Step-Toolchain {
  $store = Join-Path $ToolDir 'archives'
  New-Item -ItemType Directory -Force $store | Out-Null
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  foreach ($a in $Archives) {
    $file = Join-Path $store $a.Name
    # A cached or earlier copy is checked like a download, and fetched again if it does not match.
    if ((Test-Path $file) -and -not (Test-Sha256 $file $a.Sha256)) {
      Write-Host "$($a.Name): cached copy does not match its SHA-256; fetching again"
      Remove-Item -Force $file
    }
    if (-not (Test-Path $file)) {
      Write-Host "$($a.Name): downloading $($a.Url)"
      Invoke-WebRequest -UseBasicParsing -Uri $a.Url -OutFile $file
      if (-not (Test-Sha256 $file $a.Sha256)) {
        Remove-Item -Force $file
        throw "$($a.Name): SHA-256 does not match $($a.Sha256)"
      }
    }
    Write-Host "$($a.Name): SHA-256 $($a.Sha256) ok"
    $dir = Join-Path $ToolDir $a.Dir
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    Expand-Into $file $ToolDir
    if (-not (Test-Path (Join-Path $ToolDir $a.Bin))) { throw "$($a.Name) has no $($a.Bin)" }
  }
  Use-Toolchain
  if ($env:GITHUB_PATH) {
    # GITHUB_PATH entries are prepended in order of appearance, last first.
    for ($i = $Archives.Count - 1; $i -ge 0; $i--) {
      Add-Content -LiteralPath $env:GITHUB_PATH -Value (Join-Path $ToolDir $Archives[$i].Bin) -Encoding ascii
    }
  }
  Show-Toolchain
}

function Show-Toolchain {
  Invoke-Native 'nim -v' { nim -v }
  Invoke-Native 'nimble -v' { nimble -v }
  Invoke-Native 'gcc --version' { gcc --version }
  $gcc = (Get-Command gcc.exe).Source
  $want = Join-Path $ToolDir 'mingw64\bin\gcc.exe'
  if ($gcc -ne $want) { throw "gcc on PATH is $gcc, not $want" }
}

# [DECISIONS G436] Nimble never compares the compiler with `requires "nim == ..."`, and with
# --useSystemNim it takes the Nim on PATH, so each Nimble step checks that Nim against the one pin,
# logos_core.nimble's, before it runs. On Windows nothing else does: $NimVersion must equal that pin
# too (lint-packaging's nim-windows).
function Assert-NimPin {
  $pin = Select-String -Path (Join-Path $Repo 'logos_core.nimble') -Pattern '^requires "nim == ([0-9.]+)"' |
    Select-Object -First 1
  if (-not $pin) { throw 'logos_core.nimble has no exact nim requirement' }
  $want = $pin.Matches[0].Groups[1].Value
  $have = (& nim --version | Select-Object -First 1)
  if ($have -notmatch "^Nim Compiler Version $([regex]::Escape($want)) ") {
    throw "the Nim on PATH is '$have', not logos_core.nimble's $want"
  }
  Write-Host "Nim on PATH matches the pin: $have"
}

function Step-Setup {
  Use-Toolchain
  Set-Location $Repo
  Assert-NimPin
  # The package list is fetched here and handed to nimble, which then only resolves the lock file.
  # Local deps (`-l`) keep everything under nimbledeps\.
  New-Item -ItemType Directory -Force (Join-Path $Repo 'nimbledeps') | Out-Null
  $list = Join-Path $Repo 'nimbledeps\packages_official.json'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -UseBasicParsing -OutFile $list `
    -Uri 'https://raw.githubusercontent.com/nim-lang/packages/master/packages.json'
  # [DECISIONS G436] A package's checksum is over the bytes Nimble checks out. Nimble turns
  # core.autocrlf off in each clone, but a fetch by revision leaves core.eol native, so a package
  # whose .gitattributes marks files as text would check out with CRLF here and carry another
  # checksum than the lock's. These hold for Nimble's git only (GIT_CONFIG_*, git 2.31 or later),
  # not for the machine's git configuration.
  $gitConfig = [ordered]@{
    GIT_CONFIG_COUNT = '2'
    GIT_CONFIG_KEY_0 = 'core.autocrlf'; GIT_CONFIG_VALUE_0 = 'false'
    GIT_CONFIG_KEY_1 = 'core.eol'; GIT_CONFIG_VALUE_1 = 'lf'
  }
  foreach ($name in $gitConfig.Keys) { Set-Item "Env:$name" $gitConfig[$name] }
  try {
    Invoke-Native 'nimble setup -l' { nimble --useSystemNim -y setup -l }
  } finally {
    foreach ($name in $gitConfig.Keys) { Remove-Item -ErrorAction SilentlyContinue "Env:$name" }
  }
  Get-Content (Join-Path $Repo 'nimble.paths')
  # Nimble checks none of nimble.lock's checksums (draft #191); `test` runs this again first.
  Invoke-Native 'check_installs' { nim r --hints:off tools/check_installs.nim }
}

function Step-Test {
  Use-Toolchain
  Set-Location $Repo
  Write-Host "LCN_SHARD=$env:LCN_SHARD"
  Assert-NimPin
  Invoke-Native 'nimble test' { nimble --useSystemNim test }
}

# --- probe -----------------------------------------------------------------------------------

# Values that change from run to run on one build: pids, handle values and counts, timings, the
# scratch directory, and what the launcher decides (privileges, whether a Job Object holds the
# probe). A fact whose outcome races (the exited peer's pid after the close) is left out.
function ConvertTo-Comparable([string]$Line) {
  if ($Line -match '\.(open_exited_pid_after_close) ') { return $null }
  $l = $Line -replace '\\lp\d+', '\lp#'
  $l = $l -replace '(?<=pid[a-z_]*[ =])\d{3,}', '#'
  $l = $l -replace '\b(caller|acceptor|self|value)=\d+', '$1=#'
  $l = $l -replace '\bms=\d+', 'ms=#'
  $l = $l -replace '^(fact \S+(_ms|_wakeups|signal_seen|child_handle_count)) .*$', '$1 #'
  $l = $l -replace '^(fact \S+\.(enabled_privileges|probe_in_job)) .*$', '$1 #'
  return $l
}

function ConvertTo-PublicFacts([string[]]$Lines) {
  # The repository is public: the machine part of account SIDs and the account name go.
  $user = [regex]::Escape($env:USERNAME)
  $Lines | Where-Object { $_ -like 'fact *' } | ForEach-Object {
    ($_ -replace 'S-1-5-21-\d+-\d+-\d+', 'S-1-5-21-<machine>') -replace "(?i)$user", '<user>'
  }
}

function Compare-Facts([string]$Probe, [string]$Build, [string[]]$Facts, [string]$Committed) {
  $pattern = '^' + [regex]::Escape($Build) + '\.(\d+)-.+-' + [regex]::Escape($Probe) + '\.txt$'
  $known = Get-ChildItem -LiteralPath $Committed -File | Where-Object { $_.Name -match $pattern } |
    Sort-Object { [int]($_.Name -replace $pattern, '$1') } | Select-Object -Last 1
  if (-not $known) {
    return @("**$Probe**: build $Build has no committed facts under ``tools/winprobe/facts``. " +
      'It is not a qualified build; these facts are the evidence for adding it.')
  }
  $old = @(Get-Content -LiteralPath $known.FullName | ForEach-Object { ConvertTo-Comparable $_ } |
      Where-Object { $_ } | Sort-Object -Unique)
  $new = @($Facts | ForEach-Object { ConvertTo-Comparable $_ } | Where-Object { $_ } |
      Sort-Object -Unique)
  $diff = @(Compare-Object -ReferenceObject $old -DifferenceObject $new)
  if ($diff.Count -eq 0) {
    return @("**$Probe**: same facts as ``$($known.Name)`` (pids, timings and paths aside).")
  }
  Write-Host "::warning::$Probe facts differ from $($known.Name) in $($diff.Count) lines"
  $out = @("**$Probe**: $($diff.Count) lines differ from ``$($known.Name)``:", '', '```')
  foreach ($d in $diff) {
    $side = if ($d.SideIndicator -eq '=>') { '+ ' } else { '- ' }
    $out += $side + $d.InputObject
  }
  return $out + @('```')
}

function Step-Probe {
  Use-Toolchain
  Set-Location $Repo
  if ($Machine -eq '') {
    if ($env:ImageOS) { $Machine = "gha-$($env:ImageOS)" }
    else { $Machine = $env:COMPUTERNAME.ToLowerInvariant() }
  }
  $out = [IO.Path]::GetFullPath((Join-Path $Repo $OutDir))
  New-Item -ItemType Directory -Force $out | Out-Null
  $scratch = if ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP 'lp' } else { Join-Path $env:TEMP 'lcnlp' }
  New-Item -ItemType Directory -Force $scratch | Out-Null

  Invoke-Native 'gcc winprobe.c' {
    gcc -O1 -Wall -o "$out\winprobe.exe" tools\winprobe\winprobe.c -lws2_32 -ladvapi32 -lversion
  }
  Invoke-Native 'nim c loopprobe.nim' {
    nim c -d:release --hints:off "--nimcache:$out\nimcache" "--outdir:$out" tools\winprobe\loopprobe.nim
  }
  # Through cmd, so the output stays the probes' own bytes (Windows PowerShell's `>` writes UTF-16).
  cmd /c "`"$out\winprobe.exe`" > `"$out\winprobe.raw`" 2>&1"
  $winRc = $LASTEXITCODE
  cmd /c "`"$out\loopprobe.exe`" `"$scratch`" > `"$out\loopprobe.raw`" 2>&1"
  $loopRc = $LASTEXITCODE

  $win = @(ConvertTo-PublicFacts (Get-Content "$out\winprobe.raw"))
  $loop = @(ConvertTo-PublicFacts (Get-Content "$out\loopprobe.raw"))
  $build = ''
  $ubr = ''
  foreach ($l in $win) {
    if ($build -eq '' -and $l -match 'Q15\.version 10\.0\.(\d+)$') { $build = $Matches[1] }
    if ($ubr -eq '' -and $l -match 'Q15\.ubr (\d+)$') { $ubr = $Matches[1] }
  }
  if ($build -eq '' -or $ubr -eq '') { throw 'winprobe printed no build (Q15.version, Q15.ubr)' }

  $facts = Join-Path $out 'facts'
  New-Item -ItemType Directory -Force $facts | Out-Null
  $summary = @("### Windows probes on build $build.$ubr ($Machine)", '')
  foreach ($p in @(@{ Name = 'winprobe'; Facts = $win; Rc = $winRc }, @{ Name = 'loopprobe'; Facts = $loop; Rc = $loopRc })) {
    $file = Join-Path $facts "$build.$ubr-$Machine-$($p.Name).txt"
    [IO.File]::WriteAllText($file, (($p.Facts -join "`n") + "`n"))
    Write-Host "$($p.Name): exit $($p.Rc), $($p.Facts.Count) facts in $file"
    $summary += Compare-Facts $p.Name $build $p.Facts (Join-Path $Repo 'tools\winprobe\facts')
    $summary += ''
    if ($p.Rc -ne 0) { $summary += "**$($p.Name)** exited with $($p.Rc): it could not measure everything."; $summary += '' }
  }
  $summary | ForEach-Object { Write-Host $_ }
  if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary -Encoding utf8 }
  if ($winRc -ne 0 -or $loopRc -ne 0) { exit 1 }
}

switch ($Step) {
  'toolchain' { Step-Toolchain }
  'setup' { Step-Setup }
  'test' { Step-Test }
  'probe' { Step-Probe }
}
