@testable import AppBundle
import Common
import XCTest

@MainActor
final class StackNewWindowsTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.stackNewWindows = true
    }

    /// Simulates a new window being opened (the same way MacWindow.getOrRegister places it)
    @discardableResult
    private func openNewWindow(id: UInt32, _ workspace: Workspace, isNewWindow: Bool = true) -> TestWindow {
        let data = unbindAndGetBindingDataForNewTilingWindow(workspace, window: nil, isNewWindow: isNewWindow)
        return TestWindow.new(id: id, parent: data.parent, adaptiveWeight: data.adaptiveWeight)
            .also { $0.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index) }
    }

    private func setUpTwoColumns() -> Workspace {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TilingContainer(parent: $0, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST).apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
            }
            assertEquals(TestWindow.new(id: 3, parent: $0).focusWindow(), true)
        }
        return workspace
    }

    func testNewWindowNextToLoneTileFormsAStack() {
        let workspace = setUpTwoColumns()
        openNewWindow(id: 4, workspace)
        assertEquals(workspace.layoutDescription, .workspace([
            .h_tiles([
                .v_accordion([.window(1), .window(2)]),
                .v_accordion([.window(3), .window(4)]),
            ]),
        ]))
    }

    func testNewWindowJoinsExistingStackAfterFocusedWindow() {
        let workspace = setUpTwoColumns()
        assertEquals(Window.get(byId: 1)?.focusWindow(), true)
        openNewWindow(id: 4, workspace)
        assertEquals(workspace.layoutDescription, .workspace([
            .h_tiles([
                .v_accordion([.window(1), .window(4), .window(2)]),
                .window(3),
            ]),
        ]))
    }

    func testDisabledOpensNewTile() {
        config.stackNewWindows = false
        let workspace = setUpTwoColumns()
        openNewWindow(id: 4, workspace)
        assertEquals(workspace.layoutDescription, .workspace([
            .h_tiles([
                .v_accordion([.window(1), .window(2)]),
                .window(3),
                .window(4),
            ]),
        ]))
    }

    func testNotNewWindowOpensNewTile() { // e.g. `layout tiling` on a floating window, or windows detected at startup
        let workspace = setUpTwoColumns()
        openNewWindow(id: 4, workspace, isNewWindow: false)
        assertEquals(workspace.layoutDescription, .workspace([
            .h_tiles([
                .v_accordion([.window(1), .window(2)]),
                .window(3),
                .window(4),
            ]),
        ]))
    }
}
