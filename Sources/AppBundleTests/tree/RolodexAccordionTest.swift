@testable import AppBundle
import Common
import XCTest

@MainActor
final class RolodexAccordionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.accordionRolodex = true
    }

    private func setUpStack() -> (Workspace, TilingContainer) {
        let workspace = Workspace.get(byName: name)
        let stack = workspace.rootTilingContainer
        stack.layout = .accordion
        stack.changeOrientation(.v)
        TestWindow.new(id: 1, parent: stack)
        TestWindow.new(id: 2, parent: stack)
        assertEquals(TestWindow.new(id: 3, parent: stack).focusWindow(), true)
        return (workspace, stack)
    }

    private func cardIds(_ container: TilingContainer) -> [UInt32] {
        container.children.map { ($0 as! Window).windowId }
    }

    func testFocusingACardTurnsTheStackToBringItToTheFront() {
        let (workspace, stack) = setUpStack()
        assertEquals(Window.get(byId: 1)?.focusWindow(), true)
        workspace.normalizeContainers()
        assertEquals(cardIds(stack), [2, 3, 1])
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testFocusUpBringsTheNextCardToTheFront() async throws {
        let (workspace, stack) = setUpStack()
        try await FocusCommand.new(direction: .up).run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(cardIds(stack), [3, 1, 2])
        assertEquals(focus.windowOrNil?.windowId, 2)

        try await FocusCommand.new(direction: .up).run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(cardIds(stack), [2, 3, 1])
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testFocusDownBringsTheBackmostCardToTheFront() async throws {
        let (workspace, stack) = setUpStack()
        try await FocusCommand.new(direction: .down).run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(cardIds(stack), [2, 3, 1])
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testFocusAcrossTheStackStillLeavesIt() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer(parent: $0, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST).apply {
                TestWindow.new(id: 2, parent: $0)
                assertEquals(TestWindow.new(id: 3, parent: $0).focusWindow(), true)
            }
        }
        try await FocusCommand.new(direction: .left).run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testCascadeAccordionDoesNotTurn() async throws {
        config.accordionRolodex = false
        config.accordionCascade = true
        let (workspace, stack) = setUpStack()
        assertEquals(Window.get(byId: 1)?.focusWindow(), true)
        workspace.normalizeContainers()
        assertEquals(cardIds(stack), [1, 2, 3])

        try await FocusCommand.new(direction: .down).run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(cardIds(stack), [1, 2, 3])
        assertEquals(focus.windowOrNil?.windowId, 2)
    }

    func testClassicAccordionDoesNotTurn() {
        config.accordionRolodex = false
        let (workspace, stack) = setUpStack()
        assertEquals(Window.get(byId: 1)?.focusWindow(), true)
        workspace.normalizeContainers()
        assertEquals(cardIds(stack), [1, 2, 3])
    }
}
