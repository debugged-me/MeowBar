import XCTest
@testable import MeowBarCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

final class CountdownTests: XCTestCase {
    func testLongNeverSaysZeroMinutes() {
        XCTAssertEqual(Countdown.long(to: now.addingTimeInterval(30), now: now), "in <1m")
        XCTAssertEqual(Countdown.long(to: now.addingTimeInterval(-5), now: now), "in <1m")
        XCTAssertEqual(Countdown.long(to: now.addingTimeInterval(125), now: now), "in 2m")
        XCTAssertEqual(Countdown.long(to: now.addingTimeInterval(4 * 3600 + 52 * 60), now: now), "in 4h 52m")
        XCTAssertEqual(Countdown.long(to: now.addingTimeInterval(6 * 86400 + 22 * 3600), now: now), "in 6d 22h")
    }

    func testCompact() {
        XCTAssertEqual(Countdown.compact(to: now.addingTimeInterval(20), now: now), "<1m")
        XCTAssertEqual(Countdown.compact(to: now.addingTimeInterval(4 * 3600 + 59 * 60), now: now), "4h59m")
    }

    func testAgo() {
        XCTAssertEqual(Countdown.ago(now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(Countdown.ago(now.addingTimeInterval(-240), now: now), "4m ago")
        XCTAssertEqual(Countdown.ago(now.addingTimeInterval(-7200), now: now), "2h ago")
    }
}

final class WindowTests: XCTestCase {
    func testElapsedFraction() {
        let w = UsageWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(3 * 3600), windowSeconds: 18000)
        XCTAssertEqual(w.elapsedFraction(now: now)!, 0.4, accuracy: 0.0001)
        XCTAssertNil(UsageWindow(usedPercent: 0).elapsedFraction(now: now))
    }

    func testExpiredSessionGoesIdle() {
        let w = UsageWindow(usedPercent: 40, resetsAt: now.addingTimeInterval(-60), windowSeconds: 18000)
        let n = w.normalized(now: now)
        XCTAssertEqual(n.usedPercent, 0)
        XCTAssertNil(n.resetsAt)
    }

    func testExpiredWeeklyRollsForward() {
        let reset = now.addingTimeInterval(-3600)
        let w = UsageWindow(usedPercent: 70, resetsAt: reset, windowSeconds: 604800)
        let n = w.normalized(now: now)
        XCTAssertEqual(n.usedPercent, 0)
        XCTAssertEqual(n.resetsAt, reset.addingTimeInterval(604800))
    }

    func testLiveWindowUntouched() {
        let w = UsageWindow(usedPercent: 40, resetsAt: now.addingTimeInterval(60), windowSeconds: 18000)
        XCTAssertEqual(w.normalized(now: now), w)
    }

    func testPaceVerdicts() {
        // 1h into a 5h window
        let reset = now.addingTimeInterval(4 * 3600)
        XCTAssertEqual(UsageWindow(usedPercent: 5, resetsAt: reset, windowSeconds: 18000).paceVerdict(now: now), "plenty left")
        XCTAssertEqual(UsageWindow(usedPercent: 40, resetsAt: reset, windowSeconds: 18000).paceVerdict(now: now), "may run out in ~1h 30m")
        XCTAssertEqual(UsageWindow(usedPercent: 100, resetsAt: reset, windowSeconds: 18000).paceVerdict(now: now), "maxed")
        // first 10 minutes: too early to call
        let early = now.addingTimeInterval(18000 - 300)
        XCTAssertEqual(UsageWindow(usedPercent: 5, resetsAt: early, windowSeconds: 18000).paceVerdict(now: now), "")
    }

    func testWeeklyPaceWaitsForSignal() {
        // 3h into a week at 5%: a straight line says "out in ~2.5 days" — too little to go on.
        let reset = now.addingTimeInterval(604800 - 3 * 3600)
        XCTAssertEqual(UsageWindow(usedPercent: 5, resetsAt: reset, windowSeconds: 604800).paceVerdict(now: now), "")
        // …unless usage is already high.
        XCTAssertEqual(UsageWindow(usedPercent: 40, resetsAt: reset, windowSeconds: 604800).paceVerdict(now: now), "may run out in ~4h 30m")
        // 2 days in at 50%: on track to run out a day early.
        let later = now.addingTimeInterval(604800 - 2 * 86400)
        XCTAssertEqual(UsageWindow(usedPercent: 50, resetsAt: later, windowSeconds: 604800).paceVerdict(now: now), "may run out in ~2d")
    }

    func testTimeToEmpty() {
        // 1h into a 5h window at 40%: burns 40%/h → 100% in 1.5h, before reset.
        let reset = now.addingTimeInterval(4 * 3600)
        XCTAssertEqual(UsageWindow(usedPercent: 40, resetsAt: reset, windowSeconds: 18000)
            .timeToEmpty(now: now)!, 5400, accuracy: 1)
        // On pace to finish the window under the limit → no empty date.
        XCTAssertNil(UsageWindow(usedPercent: 10, resetsAt: reset, windowSeconds: 18000).timeToEmpty(now: now))
        // Already maxed, or too little signal → nil (the verdict covers these).
        XCTAssertNil(UsageWindow(usedPercent: 100, resetsAt: reset, windowSeconds: 18000).timeToEmpty(now: now))
        let early = now.addingTimeInterval(18000 - 300)
        XCTAssertNil(UsageWindow(usedPercent: 5, resetsAt: early, windowSeconds: 18000).timeToEmpty(now: now))
    }

    func testRoughDurations() {
        XCTAssertEqual(Countdown.rough(60), "5m")
        XCTAssertEqual(Countdown.rough(33 * 60), "35m")
        XCTAssertEqual(Countdown.rough(111 * 60), "1h 45m")
        XCTAssertEqual(Countdown.rough(40 * 3600), "1d 18h")
        XCTAssertEqual(Countdown.rough(86000), "1d")
    }
}

final class ProviderTests: XCTestCase {
    func testDisplayLeftPrefersSessionUnlessWeeklyBlocks() {
        var u = ProviderUsage(name: "Claude")
        u.session = UsageWindow(usedPercent: 20)
        u.weekly = UsageWindow(usedPercent: 50)
        XCTAssertEqual(u.displayLeft, 80)
        u.weekly = UsageWindow(usedPercent: 95)
        XCTAssertEqual(u.displayLeft, 5)
        XCTAssertEqual(u.worstUsed, 95)
    }

    func testShareLine() {
        var u = ProviderUsage(name: "Claude")
        u.session = UsageWindow(usedPercent: 69, resetsAt: now.addingTimeInterval(4 * 3600 + 59 * 60),
                                windowSeconds: 18000)
        u.weekly = UsageWindow(usedPercent: 15)
        XCTAssertEqual(u.shareLine(now: now), "Claude: session 31% left · weekly 85% left · resets in 4h59m")

        var plan = ProviderUsage(name: "Devin")
        plan.note = "Pro"; plan.noteAccent = "unlimited"
        XCTAssertEqual(plan.shareLine(now: now), "Devin: Pro unlimited")
        XCTAssertEqual(ProviderUsage(name: "Codex").shareLine(now: now), "Codex: no data")
    }

    func testExtrasJoinWorstAndBlocker() {
        var u = ProviderUsage(name: "Claude")
        u.session = UsageWindow(usedPercent: 20)
        u.weekly = UsageWindow(usedPercent: 50)
        XCTAssertEqual(u.worstUsed, 50)
        u.extras = [NamedWindow(label: "Sonnet", window: UsageWindow(usedPercent: 96))]
        XCTAssertEqual(u.worstUsed, 96)
        XCTAssertEqual(u.displayLeft, 4)       // the maxed extra is the blocker
        u.extras = [NamedWindow(label: "Sonnet", window: UsageWindow(usedPercent: 60))]
        XCTAssertEqual(u.displayLeft, 80)      // under 90 → session still shows
    }

    func testExtrasNormalized() {
        var u = ProviderUsage(name: "Claude")
        u.extras = [NamedWindow(label: "Sonnet", window: UsageWindow(
            usedPercent: 70, resetsAt: now.addingTimeInterval(-60), windowSeconds: 604800))]
        let n = u.normalized(now: now)
        XCTAssertEqual(n.extras?.first?.window.usedPercent, 0)
        XCTAssertNotNil(n.extras?.first?.window.resetsAt) // weekly rolls forward
    }

    func testExtraWindowKeys() {
        XCTAssertEqual(ExtraWindows.label(forKey: "seven_day_sonnet"), "Sonnet")
        XCTAssertEqual(ExtraWindows.label(forKey: "seven_day_oauth_apps"), "OAuth apps")
        XCTAssertEqual(ExtraWindows.label(forKey: "five_hour_extra"), "Extra")
        XCTAssertNil(ExtraWindows.label(forKey: "seven_day"))
        XCTAssertNil(ExtraWindows.label(forKey: "rate_limit"))
        XCTAssertEqual(ExtraWindows.windowSeconds(forKey: "seven_day_opus"), 604800)
        XCTAssertEqual(ExtraWindows.windowSeconds(forKey: "five_hour_x"), 18000)
    }

    func testShareLineWithExtras() {
        var u = ProviderUsage(name: "Claude")
        u.session = UsageWindow(usedPercent: 69)
        u.extras = [NamedWindow(label: "Sonnet", window: UsageWindow(usedPercent: 60))]
        XCTAssertEqual(u.shareLine(now: now), "Claude: session 31% left · sonnet 40% left")
    }

    func testCacheRoundTripDropsPerFetchState() throws {
        var u = ProviderUsage(name: "Codex")
        u.session = UsageWindow(usedPercent: 12, resetsAt: now, windowSeconds: 18000)
        u.error = "HTTP 429"
        u.action = .runInTerminal("codex login")
        u.isStale = true
        let back = try JSONDecoder().decode(ProviderUsage.self, from: JSONEncoder().encode(u))
        XCTAssertEqual(back.session, u.session)
        XCTAssertNil(back.error)
        XCTAssertNil(back.action)
        XCTAssertFalse(back.isStale)
    }
}

final class SessionClockTests: XCTestCase {
    let idle = UsageWindow(usedPercent: 0, resetsAt: nil, windowSeconds: 18000)

    func testIdleDetection() {
        XCTAssertTrue(SessionClock.isIdle(idle, now: now))
        XCTAssertTrue(SessionClock.isIdle(UsageWindow(usedPercent: 30, resetsAt: now.addingTimeInterval(-1)), now: now))
        XCTAssertFalse(SessionClock.isIdle(UsageWindow(usedPercent: 0, resetsAt: now.addingTimeInterval(60)), now: now))
        XCTAssertFalse(SessionClock.isIdle(nil, now: now))
    }

    func testStartsOnlyWhenIdleFreshAndUserPresent() {
        func start(stale: Bool = false, idleFor: TimeInterval = 10, locked: Bool = false,
                   running: Bool = false, last: Date? = nil) -> Bool {
            SessionClock.shouldStart(session: idle, dataIsStale: stale, userIdleSeconds: idleFor,
                                     screenLocked: locked, running: running, lastAttempt: last, now: now)
        }
        XCTAssertTrue(start())
        XCTAssertFalse(start(stale: true))
        XCTAssertFalse(start(idleFor: 600))
        XCTAssertFalse(start(locked: true))
        XCTAssertFalse(start(running: true))
        XCTAssertFalse(start(last: now.addingTimeInterval(-60)))
        XCTAssertTrue(start(last: now.addingTimeInterval(-16 * 60)))
    }

    func testEstimatedResetIsFiveHoursAfterTopOfHour() {
        let started = utc.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8, minute: 17))!
        let expected = utc.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 13))!
        XCTAssertEqual(SessionClock.estimatedReset(startedAt: started, calendar: utc), expected)
    }
}

final class HistoryTests: XCTestCase {
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day,
                                      hour: hour, minute: minute))!
    }

    func testAppendSkipsUnchangedUntilHeartbeat() {
        var s: [UsageSample] = []
        XCTAssertTrue(UsageHistory.append(UsageSample(t: now, session: 1, weekly: 1), to: &s))
        XCTAssertFalse(UsageHistory.append(UsageSample(t: now.addingTimeInterval(30), session: 1, weekly: 1), to: &s))
        XCTAssertTrue(UsageHistory.append(UsageSample(t: now.addingTimeInterval(60), session: 2, weekly: 1), to: &s))
        XCTAssertTrue(UsageHistory.append(UsageSample(t: now.addingTimeInterval(60 + 1800), session: 2, weekly: 1), to: &s))
        XCTAssertEqual(s.count, 3)
    }

    func testAppendDropsSamplesPastRetention() {
        var s = [UsageSample(t: now.addingTimeInterval(-9 * 86400), session: 1, weekly: 1)]
        UsageHistory.append(UsageSample(t: now, session: 1, weekly: 1), to: &s)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.t, now)
    }

    func testDailyBurnCountsIncreasesAndResets() {
        let samples = [
            UsageSample(t: at(17, 9), session: 0, weekly: 10),
            UsageSample(t: at(17, 12), session: 0, weekly: 14),   // +4 on the 17th
            UsageSample(t: at(18, 10), session: 0, weekly: 20),   // +6 on the 18th
            UsageSample(t: at(19, 9), session: 0, weekly: 3),     // reset: 3 burned since
            UsageSample(t: at(19, 11), session: 0, weekly: 5),    // +2
        ]
        let days = UsageHistory.dailyBurn(samples, days: 3, now: at(19, 20), calendar: utc)
        XCTAssertEqual(days, [4, 6, 5])
    }

    func testSessionFallbackWithoutWeekly() {
        let samples = [
            UsageSample(t: at(19, 9), session: 10, weekly: nil),
            UsageSample(t: at(19, 10), session: 25, weekly: nil),
        ]
        XCTAssertEqual(UsageHistory.dailyBurn(samples, days: 1, now: at(19, 20), calendar: utc), [15])
    }

    func testHourlyBurn() {
        let samples = [
            UsageSample(t: at(17, 10), session: 0, weekly: 1),  // old anchor outside the window
            UsageSample(t: at(19, 9), session: 0, weekly: 10),  // +9 lands at 11h ago
            UsageSample(t: at(19, 10), session: 0, weekly: 25), // +15 at 10h ago
            UsageSample(t: at(19, 19), session: 0, weekly: 28), // +3 at 1h ago
        ]
        let hours = UsageHistory.hourlyBurn(samples, hours: 24, now: at(19, 20))
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours[12], 9)   // 11 hours ago
        XCTAssertEqual(hours[13], 15)  // 10 hours ago
        XCTAssertEqual(hours[22], 3)   // 1 hour ago
        XCTAssertEqual(hours.reduce(0, +), 27)
    }

    func testBusiestBlock() {
        var samples: [UsageSample] = []
        var w = 0.0
        for h in [9, 14, 15, 16, 15, 14] {
            samples.append(UsageSample(t: at(19, h), session: nil, weekly: w))
            w += h >= 14 ? 3 : 0.5
        }
        // Too little signal → nil
        XCTAssertNil(UsageHistory.busiestBlock(Array(samples.prefix(2)), calendar: utc))
        XCTAssertEqual(UsageHistory.busiestBlock(samples, calendar: utc), 14)
    }

    func testBurnBetweenBounds() {
        // Task span 10:00–10:30: the +5 at exactly 10:30 counts, the +3
        // landing at 10:45 (post-task API lag) does not.
        let samples = [
            UsageSample(t: at(19, 10), session: 0, weekly: 10),
            UsageSample(t: at(19, 10, 15), session: 0, weekly: 14),
            UsageSample(t: at(19, 10, 30), session: 0, weekly: 19),
            UsageSample(t: at(19, 10, 45), session: 0, weekly: 22),
        ]
        XCTAssertEqual(UsageHistory.burnBetween(at(19, 10), at(19, 10, 30), in: samples), 9)
    }

    func testRecentBurnWindow() {
        let samples = [
            UsageSample(t: at(19, 8), session: 0, weekly: 40),
            UsageSample(t: at(19, 18), session: 0, weekly: 50),  // +10, 2h ago — outside
            UsageSample(t: at(19, 19, 40), session: 0, weekly: 56), // +6, 20m ago
            UsageSample(t: at(19, 19, 55), session: 0, weekly: 62), // +6, 5m ago
        ]
        XCTAssertEqual(UsageHistory.recentBurn(samples, within: 1800, now: at(19, 20)), 12)
        XCTAssertEqual(UsageHistory.recentBurn(samples, within: 6 * 3600, now: at(19, 20)), 22)
    }

    func testTaskStatsToday() {
        let spans = [
            TaskSpan(provider: "Claude", start: at(19, 9), end: at(19, 10)),
            TaskSpan(provider: "Claude", start: at(19, 11), end: at(19, 11, 30)),
            TaskSpan(provider: "Claude", start: at(18, 22), end: at(18, 23)), // yesterday
            TaskSpan(provider: "Codex", start: at(19, 9), end: at(19, 9, 20)),
        ]
        let (count, secs) = TaskStats.today(spans, provider: "Claude", now: at(19, 20), calendar: utc)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(secs, 5400, accuracy: 1)
    }

    func testTaskSpanAppendDropsBadAndOld() {
        var spans: [TaskSpan] = []
        XCTAssertFalse(TaskStats.append(
            TaskSpan(provider: "Claude", start: now, end: now.addingTimeInterval(-10)), to: &spans))
        XCTAssertFalse(TaskStats.append(
            TaskSpan(provider: "Claude", start: now.addingTimeInterval(-9 * 3600), end: now), to: &spans))
        XCTAssertTrue(TaskStats.append(
            TaskSpan(provider: "Claude", start: now.addingTimeInterval(-600), end: now), to: &spans))
        XCTAssertEqual(spans.count, 1)
        var old = [TaskSpan(provider: "Codex", start: now.addingTimeInterval(-9 * 86400),
                            end: now.addingTimeInterval(-9 * 86400 + 60))]
        XCTAssertTrue(TaskStats.append(
            TaskSpan(provider: "Codex", start: now.addingTimeInterval(-60), end: now), to: &old))
        XCTAssertEqual(old.count, 1) // the 9-day-old span dropped on append
    }

    func testBlockLabels() {
        XCTAssertEqual(UsageHistory.blockLabel(startHour: 14), "2–5 PM")
        XCTAssertEqual(UsageHistory.blockLabel(startHour: 10), "10 AM–1 PM")
        XCTAssertEqual(UsageHistory.blockLabel(startHour: 23), "11 PM–2 AM")
        XCTAssertEqual(UsageHistory.blockLabel(startHour: 0), "12–3 AM")
    }
}

final class DevinActivityTests: XCTestCase {
    typealias Row = DevinActivity.Row

    func testRunningToolKeepsTurnActiveThroughLongSilences() {
        let rows = [Row(kind: "tool_call", status: "in_progress"), Row(kind: "agent_thought")]
        XCTAssertTrue(DevinActivity.isActive(rows: rows, quietFor: 600))
        // A just-started tool call has no status yet.
        XCTAssertTrue(DevinActivity.isActive(rows: [Row(kind: "tool_call", status: nil)], quietFor: 120))
    }

    func testMidTurnToleratesThinkingGaps() {
        let rows = [Row(kind: "agent_thought"), Row(kind: "tool_call", status: "completed")]
        XCTAssertTrue(DevinActivity.isActive(rows: rows, quietFor: 30))
        XCTAssertFalse(DevinActivity.isActive(rows: rows, quietFor: 60))
    }

    func testFinalMessageEndsTurnSooner() {
        let rows = [Row(kind: "agent_message"), Row(kind: "tool_call", status: "completed")]
        XCTAssertTrue(DevinActivity.isActive(rows: rows, quietFor: 5))
        XCTAssertFalse(DevinActivity.isActive(rows: rows, quietFor: 25))
    }

    func testFailedToolDoesNotCountAsRunning() {
        let rows = [Row(kind: "agent_message"), Row(kind: "tool_call", status: "failed")]
        XCTAssertFalse(DevinActivity.isActive(rows: rows, quietFor: 30))
        XCTAssertFalse(DevinActivity.isActive(rows: [], quietFor: 0))
    }
}

final class VersionTests: XCTestCase {
    func testDottedCompare() {
        XCTAssertTrue(AppVersion.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(AppVersion.isNewer("1.1", than: "1.0.9"))
        XCTAssertFalse(AppVersion.isNewer("1.1", than: "1.1.0"))
        XCTAssertFalse(AppVersion.isNewer("1.0", than: "1.1"))
    }
}
