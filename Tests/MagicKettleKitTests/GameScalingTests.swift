import CoreGraphics
import MagicKettleKit
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

    // MARK: At launch

    let mac = GameScaling.Size(width: 1728, height: 1056)

    @Test func aSmallWindowSeenLastTimeIsEnlargedByAWholeNumber() {
        let learned = GameScaling.LearnedWindow(width: 640, height: 508, fullScreen: false)
        #expect(GameScaling.scale(setting: .auto, learned: learned, dpiAware: false, screen: mac) == 2)
        #expect(GameScaling.dpi(for: 2) == 192)
        #expect(GameScaling.dpi(for: 1) == 96)
    }

    @Test func nothingIsEnlargedWithoutReason() {
        let small = GameScaling.LearnedWindow(width: 640, height: 508, fullScreen: false)
        // Never seen: the size isn't known yet.
        #expect(GameScaling.scale(setting: .on, learned: nil, dpiAware: false, screen: mac) == 1)
        // Full screen: Wine fits it to the screen itself.
        let full = GameScaling.LearnedWindow(width: 1728, height: 1117, fullScreen: true)
        #expect(GameScaling.scale(setting: .on, learned: full, dpiAware: false, screen: mac) == 1)
        // It draws for Retina itself.
        #expect(GameScaling.scale(setting: .on, learned: small, dpiAware: true, screen: mac) == 1)
        #expect(GameScaling.scale(setting: .off, learned: small, dpiAware: false, screen: mac) == 1)
        // Already more than half the screen high: Auto leaves it, On still fills it.
        let large = GameScaling.LearnedWindow(width: 1024, height: 768, fullScreen: false)
        #expect(GameScaling.scale(setting: .auto, learned: large, dpiAware: false, screen: mac) == 1)
        #expect(GameScaling.scale(setting: .on, learned: large, dpiAware: false, screen: mac) > 1.3)
    }

    @Test func theWindowIsLearnedInTheGamesOwnPixels() {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let enlarged = GameScaling.learn(frame: CGRect(x: 100, y: 100, width: 1280, height: 1016), display: display,
                                         scale: 2)
        #expect(enlarged == GameScaling.LearnedWindow(width: 640, height: 508, fullScreen: false))
        #expect(GameScaling.learn(frame: display, display: display, scale: 1).fullScreen)
        #expect(GameScaling.availableScreen(display: display) == GameScaling.Size(width: 1728, height: 1056))
    }
}
