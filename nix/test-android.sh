# The body of `nix run .#test-android` (nix/android.nix sets sdk, suites, data
# and systemImage). Boots a headless x86_64 emulator, pushes the cross-compiled
# suites and the data they read, runs each one from the repository root, and
# stops the emulator. Needs /dev/kvm.
#
# Usage: test-android [PATTERN]   runs the suites whose name contains PATTERN.

pattern="${1:-}"

if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
  echo "test-android: /dev/kvm is not usable by $(id -un)" >&2
  exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/lcn-android-XXXXXX")
export ANDROID_SDK_ROOT="$sdk/libexec/android-sdk"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_USER_HOME="$work/user"
export ANDROID_AVD_HOME="$work/avd"
mkdir -p "$ANDROID_USER_HOME" "$ANDROID_AVD_HOME"
adb="$ANDROID_SDK_ROOT/platform-tools/adb"

port=""
for p in $(seq 5554 2 5584); do
  if ! "$adb" devices | grep -q "^emulator-$p"; then
    port=$p
    break
  fi
done
if [ -z "$port" ]; then
  echo "test-android: no free emulator port" >&2
  exit 1
fi
export ANDROID_SERIAL="emulator-$port"

echo no | "$sdk/bin/avdmanager" create avd --force -n lcn -k "$systemImage" \
  -p "$ANDROID_AVD_HOME/lcn.avd" >/dev/null

"$ANDROID_SDK_ROOT/emulator/emulator" -avd lcn -port "$port" -no-window -no-audio \
  -no-boot-anim -no-snapshot -gpu swiftshader_indirect -accel on \
  >"$work/emulator.log" 2>&1 &
emulator=$!

stop() {
  status=$?
  "$adb" emu kill >/dev/null 2>&1 || kill "$emulator" 2>/dev/null || true
  wait "$emulator" 2>/dev/null || true
  if [ "$status" -ne 0 ] && [ -z "${booted:-}" ]; then
    echo "test-android: the emulator's log:" >&2
    tail -40 "$work/emulator.log" >&2 || true
  fi
  rm -rf "$work"
}
trap stop EXIT

# Up to five minutes for the device to come up and finish booting.
echo "test-android: booting $systemImage on $ANDROID_SERIAL" >&2
booted=""
for _ in $(seq 1 150); do
  if [ "$("$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
    booted=1
    break
  fi
  if ! kill -0 "$emulator" 2>/dev/null; then
    echo "test-android: the emulator exited" >&2
    break
  fi
  sleep 2
done
if [ -z "$booted" ]; then
  echo "test-android: $ANDROID_SERIAL did not boot; adb sees: $("$adb" devices | tr '\n' ' ')" >&2
  exit 1
fi
echo "test-android: booted" >&2

dest=/data/local/tmp/lcn
"$adb" shell rm -rf "$dest"
"$adb" shell mkdir -p "$dest"
"$adb" push "$data/repo" "$data/boringssl" "$suites" "$dest/" >/dev/null
# Store files arrive read-only; the suites write under build/.
"$adb" shell chmod -R u+w "$dest"

passed=()
failed=()
for path in "$suites"/*; do
  name=$(basename "$path")
  case "$name" in *"$pattern"*) ;; *) continue ;; esac
  echo "=== $name"
  # The command line is built here and runs on the device.
  # shellcheck disable=SC2029
  if "$adb" shell "cd $dest/repo && LCN_BORINGSSL_DIR=$dest/boringssl $dest/bin/$name"; then
    passed+=("$name")
  else
    failed+=("$name")
  fi
done

echo "test-android: ${#passed[@]} suites passed, ${#failed[@]} failed"
if [ "${#failed[@]}" -gt 0 ]; then
  printf '  failed: %s\n' "${failed[@]}"
  exit 1
fi
