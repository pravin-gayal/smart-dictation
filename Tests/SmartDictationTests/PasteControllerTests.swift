import XCTest
import AppKit
@testable import SmartDictationLib

@MainActor
final class PasteControllerTests: XCTestCase {

    var controller: PasteController!

    override func setUp() {
        super.setUp()
        controller = PasteController()
    }

    // MARK: - 1. Clipboard restored to original after paste

    func testClipboardRestoredAfterPaste() async throws {
        // Arrange: set a known value on the pasteboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("original", forType: .string)

        // Act
        await controller.paste("new text", into: nil)

        // Assert: pasteboard should be restored to "original"
        let restored = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(restored, "original", "Pasteboard should be restored to original value after paste")
    }

    // MARK: - 2. Empty pasteboard — no crash, acceptable end state

    func testEmptyClipboardBeforePaste() async throws {
        // Arrange: clear the pasteboard so there's nothing to restore
        NSPasteboard.general.clearContents()

        // Act — should not crash
        await controller.paste("new text", into: nil)

        // Assert: since there was nothing saved, the spec says
        // "leave pasted text on pasteboard or clear it — acceptable either way"
        // We just verify no crash and the function completes.
        // (The implementation leaves "new text" on pasteboard when savedString is nil)
    }

    // MARK: - 3. Paste writes target text to pasteboard before restore

    func testPasteWritesTextToClipboardBeforeRestore() async throws {
        // We can't easily observe the intermediate state during the async sleep,
        // but we can verify that when there was no prior content, the paste value
        // is visible right after calling paste (since nothing was saved to restore).
        NSPasteboard.general.clearContents()

        await controller.paste("interim text", into: nil)

        // With no prior saved string, implementation does NOT clear — "interim text" remains.
        // This confirms the write step ran.
        let current = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(current, "interim text",
            "When no prior pasteboard content exists, pasted text should remain after paste()")
    }

    // MARK: - 4. Multiple sequential pastes restore correctly

    func testSequentialPastesRestoreCorrectly() async throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("step1", forType: .string)

        await controller.paste("injected1", into: nil)
        let after1 = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(after1, "step1")

        // Change the pasteboard between pastes
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("step2", forType: .string)

        await controller.paste("injected2", into: nil)
        let after2 = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(after2, "step2")
    }
}
