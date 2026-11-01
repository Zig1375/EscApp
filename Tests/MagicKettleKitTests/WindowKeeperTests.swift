import Foundation
@testable import MagicKettleKit
import Testing

@Suite struct WindowKeeperTests {
    /// The keeper ships inside MagicKettleKit as a 64-bit Windows program (`scripts/build-window-keeper.sh`).
    @Test func theKeeperShipsWithMagicKettle() throws {
        let program = try #require(WindowKeeper.program)
        let info = try ExecutableInfo.read(program)
        #expect(info.format == .pe64)
        #expect(info.imports.contains("user32.dll"))
    }
}
