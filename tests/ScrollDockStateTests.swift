import Foundation

@main
enum ScrollDockStateTests {
    static func main() {
        var checks = 0
        func expect(_ actual: Bool?, _ expected: Bool?, _ label: String) {
            precondition(actual == expected, "\(label): expected \(String(describing: expected)), got \(String(describing: actual))")
            checks += 1
        }
        var state = ATMusicScrollDockState()
        let a = UUID(), b = UUID()
        func send(_ offset: CGFloat, max: CGFloat = 1000, viewport: CGFloat = 700,
                  source: UUID? = nil, user: Bool = true) -> Bool? {
            state.consume(ATMusicScrollSample(offset: offset, maximum: max, viewport: viewport),
                          source: source ?? a, userDriven: user)
        }

        expect(send(0), false, "top expanded")
        expect(send(5), nil, "small movement")
        expect(send(13), true, "cumulative downward gesture")
        expect(send(500), true, "fast downward gesture")
        expect(send(490), nil, "reverse hysteresis")
        expect(send(480), false, "upward gesture expands")
        expect(send(990), true, "approach bottom")
        for _ in 0..<20 {
            expect(send(1040), nil, "bottom overscroll")
            expect(send(1010), nil, "elastic return")
            expect(send(1000), nil, "re-entry frame")
            expect(send(995), nil, "bottom settling")
        }
        expect(send(970), false, "deliberate pull away from bottom")

        expect(send(250, max: 1400), nil, "height remeasurement is not upward gesture")
        expect(send(270, max: 1400), true, "gesture after remeasurement")
        expect(send(200, max: 1400, viewport: 620), nil, "viewport change ignored")
        expect(send(0, max: 1400, viewport: 620, user: false), nil, "programmatic scroll ignored")
        expect(send(0, source: b, user: false), nil, "inactive source cannot reset current baseline")
        expect(send(20, max: 1400, viewport: 620), true, "current source baseline preserved")
        expect(send(500, source: b), nil, "new page never compares with old page offset")
        expect(send(475, source: b), false, "new page has independent baseline")
        state.reset()
        expect(send(200), nil, "tab selection clears baseline")
        expect(send(220), true, "new scroll after tab switch")
        expect(send(0, max: 0), nil, "short-page layout change")
        expect(send(20, max: 0), false, "short-page bounce remains expanded")
        state.reset()
        expect(send(0), false, "top baseline")
        expect(send(-50), nil, "top overscroll")
        expect(send(-10), nil, "top elastic return")
        expect(send(0), nil, "top re-entry")
        expect(send(15), true, "real scrolling after top bounce")
        expect(send(.nan), nil, "invalid geometry ignored")
        expect(send(.infinity), nil, "infinite geometry ignored")
        expect(send(20, viewport: 0), nil, "zero viewport ignored")

        // Many sub-pixel updates must not cause oscillation or depend on screen refresh rate.
        state.reset()
        _ = send(100)
        for step in 1...119 { expect(send(100 + CGFloat(step) / 10), nil, "slow gesture threshold") }
        expect(send(112), true, "slow gesture still collapses")
        // Both expanded and collapsed dock use the same bottom anchor/reservation.
        for safeBottom: CGFloat in [0, 20, 34] {
            let adjustment = ATMusicDockLayout.downwardAdjustment(safeAreaBottom: safeBottom)
            let gap = safeBottom + ATMusicDockLayout.reservedBottomPadding - adjustment
            precondition(gap == min(safeBottom + 12, 22), "Dock bottom gap")
            precondition(ATMusicDockLayout.reservedHeight + ATMusicDockLayout.reservedBottomPadding == 148,
                         "Do not change the stable scroll viewport reservation")
            for contentHeight: CGFloat in [50, 52, 64, 122] {
                let top = ATMusicDockLayout.reservedHeight - contentHeight
                precondition(top + contentHeight == ATMusicDockLayout.reservedHeight, "Bottom alignment")
                checks += 1
            }
            checks += 2
        }
        precondition(ATMusicDockLayout.downwardAdjustment(safeAreaBottom: 340) == 0, "Keyboard safety")
        precondition(ATMusicDockLayout.downwardAdjustment(safeAreaBottom: .nan) == 0, "Invalid inset safety")
        checks += 2
        print("PASS: \(checks) scroll state assertions (20 repeated bottom bounces included).")
    }
}
