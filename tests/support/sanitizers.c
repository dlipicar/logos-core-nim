/* Run-time defaults for the sanitizer builds (-d:asan, -d:tsan and -d:msan in
   config.nims), compiled into every program they link, so a plain run and a Nix
   check behave alike. Each runtime calls only its own hooks; ASAN_OPTIONS and the
   other variables in the environment still take precedence. */

#define HOOK __attribute__((visibility("default"), used))

HOOK const char *__asan_default_options(void) {
  return "detect_stack_use_after_return=1:check_initialization_order=1";
}

HOOK const char *__ubsan_default_options(void) { return "print_stacktrace=1"; }

HOOK const char *__tsan_default_options(void) {
  return "halt_on_error=1:second_deadlock_stack=1";
}

HOOK const char *__tsan_default_suppressions(void) {
  /* Nim 2.2.14 lib/system/channels_builtin.nim: sendImpl and recvImpl compare
     q.cap with ChannelDead before they take the channel's lock, while grow
     writes q.cap holding it. Matched on the top frame only, so a race on
     anything a channel carries is still reported. */
  return "race_top:system::sendImpl\n"
         "race_top:system::recvImpl\n";
}
