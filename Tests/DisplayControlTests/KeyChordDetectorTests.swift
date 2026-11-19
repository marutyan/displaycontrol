import Testing
@testable import DisplayControl

@Suite("輝度キーの判定")
struct KeyChordDetectorTests {
    @Test("単押しは離した時点で待たずに確定する")
    func singlePressResolvesOnRelease() {
        var d = KeyChordDetector(chordWindow: 0.075)
        #expect(d.press(.up, shift: false, isRepeat: false, at: 0) == [])
        #expect(d.deadline == 0.075)
        #expect(d.release(.up, at: 0.03) == [.step(1)])
        #expect(d.deadline == nil)
        #expect(d.expire(at: 1) == [])
    }

    @Test("押し続けると期限で確定し、リピートは段階変化になる")
    func holdResolvesOnDeadline() {
        var d = KeyChordDetector(chordWindow: 0.075)
        _ = d.press(.down, shift: false, isRepeat: false, at: 0)
        #expect(d.expire(at: 0.05) == [])
        #expect(d.expire(at: 0.075) == [.step(-1)])
        #expect(d.press(.down, shift: false, isRepeat: true, at: 0.5) == [.step(-1)])
        #expect(d.release(.down, at: 0.6) == [])
    }

    @Test("期限内の上下同時押しは揃えるだけで、段階変化を出さない")
    func chordMatchesOnceWithoutStep() {
        var d = KeyChordDetector(chordWindow: 0.075)
        #expect(d.press(.up, shift: false, isRepeat: false, at: 0) == [])
        #expect(d.press(.down, shift: false, isRepeat: false, at: 0.02) == [.match])
        // 押し続けのリピートや片方の再押下では再度揃えない。
        #expect(d.press(.up, shift: false, isRepeat: true, at: 0.5) == [])
        #expect(d.press(.down, shift: false, isRepeat: true, at: 0.5) == [])
        #expect(d.release(.up, at: 0.6) == [])
        #expect(d.press(.up, shift: false, isRepeat: false, at: 0.7) == [])
        #expect(d.release(.up, at: 0.8) == [])
        #expect(d.release(.down, at: 0.9) == [])
        #expect(d.expire(at: 2) == [])
        // 両方離した後は次の組で再び揃えられる。
        _ = d.press(.down, shift: false, isRepeat: false, at: 3)
        #expect(d.press(.up, shift: false, isRepeat: false, at: 3.01) == [.match])
    }

    @Test("Shift 付きは初回の押下で Primary を切り替え、同じキーのリピートは無視する")
    func shiftCyclesPrimary() {
        var d = KeyChordDetector()
        #expect(d.press(.up, shift: true, isRepeat: false, at: 0) == [.cyclePrimary(1)])
        #expect(d.deadline == nil)
        #expect(d.release(.up, at: 0.01) == [])
        #expect(d.press(.down, shift: true, isRepeat: false, at: 1) == [.cyclePrimary(-1)])
        #expect(d.press(.down, shift: true, isRepeat: true, at: 1.5) == [])
        // Shift を先に離しても、そのキーを離すまでリピートで段階変化にしない。
        #expect(d.press(.down, shift: false, isRepeat: true, at: 1.6) == [])
        #expect(d.release(.down, at: 2) == [])
        #expect(d.expire(at: 3) == [])
    }

    @Test("期限切れで確定した後の反対キーは揃えずに普通の操作になる")
    func latePressIsNotChord() {
        var d = KeyChordDetector(chordWindow: 0.075)
        _ = d.press(.up, shift: false, isRepeat: false, at: 0)
        #expect(d.expire(at: 0.075) == [.step(1)])
        // 上を押したまま 75ms の外で下を押す。
        #expect(d.press(.down, shift: false, isRepeat: false, at: 0.3) == [])
        #expect(d.release(.down, at: 0.32) == [.step(-1)])
        #expect(d.release(.up, at: 0.4) == [])
    }

    @Test("タイマーが遅れても入力時刻で期限を判定する")
    func lateTimerUsesInputTime() {
        var d = KeyChordDetector(chordWindow: 0.075)
        _ = d.press(.up, shift: false, isRepeat: false, at: 0)
        // 期限の確定より先に、期限後の反対キーが届いた場合。
        #expect(d.press(.down, shift: false, isRepeat: false, at: 0.2) == [.step(1)])
        #expect(d.expire(at: 0.275) == [.step(-1)])
        #expect(d.release(.down, at: 0.3) == [])
        #expect(d.release(.up, at: 0.3) == [])
        // 期限ちょうど手前なら同時押し。
        _ = d.press(.down, shift: false, isRepeat: false, at: 1)
        #expect(d.press(.up, shift: false, isRepeat: false, at: 1.074) == [.match])
    }

    @Test("Shift が混ざった上下押しは揃えず、それぞれの操作になる")
    func shiftMixedIsNotChord() {
        var d = KeyChordDetector(chordWindow: 0.075)
        // Shift なしの保留中に Shift 付きの反対キー。
        _ = d.press(.up, shift: false, isRepeat: false, at: 0)
        #expect(d.press(.down, shift: true, isRepeat: false, at: 0.02) == [.step(1), .cyclePrimary(-1)])
        #expect(d.release(.up, at: 0.05) == [])
        #expect(d.release(.down, at: 0.05) == [])
        // Shift 付きで押した後に Shift なしの反対キー。
        #expect(d.press(.up, shift: true, isRepeat: false, at: 1) == [.cyclePrimary(1)])
        #expect(d.press(.down, shift: false, isRepeat: false, at: 1.02) == [])
        #expect(d.release(.down, at: 1.03) == [.step(-1)])
        #expect(d.release(.up, at: 1.04) == [])
    }

    @Test("解放を取りこぼした後の再押下は保留分を確定してから扱う")
    func missedReleaseDoesNotFakeChord() {
        var d = KeyChordDetector()
        _ = d.press(.up, shift: false, isRepeat: false, at: 0)
        #expect(d.press(.up, shift: false, isRepeat: false, at: 0.03) == [.step(1)])
        d.reset()
        #expect(d.held.isEmpty)
        _ = d.press(.down, shift: false, isRepeat: false, at: 1)
        #expect(d.release(.down, at: 1.01) == [.step(-1)])
    }

    @Test("systemDefined の data1 を輝度キーとして解釈する")
    func parsesSystemDefinedData() {
        let upDown = (2 << 16) | (0x0A << 8)
        #expect(BrightnessKeyEvent.parse(subtype: 8, data1: upDown)
            == BrightnessKeyEvent(key: .up, isDown: true, isRepeat: false))
        let downRepeat = (3 << 16) | (0x0A << 8) | 1
        #expect(BrightnessKeyEvent.parse(subtype: 8, data1: downRepeat)
            == BrightnessKeyEvent(key: .down, isDown: true, isRepeat: true))
        let downUp = (3 << 16) | (0x0B << 8)
        #expect(BrightnessKeyEvent.parse(subtype: 8, data1: downUp)
            == BrightnessKeyEvent(key: .down, isDown: false, isRepeat: false))
        // 音量キーや別サブタイプは扱わない。
        #expect(BrightnessKeyEvent.parse(subtype: 8, data1: (0 << 16) | (0x0A << 8)) == nil)
        #expect(BrightnessKeyEvent.parse(subtype: 7, data1: upDown) == nil)
    }
}
