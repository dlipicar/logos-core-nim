# The body of `nix run .#test-ios` (nix/ios.nix sets sources, deps and
# variants). Needs Xcode with an iOS simulator runtime. Builds every suite under
# every variant for the arm64 iOS simulator and, under orc, for arm64 iOS devices
# (built and checked, not run); creates a simulator, runs each simulator suite
# from the repository root, and deletes the simulator.
#
# Usage: test-ios [PATTERN]   runs the suites whose name contains PATTERN.

pattern="${1:-}"
minIos=15.0 # [IMPL] the oldest iOS the binaries target

if ! simSdk=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null) ||
  ! devSdk=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null); then
  echo "test-ios: no iOS SDK; install Xcode and select it with xcode-select" >&2
  exit 1
fi
toolchain=$(dirname "$(xcrun --sdk iphonesimulator -f clang)")
# Xcode's compilers only: Nim compiles C++ with whatever `clang++` is on PATH,
# and a Nix shell's clang wrapper would add the macOS SDK.
export PATH="$toolchain:$PATH"
export CC="$toolchain/clang" CXX="$toolchain/clang++"
unset SDKROOT MACOSX_DEPLOYMENT_TARGET

work=$(mktemp -d "${TMPDIR:-/tmp}/lcn-ios-XXXXXX")
udid=""
cleanup() {
  if [ -n "$udid" ]; then
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# The repository as the suites see it, with nimble.paths naming the locked
# dependencies the way `nimble setup -l` would.
cp -R "$sources" "$work/repo"
chmod -R u+w "$work/repo"
echo '--noNimblePath' >"$work/repo/nimble.paths"
while read -r dirName src; do
  srcDir=$(sed -nE 's/^[[:space:]]*srcDir[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' \
    "$src"/*.nimble | head -1)
  echo "--path:\"$src${srcDir:+/$srcDir}\"" >>"$work/repo/nimble.paths"
  echo "test-ios: dependency $dirName" >&2
done <<<"$deps"

build() { # build TARGET SDK SUFFIX FLAGS TEST OUT
  local target=$1 sdk=$2 suffix=$3 flags=$4 test=$5 out=$6
  local name
  name=$(basename "$test" .nim)
  # shellcheck disable=SC2086
  (cd "$work/repo" && nim c $flags --os:ios --cpu:arm64 --cc:clang --hints:off \
    --nimcache:"$work/nimcache/$target/$name-$suffix" \
    --passC:"-target $target -isysroot $sdk" --passL:"-target $target -isysroot $sdk" \
    -o:"$out/$name-$suffix" "$test" </dev/null)
}

mkdir -p "$work/sim" "$work/device"
for test in "$work"/repo/tests/test_*.nim; do
  case "$(basename "$test")" in *"$pattern"*) ;; *) continue ;; esac
  while read -r suffix flags; do
    echo "test-ios: building $(basename "$test" .nim)-$suffix" >&2
    build "arm64-apple-ios$minIos-simulator" "$simSdk" "$suffix" "$flags" "$test" "$work/sim"
  done <<<"$variants"
  build "arm64-apple-ios$minIos" "$devSdk" orc "--mm:orc" "$test" "$work/device"
done

# The static check: each binary is arm64 for its platform (LC_BUILD_VERSION
# platform 7 is the simulator, 2 a device).
check() { # check DIR PLATFORM
  for b in "$1"/*; do
    if ! otool -l "$b" | grep -A3 LC_BUILD_VERSION | grep -qE "platform $2$"; then
      echo "test-ios: $b is not for platform $2" >&2
      exit 1
    fi
  done
}
check "$work/sim" 7
check "$work/device" 2

# `simctl spawn` starts a program with no working directory of its own; this
# launcher enters the repository first.
cat >"$work/cdrun.c" <<'EOF'
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: cdrun DIR PROGRAM [ARG...]\n"); return 2; }
  if (chdir(argv[1]) != 0) { perror(argv[1]); return 2; }
  execv(argv[2], argv + 2);
  perror(argv[2]);
  return 2;
}
EOF
"$CC" -target "arm64-apple-ios$minIos-simulator" -isysroot "$simSdk" -O2 \
  -o "$work/cdrun" "$work/cdrun.c"

# The newest iOS runtime installed, and the first iPhone it supports.
runtimes=$(xcrun simctl list runtimes -j)
runtime=$(jq -r '[.runtimes[] | select(.isAvailable and (.identifier | test("SimRuntime\\.iOS-[0-9]+-[0-9]+$")))]
  | sort_by(.version | split(".") | map(tonumber)) | last | .identifier // empty' <<<"$runtimes")
if [ -z "$runtime" ]; then
  echo "test-ios: no iOS simulator runtime; run: xcodebuild -downloadPlatform iOS" >&2
  exit 1
fi
device=$(jq -r --arg r "$runtime" '.runtimes[] | select(.identifier == $r)
  | [.supportedDeviceTypes[] | select(.productFamily == "iPhone")] | first | .identifier // empty' <<<"$runtimes")
udid=$(xcrun simctl create "logos-core-nim-test-$$" "$device" "$runtime")
echo "test-ios: booting $device on $runtime" >&2
xcrun simctl boot "$udid"
# A first boot can stall in data migration (seen for hours in the iOS 27.2
# address-book migrator) while launchd already runs spawned programs, which is
# all the suites need. Wait a bounded time, then run them anyway: a simulator
# that cannot spawn fails every suite.
if ! timeout 300 xcrun simctl bootstatus "$udid" -b >/dev/null; then
  echo "test-ios: the simulator did not report booted within 300 s; running the suites anyway" >&2
fi

passed=()
failed=()
for path in "$work"/sim/*; do
  name=$(basename "$path")
  echo "=== $name"
  if xcrun simctl spawn "$udid" "$work/cdrun" "$work/repo" "$path"; then
    passed+=("$name")
  else
    failed+=("$name")
  fi
done

echo "test-ios: ${#passed[@]} suites passed, ${#failed[@]} failed"
if [ "${#failed[@]}" -gt 0 ]; then
  printf '  failed: %s\n' "${failed[@]}"
  exit 1
fi
