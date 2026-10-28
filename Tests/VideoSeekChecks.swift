import Foundation

@main struct VideoSeekChecks {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; precondition(condition(), message)
        }
        let ranges = [SeekTimeRange(start: 10, end: 20), SeekTimeRange(start: 40, end: 60)]
        check(VideoSeekMath.target(seconds: 15, duration: 100, ranges: ranges) == 15, "Requested position inside a valid range remains unchanged")
        check(VideoSeekMath.target(seconds: 0, duration: 100, ranges: ranges) == 10, "Position before ranges clamps to nearest valid start")
        check(VideoSeekMath.target(seconds: 30, duration: 100, ranges: ranges) == 20, "Equal-distance gaps choose the earlier valid boundary")
        check(VideoSeekMath.target(seconds: 90, duration: 100, ranges: ranges) == 60, "Position after ranges clamps to nearest valid end")
        check(VideoSeekMath.target(seconds: 100, duration: 100, ranges: [.init(start: 0, end: 100)]) == 99.95, "Target never seeks into the final 50 milliseconds")
        check(VideoSeekMath.target(seconds: -5, duration: 100, ranges: [.init(start: -3, end: 12)]) == 0, "Valid ranges clamp to media bounds")
        check(VideoSeekMath.target(seconds: .nan, duration: 100, ranges: ranges) == nil, "Non-finite requested time is rejected")
        check(VideoSeekMath.target(seconds: 1, duration: .infinity, ranges: ranges) == nil, "Unknown or non-finite duration is rejected")
        check(VideoSeekMath.target(seconds: 1, duration: 0, ranges: ranges) == nil, "Zero duration is rejected")
        check(VideoSeekMath.target(seconds: 1, duration: 100, ranges: []) == nil, "No seek ranges means there is no valid seek target")
        check(VideoSeekMath.target(seconds: 1, duration: 100, ranges: [.init(start: .nan, end: 10), .init(start: 20, end: 10)]) == nil, "Malformed ranges are ignored and cannot produce a target")
        check(VideoSeekMath.target(seconds: 50, duration: 100, ranges: [.init(start: 101, end: 120), .init(start: -20, end: -1)]) == nil, "Ranges wholly outside media duration are rejected")
        let centerPlan = VideoSeekMath.interactivePlan(seconds: 15, duration: 100, ranges: ranges)
        check(centerPlan == .init(target: 15, toleranceBefore: 0.05, toleranceAfter: 0.05), "Interior plan allows 50 ms each side")
        let gapPlan = VideoSeekMath.interactivePlan(seconds: 30, duration: 100, ranges: ranges)
        check(gapPlan?.target == 20 && gapPlan?.toleranceBefore == 0.05 && gapPlan?.toleranceAfter == 0, "Gap endpoint tolerance cannot cross the gap")
        let narrowPlan = VideoSeekMath.interactivePlan(seconds: 2, duration: 10, ranges: [.init(start: 1.98, end: 2.01)])
        check(narrowPlan.map { abs($0.toleranceBefore - 0.02) < 1e-9 && abs($0.toleranceAfter - 0.01) < 1e-9 } == true, "Narrow interval limits both tolerances")
        let globalPlan = VideoSeekMath.interactivePlan(seconds: 100, duration: 100, ranges: [.init(start: 0, end: 100)])
        check(globalPlan?.target == 99.95 && globalPlan?.toleranceAfter == 0, "Global media end limits after tolerance")
        let pointPlan = VideoSeekMath.interactivePlan(seconds: 5, duration: 10, ranges: [.init(start: 5, end: 5)])
        check(pointPlan?.toleranceBefore == 0 && pointPlan?.toleranceAfter == 0, "Point interval has zero tolerance")
        check(VideoSeekMath.interactivePlan(seconds: .nan, duration: 10, ranges: ranges) == nil &&
              VideoSeekMath.interactivePlan(seconds: 1, duration: .infinity, ranges: ranges) == nil &&
              VideoSeekMath.interactivePlan(seconds: 1, duration: 10, ranges: []) == nil &&
              VideoSeekMath.interactivePlan(seconds: 1, duration: 10, ranges: [.init(start: .infinity, end: 5)]) == nil,
              "Invalid time, duration, or ranges yield no plan")
        for duration in [0.2, 1.0, 5.0, 20.0] {
            let upper = duration - 0.05
            guard upper > 0 else { continue }
            for startFraction in [0.0, 0.25, 0.8] {
                for widthFraction in [0.0, 0.03, 0.4, 1.0] {
                    let start = upper * startFraction
                    let end = min(upper, start + upper * widthFraction)
                    for requested in [0.0, start, (start + end) / 2, end, duration] {
                        if let plan = VideoSeekMath.interactivePlan(seconds: requested, duration: duration,
                                                                   ranges: [.init(start: start, end: end)]) {
                            check(plan.target >= 0 && plan.target <= upper &&
                                  plan.target - plan.toleranceBefore >= start &&
                                  plan.target + plan.toleranceAfter <= end &&
                                  plan.toleranceBefore >= 0 && plan.toleranceBefore <= 0.05 &&
                                  plan.toleranceAfter >= 0 && plan.toleranceAfter <= 0.05,
                                  "Property matrix preserves media and interval bounds")
                        }
                    }
                }
            }
        }
        check(VideoSeekMath.time(fraction: -0.2, duration: 100) == 0, "Fraction clamps at zero")
        check(VideoSeekMath.time(fraction: 1.2, duration: 100) == 99.95, "Fraction clamps before media end")
        check(VideoSeekMath.time(fraction: .infinity, duration: 100) == nil && VideoSeekMath.time(fraction: 0.5, duration: .nan) == nil, "Non-finite fractions and durations are rejected")
        check(VideoSeekMath.allowsHorizontalDrag(vx: 121, vy: 100), "Dominant horizontal movement is accepted")
        check(!VideoSeekMath.allowsHorizontalDrag(vx: 120, vy: 100), "Horizontal movement must exceed the vertical threshold")
        check(!VideoSeekMath.allowsHorizontalDrag(vx: 30, vy: 100) && !VideoSeekMath.allowsHorizontalDrag(vx: .nan, vy: 0), "Vertical or non-finite gestures are rejected")
        func verifyTickWindow(_ plan: VideoSeekMath.InteractiveTickPlan, ranges: [SeekTimeRange], duration: Double) -> Bool {
            let scale = Double(plan.timescale)
            let target = Double(plan.targetTicks) / scale
            let before = Double(plan.toleranceBeforeTicks) / scale
            let after = Double(plan.toleranceAfterTicks) / scale
            let low = target - before, high = target + after
            guard target >= 0, target <= duration - 0.05, before >= 0, after >= 0,
                  before <= 0.05, after <= 0.05 else { return false }
            return ranges.contains { $0.start <= low && high <= min($0.end, duration - 0.05) }
        }
        let decimalStartRange = [SeekTimeRange(start: 10.0004, end: 11)]
        let decimalStart = VideoSeekMath.interactiveTickPlan(seconds: 10.0004, duration: 20, ranges: decimalStartRange)
        check(decimalStart?.targetTicks == 600_024 && decimalStart.map { verifyTickWindow($0, ranges: decimalStartRange, duration: 20) } == true,
              "Inward-rounded tick target stays at or after a decimal range start")
        let decimalEndRange = [SeekTimeRange(start: 9, end: 10.00041)]
        let decimalEnd = VideoSeekMath.interactiveTickPlan(seconds: 10.00041, duration: 20, ranges: decimalEndRange)
        check(decimalEnd?.targetTicks == 600_024 && decimalEnd.map { verifyTickWindow($0, ranges: decimalEndRange, duration: 20) } == true,
              "Tick target and tolerance stay before a decimal range end")
        let gapTickRanges = [SeekTimeRange(start: 10, end: 20), .init(start: 40, end: 60)]
        let leftGap = VideoSeekMath.interactiveTickPlan(seconds: 30, duration: 100, ranges: gapTickRanges)
        let rightGap = VideoSeekMath.interactiveTickPlan(seconds: 30.1, duration: 100, ranges: gapTickRanges)
        check(leftGap?.targetTicks == 1_200_000 && leftGap?.toleranceAfterTicks == 0 &&
              rightGap?.targetTicks == 2_400_000 && rightGap?.toleranceBeforeTicks == 0,
              "Tick windows stop at both sides of a seekable gap")
        check(VideoSeekMath.interactiveTickPlan(seconds: 10.000001, duration: 20,
                                                ranges: [.init(start: 10.000001, end: 10.000002)]) == nil,
              "Subtick interval with no representable tick is rejected")
        check(VideoSeekMath.interactiveTickPlan(seconds: 10, duration: 20, ranges: [.init(start: 10, end: 10)])?.targetTicks == 600_000 &&
              VideoSeekMath.interactiveTickPlan(seconds: 10.00001, duration: 20,
                                                ranges: [.init(start: 10.00001, end: 10.00001)]) == nil,
              "Representable point intervals pass and unrepresentable points fail")
        check(VideoSeekMath.interactiveTickPlan(seconds: 1, duration: 10, ranges: ranges, timescale: 0) == nil &&
              VideoSeekMath.interactiveTickPlan(seconds: 1, duration: 10, ranges: ranges, timescale: -1) == nil &&
              VideoSeekMath.interactiveTickPlan(seconds: 1e20, duration: 1e20,
                                                ranges: [.init(start: 0, end: 1e20)], timescale: Int32.max) == nil,
              "Invalid timescale and tick overflow are rejected")
        for scale in [Int32(1), 100, 1_000, 60_000, 1_000_000] {
            for duration in [1.0, 10.0, 100.0] {
                let bound = duration - 0.05
                for range in [SeekTimeRange(start: 0.12345, end: min(bound, 0.98765)),
                              SeekTimeRange(start: 10.0004, end: min(bound, 10.9999))] where range.start <= range.end {
                    for requested in [0.0, range.start, (range.start + range.end) / 2, range.end, duration] {
                        if let plan = VideoSeekMath.interactiveTickPlan(seconds: requested, duration: duration,
                                                                        ranges: [range], timescale: scale) {
                            check(plan.timescale == scale && verifyTickWindow(plan, ranges: [range], duration: duration),
                                  "Multi-scale tick window stays inside original bounds")
                        }
                    }
                }
            }
        }
        print("VideoSeekChecks: \(checks) local math assertions passed")
    }
}
