import ExePortKit
import Testing

@Suite struct GameScalingTests {
    let screen = GameScaling.Size(width: 3024, height: 1890)

    func window(_ width: Int, _ height: Int, grows: Bool = false) -> GameScaling.Window {
        GameScaling.Window(size: .init(width: width, height: height), canGrowByItself: grows)
    }

    @Test func smallFixedWindowGetsSharpWholeMultiple() {
        let decision = GameScaling.decide(setting: .auto, window: window(640, 480), screen: screen)
        #expect(decision == .init(filter: .sharpPixels, scale: 3))
    }

    @Test func largerWindowIsSmoothedToFit() {
        let decision = GameScaling.decide(setting: .on, window: window(1280, 720), screen: screen)
        #expect(decision?.filter == .smooth)
        #expect(decision?.scale == 3024.0 / 1280.0)
    }

    @Test func autoLeavesResizableGamesAlone() {
        #expect(GameScaling.decide(setting: .auto, window: window(640, 480, grows: true), screen: screen) == nil)
    }

    @Test func autoSkipsLatencySensitiveGames() {
        #expect(GameScaling.decide(setting: .auto, window: window(640, 480), screen: screen,
                                   latencySensitive: true) == nil)
    }

    @Test func autoSkipsWindowsTallerThanHalfTheScreen() {
        #expect(GameScaling.decide(setting: .auto, window: window(1600, 1000), screen: screen) == nil)
        #expect(GameScaling.decide(setting: .on, window: window(1600, 1000), screen: screen) != nil)
    }

    @Test func onScalesEvenResizableGames() {
        #expect(GameScaling.decide(setting: .on, window: window(640, 480, grows: true), screen: screen) != nil)
    }

    @Test func offAndFullSizeNeverScale() {
        #expect(GameScaling.decide(setting: .off, window: window(640, 480), screen: screen) == nil)
        #expect(GameScaling.decide(setting: .on, window: window(3024, 1890), screen: screen) == nil)
    }
}
