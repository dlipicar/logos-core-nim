## lcn_call, the CLI module, in a logosd in this process (Tier 5 steps N-2b
## and N-2c; DECISIONS G343-G350; docs/DAEMON.md §7a; plan §5, L-1 to L-13).
##
## Each case makes a session with `logosctl init`'s library function: the
## meter, shapes, vault (orc and arc only, G277) and bulk kit modules hosted as operator providers,
## operator rules granting `lcn_call` the first three (and `discover` alone on
## bulk), and `cli.artifact` naming the library `support/clibuild` builds. It
## runs `assembleDaemon` and `startDaemon` as logosd's `main` does, and runs
## each command with the launcher's library function (`launch`), as `logosctl
## call` does, from the test's threads, with regular files for stdout and
## stderr; a stream (`subscribe`, `events`) runs from a thread of its own,
## with a pipe for the launcher's cancel. `lcn_call` runs in a Module Host of its own, so the test cannot
## reach its globals: what it did is read from exit codes, its output, the
## Runtime's records (through the logosctl instance), and the meter's `held`
## file (channels 22 and 23 hold a call until the file `open` is in the
## meter's state directory; `meter_impl.nim`). Waits that only bound a test
## scale with `Slow`.
##
## logosctl's argument parsing and the binaries are `test_logosd`'s; the
## module's pure parts (arguments, the wire, hops, activation decisions, the
## classifier) are `test_cli`'s.

when defined(posix):
  const LivePrefix = "lcc" ## the short directories' prefix
  include ./support/lcncall_live

  # Cases ---------------------------------------------------------------------------------

  suite "cli.lcn_call: the CLI module in logosd (DAEMON.md §7a) [IMPL-DECISION G343] [IMPL-DECISION G344] [IMPL-DECISION G348] [IMPL-DECISION G349]":
    setup:
      var l {.inject.} = Live()
      live = addr l

    teardown:
      if live != nil:
        if holding and live[].up:
          try:
            writeFile(live[].meterDir / "open", "")
          except IOError:
            discard
        joinHeld()
        if watching:
          interrupt()
          discard endStream()
        if live[].up:
          finish(live[])
      live = nil

    test "[BCP-0086] [BCP-0088] L-1: the first command starts lcn_call, later ones reuse it and its route; a restarted Runtime resumes it; after module stop the next command starts it again":
      let s = newSession()
      l = boot(s)
      check l.state(CliInstance) == LogosNSRuntimeControlStateKind.Unloaded
      check not fileExists(l.cli)
      let a = l.run(meterRead(7))
      checkpoint a.said
      check a.exit == 0
      let e = a.env
      check e{"status"}.getStr == "ok"
      check e{"result", "label"}.getStr == "ch7"
      check e{"result", "reading", "value"}.getInt == 70
      check l.state(CliInstance) == LogosNSRuntimeControlStateKind.Ready
      let first = l.cliRoutes
      check first.len == 1
      check l.run(meterRead(8)).exit == 0
      let second = l.cliRoutes
      check second.len == 1
      if first.len == 1 and second.len == 1:
        check second[0].route == first[0].route
      # [G350] Stopped by the operator, it is started again by the next command.
      l.stop("lcn_call", CliInstance)
      check l.reaches(CliInstance, LogosNSRuntimeControlStateKind.Unloaded)
      let b = l.run(meterRead(9))
      checkpoint b.said
      check b.exit == 0
      check l.state(CliInstance) == LogosNSRuntimeControlStateKind.Ready
      # [plan R1] The orchestrator resumes it after a restart: its retained
      # intent is `requested`.
      finish(l)
      l = boot(s)
      check l.reaches(CliInstance, LogosNSRuntimeControlStateKind.Ready)
      check l.run(meterRead(10)).exit == 0

    test "L-2: key=value typed from the request rule, --request, JSON and text output":
      l = boot(newSession())
      let a = l.run(meterRead(9))
      checkpoint a.said
      check a.exit == 0
      check a.env{"result", "label"}.getStr == "ch9"
      check a.errors == ""
      let t = l.run(meterRead(9), text = true)
      checkpoint t.said
      check t.exit == 0
      check "\"ch9\"" in t.output
      check t.errors == ""
      check "\"deployment\"" notin t.output # diagnostic notation, no envelope
      # [D26 (a)] The whole request as one JSON object; `reflect` answers with
      # it, which G89 renders as it was written.
      let r = l.run(callOf("shapes_module", "reflect", request = ReflectRequest))
      checkpoint r.said
      check r.exit == 0
      check r.env{"result"} == parseJson(ReflectRequest)
      # A value its field does not read is refused before any call (1).
      let bad = l.run(callOf("meter_module", "read", [("channel", "x")]))
      checkpoint bad.said
      check bad.exit == 1
      check bad.env{"status"}.getStr == "error"
      let badText =
        l.run(callOf("meter_module", "read", [("channel", "x")]), text = true)
      check badText.exit == 1
      check badText.output == ""
      check badText.errors.startsWith("logosctl: ")

    test "L-3: refusals (1), a Runtime Control failure (4) and the provider's error channel (5)":
      l = boot(newSession())
      for (cmd, what) in [
        (callOf("nosuch_module", "read", [("channel", "1")]), "an unknown module"),
        (callOf("meter_module", "nosuch"), "an unknown method"),
      ]:
        checkpoint what
        let r = l.run(cmd)
        checkpoint r.said
        check r.exit == 1
      let node = l.run(meterRead(1), target = "elsewhere")
      checkpoint node.said
      check node.exit == 1
      check "elsewhere" in node.env{"message"}.getStr
      # `discover` alone on bulk: describe works, the route is not authorised.
      check l.run(describeOf("bulk_module")).exit == 0
      let na = l.run(callOf("bulk_module", "send", [("size", "1")]))
      checkpoint na.said
      check na.exit == 4
      check na.env{"code"}.getStr == "NOT_AUTHORISED"
      check l.cliRoutes.allIt(it.module != "bulk_module")
      # Channel 13 fails with a message: the provider's error channel.
      let pe = l.run(meterRead(13))
      checkpoint pe.said
      check pe.exit == 5
      check pe.env{"status"}.getStr == "error"
      let peText = l.run(meterRead(13), text = true)
      check peText.exit == 5
      check "(declared)" in peText.errors

    test "[IFC-0942] L-4: describe prints the provider's contracts, roots and methods":
      l = boot(newSession())
      for (module, instance, root, meth) in [
        ("meter_module", MeterInstance, meterRoot, "read"),
        ("shapes_module", ShapesInstance, shapesRoot, "reflect"),
      ]:
        checkpoint module
        let d = l.run(describeOf(module))
        checkpoint d.said
        check d.exit == 0
        let r = d.env{"result"}
        check r{"module"}.getStr == module
        check r{"instance"}.getStr == instance
        check r{"selected"}.getStr == hexOf(root)
        check r{"record", "primary"}.getStr == hexOf(root)
        let cs = r{"contracts"}.getElems
        check cs.len == 1
        if cs.len == 1:
          check cs[0]{"role"}.getStr == "primary"
          check cs[0]{"root"}.getStr == hexOf(root)
        check r{"methods"}.getElems.anyIt(
          it{"method"}.getStr == meth and not it{"marked"}.getBool
        )
      let t = l.run(describeOf("meter_module"), text = true)
      checkpoint t.said
      check t.exit == 0
      check hexOf(meterRoot) & " (selected)" in t.output
      check "  read " in t.output

    test "L-5: a marked request comes from files only, refused before any route otherwise; a marked response is printed (G349 N-2d)":
      when ChannelsMove:
        l = boot(newSession())
        let d = l.run(describeOf("vault_module"))
        check d.exit == 0
        check d.env{"result", "methods"}.getElems.anyIt(
          it{"method"}.getStr == "store" and it{"marked"}.getBool
        )
        # Inline, all or part: refused before any file is read or route made.
        let s =
          l.run(callOf("vault_module", "store", [("slot", "1"), ("secret", "00")]))
        checkpoint s.said
        check s.exit == 1
        check "store" in s.env{"message"}.getStr
        check "NAME=@FILE" in s.env{"message"}.getStr
        check "00" notin s.env{"message"}.getStr
        let mixed = l.run(
          callWith(
            "vault_module",
            "store",
            @[
              LcnCliArg(
                kind: LcnCliArgKind.lcn_Cli_text_arg,
                arm_lcn_Cli_text_arg: LcnCliTextArg(name: "slot", value: "1"),
              ),
              fileArg("secret", 2),
            ],
          ),
          files = @[l.inFile("\xAA\xBB")],
        )
        checkpoint mixed.said
        check mixed.exit == 1
        check l.cliRoutes.len == 0
        let p = l.run(callOf("vault_module", "peek", [("slot", "1")]))
        checkpoint p.said
        check p.exit == 0
        check p.env{"result", "stored"}.getBool == false
        check l.cliRoutes.len == 1
        # Every field from a file: `slot` as its text, less one newline.
        let stored = l.run(
          callWith("vault_module", "store", @[fileArg("slot", 2), fileArg("secret", 3)]),
          files = @[l.inFile("1\n"), l.inFile("\xAA\xBB\x00\x01")],
        )
        checkpoint stored.said
        check stored.exit == 0
        check stored.env{"result", "stored"}.getBool
        let fetched = l.run(
          callWith("vault_module", "fetch", @[fileArg("slot", 2)]),
          files = @[l.inFile("1")],
        )
        checkpoint fetched.said
        check fetched.exit == 0
        check fetched.env{"result", "secret"}.getStr == "aabb0001"
        check fetched.errors == ""
        let shown = l.run(callOf("vault_module", "fetch", [("slot", "1")]), text = true)
        checkpoint shown.said
        check shown.exit == 0
        check "h'aabb0001'" in shown.output
        # A file past the field's bound is refused, its length named only.
        let long = l.run(
          callWith("vault_module", "store", @[fileArg("slot", 2), fileArg("secret", 3)]),
          files = @[l.inFile("2"), l.inFile(repeat("\xCC", 300))],
        )
        checkpoint long.said
        check long.exit == 1
        check "longer than its field's 256 bytes" in long.env{"message"}.getStr
      else:
        # [DECISIONS G277] A refc build starts no marked provider, and lcn_call
        # refuses a marked method before reading any input.
        skip()

    test "[BCP-0089] L-6: the route is lcn_call's, to the hosted provider; the launcher gets an exit status and the output, no route":
      l = boot(newSession())
      let a = l.run(meterRead(7))
      check a.exit == 0
      let rs = l.cliRoutes
      check rs.len == 1
      if rs.len == 1:
        let r = rs[0]
        check r.consumer.module_instance_id == CliInstance
        check r.module == "meter_module"
        check r.instance == Opt.some(MeterInstance)
        check r.invocation.isNone
      var keys: seq[string]
      for k, _ in a.env.pairs:
        keys.add(k)
      check keys.sorted == @["command", "deployment", "result", "status"]

    test "[BCP-0087] L-7: activation cannot select: an instance or artifact field, or an unknown op, is refused protocol":
      l = boot(newSession())
      check l.run(meterRead(7)).exit == 0 # lcn_call is up
      let good =
        LcnCliMessage(
          command: meterRead(7),
          output: LcnCliOutput(kind: LcnCliOutputKind.Json),
          fds: @[
            LcnCliFdRole(kind: LcnCliFdRoleKind.Stdout),
            LcnCliFdRole(kind: LcnCliFdRoleKind.Stderr),
          ],
        ).toCbor
      var bad: seq[(string, CborValue)]
      for (field, value) in [("instance", cbor(MeterInstance)), ("artifact", cbor("x"))]:
        var v = good
        v.entries.add((cbor(field), value))
        bad.add((field, v))
      var unknownOp = good
      for e in unknownOp.entries.mitems:
        if e.key == cbor("command"):
          e.value = cborMap(
            (cbor("op"), cbor("frobnicate")),
            (cbor("provider"), cborMap((cbor("module"), cbor("meter_module")))),
          )
      bad.add(("an unknown op", unknownOp))
      for (what, v) in bad:
        checkpoint what
        let (_, ofd) = outFile(l.outDir)
        let (_, efd) = outFile(l.outDir)
        let fd = connectCtl(l.cli, Timeout).expect("a connection")
        check writeRequest(fd, encodeCbor(v), [ofd, efd], Timeout).isOk
        let reply = readReply(fd, Timeout)
        check reply.isOk
        if reply.isOk:
          check reply.get.outcome.kind == LcnCliOutcomeKind.lcn_Cli_refused
          if reply.get.outcome.kind == LcnCliOutcomeKind.lcn_Cli_refused:
            check reply.get.outcome.arm_lcn_Cli_refused.reason.kind ==
              LcnCliRefusedReasonChoiceKind.Protocol
        closeFd(fd)
        discard posix.close(ofd)
        discard posix.close(efd)
      check l.run(meterRead(7)).exit == 0 # still serving

    test "L-8: with workers = 1 a second command is refused busy until its timeout; a listener of another uid is refused; without discover, describe is a Runtime Control failure (4)":
      l = boot(newSession(Shape(workers: 1, bulkDiscover: false)))
      l.hold(22)
      let busy = l.run(meterRead(7), timeoutMs = 1_500 * Slow)
      checkpoint busy.said
      check busy.exit == 2
      check "busy" in busy.failure
      writeFile(l.meterDir / "open", "")
      joinHeld()
      check heldExit.load == 0
      check l.heldLines == 1
      check l.run(meterRead(7)).exit == 0
      # [K20] The launcher checks the listener's uid before it sends anything.
      let other = l.run(meterRead(7), credOf = otherUid)
      checkpoint other.said
      check other.exit == 2
      check other.output == "" and other.errors == ""
      let nd = l.run(describeOf("bulk_module"))
      checkpoint nd.said
      check nd.exit == 4
      check nd.env{"code"}.getStr == "NOT_AUTHORISED"

    test "L-9: lcn_call's host killed: the next command recovers it and succeeds":
      l = boot(newSession())
      let before = hostPids()
      check l.run(meterRead(7)).exit == 0
      let mine = hostPids().filterIt(it notin before)
      check mine.len == 1
      if mine.len == 1:
        check posix.kill(Pid(mine[0]), SIGKILL) == 0
        check l.reaches(CliInstance, LogosNSRuntimeControlStateKind.Error)
        let r = l.run(meterRead(7))
        checkpoint r.said
        check r.exit == 0
        check l.state(CliInstance) == LogosNSRuntimeControlStateKind.Ready
        check mine[0] notin hostPids()

    test "L-10: calls past a short decision validity, concurrent calls on one route, an idle close, and a call after the provider restarted":
      # [IMPL] A decision takes up to about 1.5 s on a loaded host (refc, or a
      # load of 100), and its validity runs from it. With 8 s and a command
      # every second, the next command renews the route before it ends; the
      # idle close comes only after the calls stop. A refc build takes `Load`
      # times as long for a decision and a renewal.
      let validity = 8_000 * Slow * Load
      let idle = validity
      l = boot(newSession(Shape(validityMs: validity, routeIdleMs: idle)))
      check l.run(meterRead(7)).exit == 0
      let first = l.cliRoutes
      check first.len == 1
      # [G348] Past the decision's validity the route is renewed onto a new
      # handle: the calls go on, on the same route.
      let began = getMonoTime()
      var calls = 0
      while calls < 3 or
          getMonoTime() - began < initDuration(milliseconds = 2 * validity):
        let r = l.run(meterRead(7))
        checkpoint r.said
        check r.exit == 0
        inc calls
        sleep(validity div 8)
      let renewed = l.cliRoutes
      check renewed.len == 1
      if first.len == 1 and renewed.len == 1:
        check renewed[0].route == first[0].route
        check renewed[0].decision_id != first[0].decision_id
      # Six workers call on the one route at once.
      var threads: array[6, Thread[(ptr Live, int)]]
      for i in 0 ..< threads.len:
        concurrent[i].store(-1)
        createThread(threads[i], reader, (addr l, i))
      joinThreads(threads)
      for i in 0 ..< threads.len:
        check concurrent[i].load == 0
      check l.cliRoutes.len == 1
      # [G348, G350] Unused for `route_idle_ms`, lcn_call closes it.
      let closing = getMonoTime() + initDuration(milliseconds = idle + Patience * 1000)
      while l.cliRoutes.len > 0 and getMonoTime() < closing:
        sleep(50)
      check l.cliRoutes.len == 0
      check l.state(CliInstance) == LogosNSRuntimeControlStateKind.Ready
      check l.run(meterRead(7)).exit == 0
      let again = l.cliRoutes
      check again.len == 1
      if again.len == 1 and first.len == 1:
        check again[0].route != first[0].route
      # [G348; plan §3.5 step 8] After the provider restarted, the ended handle
      # is not used (rule 1) or a NOT_READY completion is retried once (rule 2).
      l.stop("meter_module", MeterInstance)
      check l.reaches(MeterInstance, LogosNSRuntimeControlStateKind.Unloaded)
      l.start("meter_module", MeterInstance)
      check l.reaches(MeterInstance, LogosNSRuntimeControlStateKind.Ready)
      let after = l.run(meterRead(7))
      checkpoint after.said
      check after.exit == 0

    test "L-11: subscribe: --count and --for, the event's three name forms, text output, the launcher's EOF (130), a stalled reader (6), the provider stopping (6), lcn_call stopping (6) [IMPL-DECISION G349]":
      l = boot(newSession(Shape(bulkStream: true)))
      # [G349] `--count 3`: three lines, then 0. Until the subscription is
      # active a publication reaches no one, so the meter publishes until
      # the stream has its three.
      l.stream(subscribeOf("meter_module", "changed", count = 3))
      check within(streamEnded(), l.publish())
      check endStream() == 0
      let three = streamLines()
      checkpoint saidStream()
      check three.len == 3
      for x in three:
        check x{"event"}.getStr == "meter.changed_event"
        check x{"data"} == %*{"value": 150}
      # `--for`: no event in 300 ms; 0, and nothing written.
      l.stream(subscribeOf("meter_module", "meter.changed_event", forMs = 300))
      check endStream() == 0
      check streamOutput() == ""
      check streamErrors() == ""
      # An event the provider does not declare is refused before any route (1).
      let unknown = l.run(subscribeOf("meter_module", "flashed"))
      checkpoint unknown.said
      check unknown.exit == 1
      check "changed" in unknown.env{"message"}.getStr
      # Text; the launcher's EOF ends the stream (130), and lcn_call serves
      # the next command.
      l.stream(subscribeOf("meter_module", "changed_event"), text = true)
      check within(
        "meter.changed_event {\"value\": 150}" in streamOutput(), l.publish()
      )
      interrupt()
      check endStream() == 130
      check streamErrors() == ""
      check l.run(meterRead(7)).exit == 0
      # [plan §3.7] A stalled reader: stdout is a pipe nothing reads, so the
      # queue fills (16 MiB) with 2 MiB events and the stream ends (6); the
      # failure's envelope goes to stderr, since stdout waits for the same
      # reader.
      l.stream(subscribeOf("bulk_module", "carried"), stalled = true)
      check within(streamEnded(), l.sendBulk(2 * 1024 * 1024))
      check endStream() == 6
      checkpoint saidStream()
      try:
        let e = parseJson(streamErrors().strip)
        check e{"status"}.getStr == "error"
        check e{"message"}.getStr == "the terminal did not keep up; the stream ended"
      except CatchableError as e:
        checkpoint("stderr is not one envelope: " & e.msg)
        fail()
      check l.run(meterRead(7)).exit == 0
      # The provider stops: the route ends, and the stream with it (6), after
      # the lines it had.
      l.stream(subscribeOf("meter_module", "changed"))
      check within(streamLines().eventsIn.len >= 1, l.publish())
      l.stop("meter_module", MeterInstance)
      check within(streamEnded(), sleep(10))
      check endStream() == 6
      let stopped = streamLines()
      checkpoint saidStream()
      check stopped.eventsIn.len >= 1
      if stopped.len > 0:
        check stopped[^1]{"status"}.getStr == "error"
        check "the route ended" in stopped[^1]{"message"}.getStr
      # The route ends as the stop begins; a start is refused until it is done.
      check l.reaches(MeterInstance, LogosNSRuntimeControlStateKind.Unloaded)
      l.start("meter_module", MeterInstance)
      check l.reaches(MeterInstance, LogosNSRuntimeControlStateKind.Ready)
      # lcn_call stopping ends its streams (6), never as a cancel (130). The
      # Runtime may end lcn_call's routes as the stop begins, before
      # `_MODULE_destroy`: a subscription's stream then ends with its route.
      l.stream(subscribeOf("meter_module", "changed"), text = true)
      check within(
        "meter.changed_event {\"value\": 150}" in streamOutput(), l.publish()
      )
      l.stop("lcn_call", CliInstance)
      check endStream() == 6
      checkpoint saidStream()
      check "lcn_call is stopping; the stream ended" in streamErrors() or
        "the route ended" in streamErrors()
      check l.reaches(CliInstance, LogosNSRuntimeControlStateKind.Unloaded)
      # `events` has no route: lcn_call's own stop ends it.
      l.stream(eventsOf(), text = true)
      check within(streamOutput().len > 0, l.restart("shapes_module", ShapesInstance))
      l.stop("lcn_call", CliInstance)
      check endStream() == 6
      checkpoint saidStream()
      check "lcn_call is stopping; the stream ended" in streamErrors()
      check l.reaches(CliInstance, LogosNSRuntimeControlStateKind.Unloaded)

    test "[TRN-0392] [RUN-1095] L-11: a revoked grant ends a stream through the subscription-end observer (6) [IMPL-DECISION G349]":
      l = boot(newSession(Shape(meterGrant: true)))
      # Without `subscribe-event` the subscription is refused (4): nothing
      # was subscribed, nothing is written but the failure.
      let refused = l.run(subscribeOf("meter_module", "changed", count = 1))
      checkpoint refused.said
      check refused.exit == 4
      check refused.env{"code"}.getStr == "NOT_AUTHORISED"
      # lcn_call issues itself the grant through the authority's issue_grant
      # (an issue rule, SPEC CA l.696-792), with `logosctl call`.
      let me = l.addressOf(CliInstance)
      let issued = l.run(
        callOf(
          AuthorityModule,
          "issue_grant",
          request = $(
            %*{
              "consumer": me,
              "target": me,
              "scopes": [
                {
                  "kind": "provider-access",
                  "contract": commitmentOf(meterRoot),
                  "actions": ["subscribe-event"],
                }
              ],
            }
          ),
        )
      )
      checkpoint issued.said
      check issued.exit == 0
      let grantId = issued.env{"result", "grant", "grant_id"}.getStr
      check grantId.len > 0
      l.stream(subscribeOf("meter_module", "changed"))
      check within(streamLines().eventsIn.len >= 1, l.publish())
      # [SPEC CA l.906-914] The revocation drops the decisions it allowed: the
      # next delivery is denied, the provider's side ends the subscription,
      # and lcn_call's observer ends the stream with NOT_AUTHORISED. The
      # route was established under the meter's rule and stays.
      let revoked = l.run(
        callOf(
          AuthorityModule,
          "revoke_grant",
          request = $(%*{"consumer": me, "grant_id": grantId}),
        )
      )
      checkpoint revoked.said
      check revoked.exit == 0
      check revoked.env{"result", "grant", "status"}.getStr == "revoked"
      check within(streamEnded(), l.publish())
      check endStream() == 6
      let lines = streamLines()
      checkpoint saidStream()
      check lines.eventsIn.len >= 1
      if lines.len > 0:
        check lines[^1]{"code"}.getStr == "NOT_AUTHORISED"
        check lines[^1]{"message"}.getStr ==
          "the subscription ended: authority to receive the event ended"
      check l.run(meterRead(7)).exit == 0

    test "L-11: a stream lasts one route session: under a short decision_validity_ms it ends with its route's session (6) [IMPL-DECISION G349]":
      # [P5; R l.3337-3338] A renewal does not extend a session; nothing
      # renews the stream's route, so it ends at the decision's valid_until.
      let validity = 8_000 * Slow
      l = boot(newSession(Shape(validityMs: validity)))
      l.stream(subscribeOf("meter_module", "changed"), text = true)
      check within("meter.changed_event" in streamOutput(), l.publish())
      check within(streamEnded(), sleep(10))
      check endStream() == 6
      checkpoint saidStream()
      check "the route's session ended; run the command again" in streamErrors()
      check l.run(meterRead(7)).exit == 0

    test "L-12: events follows a module start; an event outside the events rule is NOT_AUTHORISED (4); an unknown one is refused (1) [IMPL-DECISION G346] [IMPL-DECISION G349]":
      l = boot(newSession())
      # The default set, the events rule's three. Until the subscriptions are
      # active a start is not seen, so shapes is stopped and started until
      # one is.
      l.stream(eventsOf(count = 1))
      check within(streamEnded(), l.restart("shapes_module", ShapesInstance))
      check endStream() == 0
      let seen = streamLines()
      checkpoint saidStream()
      check seen.len == 1
      if seen.len == 1:
        check seen[0]{"event"}.getStr in [
          "logos.runtime_control.module_state_changed_event",
          "logos.runtime_control.execution_state_changed_event",
        ]
        check seen[0]{"data", "instance"}.getStr == ShapesInstance
      check l.reaches(ShapesInstance, LogosNSRuntimeControlStateKind.Ready)
      # [G345 S7] route_state_changed is outside the events rule.
      let denied = l.run(eventsOf(["route_state_changed"], count = 1))
      checkpoint denied.said
      check denied.exit == 4
      check denied.env{"code"}.getStr == "NOT_AUTHORISED"
      let unknown = l.run(eventsOf(["module_flashed"]))
      checkpoint unknown.said
      check unknown.exit == 1
      check "module_state_changed" in unknown.env{"message"}.getStr

    test "L-13: a route ended while its call is in flight: exit 2, the outcome unknown, no retry; the provider saw one call":
      l = boot(newSession(Shape(stopDeadlineMs: StopDeadlineMs)))
      check l.run(meterRead(7)).exit == 0
      # Channel 23 waits for `open` alone: the stop ends at its deadline, and
      # the provider's host with it, while the call is admitted and running.
      l.hold(23)
      l.stop("meter_module", MeterInstance)
      joinHeld()
      check heldExit.load == 2
      check heldUnknown.load
      check l.heldLines == 1
      check l.reaches(MeterInstance, LogosNSRuntimeControlStateKind.Unloaded)
else:
  import unittest2

  suite "cli.lcn_call: the CLI module in logosd (POSIX only)":
    test "[IMPL] logosd is a stub on this platform (DECISIONS G107); there is no lcn_call to run":
      skip()
