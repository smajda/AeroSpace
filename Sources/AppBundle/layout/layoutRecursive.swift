import AppKit

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws {
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        try await layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, LayoutContext(self))
    }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                try await workspace.rootTilingContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
                try await workspace.floatingWindowsContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .floatingWindowsContainer(let container):
                for window in container.children.filterIsInstance(of: Window.self) {
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    try await window.layoutFloatingWindow(context)
                }
            case .window(let window):
                if window.windowId != currentlyManipulatedWithMouseWindowId {
                    lastAppliedLayoutVirtualRect = virtual
                    if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                        lastAppliedLayoutPhysicalRect = nil
                        window.layoutFullscreen(context)
                    } else {
                        lastAppliedLayoutPhysicalRect = physicalRect
                        window.isFullscreen = false
                        window.setAxFrame(point, CGSize(width: width, height: height))
                    }
                }
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                switch container.layout {
                    case .tiles:
                        try await container.layoutTiles(point, width: width, height: height, virtual: virtual, context)
                    case .accordion:
                        try await container.layoutAccordion(point, width: width, height: height, virtual: virtual, context)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }
}

private struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps

    @MainActor
    init(_ workspace: Workspace) {
        self.workspace = workspace
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext) async throws {
        let workspace = context.workspace
        let windowRect = try await getAxRect(.cancellable) // Probably not idempotent
        let currentMonitor = windowRect?.center.monitorApproximation
        if let currentMonitor, let windowRect, workspace != currentMonitor.activeWorkspace {
            let windowTopLeftCorner = windowRect.topLeftCorner
            let xProportion = (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX) / currentMonitor.visibleRect.width
            let yProportion = (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY) / currentMonitor.visibleRect.height

            let workspaceRect = workspace.workspaceMonitor.visibleRect
            var newX = workspaceRect.topLeftX + xProportion * workspaceRect.width
            var newY = workspaceRect.topLeftY + yProportion * workspaceRect.height

            let windowWidth = windowRect.width
            let windowHeight = windowRect.height
            newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
            newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

            setAxFrame(CGPoint(x: newX, y: newY), nil)
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let monitorRect = noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitor.visibleRect
            : context.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        setAxFrame(monitorRect.topLeftCorner, CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}

extension TilingContainer {
    @MainActor
    fileprivate func layoutTiles(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        var point = point
        var virtualPoint = virtual.topLeftCorner

        guard let delta = ((orientation == .h ? width : height) - CGFloat(children.sumOfDouble { $0.getWeight(orientation) }))
            .div(children.count) else { return }

        let lastIndex = children.indices.last
        for (i, child) in children.enumerated() {
            child.setWeight(orientation, child.getWeight(orientation) + delta)
            let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
            // Gaps. Consider 4 cases:
            // 1. Multiple children. Layout first child
            // 2. Multiple children. Layout last child
            // 3. Multiple children. Layout child in the middle
            // 4. Single child   let rawGap = gaps.inner.get(orientation).toDouble()
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            try await child.layoutRecursive(
                i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? child.hWeight - gap : width,
                height: orientation == .v ? child.vWeight - gap : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? child.hWeight : width,
                    height: orientation == .v ? child.vWeight : height,
                ),
                context,
            )
            virtualPoint = orientation == .h ? virtualPoint.addingXOffset(child.hWeight) : virtualPoint.addingYOffset(child.vWeight)
            point = orientation == .h ? point.addingXOffset(child.hWeight) : point.addingYOffset(child.vWeight)
        }
    }

    /// Cascade accordion (`accordion-cascade`, also used by `accordion-rolodex`). Every card (child) peeks out by `accordion-padding`.
    /// Cards before the focused one peek out at the top (left), cards after it peek out at the bottom (right).
    /// In rolodex mode, the focused card is always the last one (see rotateRolodexAccordions), so all cards peek out at the top:
    ///
    ///     ┌ card 0 ─────────┐
    ///     ┌ card 1 ─────────┐
    ///     ┌ card 2 (focus) ─┐
    ///     │                 │
    ///     └─────────────────┘
    @MainActor
    fileprivate func layoutCascade(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        guard let mruIndex: Int = mostRecentChild?.ownIndex else { return }
        let padding = CGFloat(config.accordionPadding)
        let lastIndex = children.count - 1
        let length = orientation == .h ? width : height
        for (index, child) in children.enumerated() {
            let start = CGFloat(Swift.min(index, mruIndex)) * padding
            let end = length - CGFloat(lastIndex - Swift.max(index, mruIndex)) * padding
            switch orientation {
                case .h:
                    try await child.layoutRecursive(point + CGPoint(x: start, y: 0), width: end - start, height: height, virtual: virtual, context)
                case .v:
                    try await child.layoutRecursive(point + CGPoint(x: 0, y: start), width: width, height: end - start, virtual: virtual, context)
            }
        }
        if context.workspace.isVisible {
            try await raiseCascadeCards(mruIndex: mruIndex)
        }
    }

    /// Cards must overlap in the right z-order, otherwise the peeking parts are covered by other cards.
    /// Raise order (bottom to top): cards before the focused one in order, cards after it in reverse order, the focused card
    @MainActor
    private func raiseCascadeCards(mruIndex: Int) async throws {
        if children.count < 2 { return }
        let cardOrder = Array(children.indices.prefix(mruIndex)) + children.indices.suffix(from: mruIndex + 1).reversed() + [mruIndex]
        var windows: [Window] = []
        for cardIndex in cardOrder {
            let card = children[cardIndex]
            var cardWindows = card.allLeafWindowsRecursive
            if let mruWindow = card.mostRecentWindowRecursive, let i = cardWindows.firstIndex(of: mruWindow) {
                cardWindows.append(cardWindows.remove(at: i)) // The most recent window of the card goes on top
            }
            windows += cardWindows
        }
        let order = windows.map(\.windowId)
        if getUserData(key: cascadeRaisedOrderKey) == order { return } // Already in the right z-order. Avoid flicker
        // Remember the order only once all windows are raised. Refresh sessions are frequently cancelled (e.g. a new
        // window triggers a burst of AX notifications). If the order were remembered upfront, a session cancelled
        // in the middle of raising would leave the cards in a wrong z-order, and the next session would skip fixing it
        cleanUserData(key: cascadeRaisedOrderKey)
        cascadeRaiseInProgress += 1
        defer { cascadeRaiseInProgress -= 1 }
        for (i, window) in windows.enumerated() {
            await window.nativeRaise(makeMain: i == windows.indices.last) // Non-cancellable, the sequence always completes
        }
        putUserData(key: cascadeRaisedOrderKey, data: order)
    }

    @MainActor
    fileprivate func layoutAccordion(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        if config.accordionCascade || config.accordionRolodex {
            try await layoutCascade(point, width: width, height: height, virtual: virtual, context)
            return
        }
        guard let mruIndex: Int = mostRecentChild?.ownIndex else { return }
        for (index, child) in children.enumerated() {
            let padding = CGFloat(config.accordionPadding)
            let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                case 0 where children.count == 1: (0, 0)
                case 0:                           (0, padding)
                case children.indices.last:       (padding, 0)
                case mruIndex - 1:                (0, 2 * padding)
                case mruIndex + 1:                (2 * padding, 0)
                default:                          (padding, padding)
            }
            switch orientation {
                case .h:
                    try await child.layoutRecursive(
                        point + CGPoint(x: lPadding, y: 0),
                        width: width - rPadding - lPadding,
                        height: height,
                        virtual: virtual,
                        context,
                    )
                case .v:
                    try await child.layoutRecursive(
                        point + CGPoint(x: 0, y: lPadding),
                        width: width,
                        height: height - lPadding - rPadding,
                        virtual: virtual,
                        context,
                    )
            }
        }
    }
}

private let cascadeRaisedOrderKey = TreeNodeUserDataKey<[UInt32]>(key: "cascadeRaisedOrder")

/// While cascade cards are being raised, macOS may temporarily report one of the raised cards as the focused window.
/// Refresh sessions must not pick up that intermediate focus, otherwise focus would jump to the wrong card (and a rolodex stack would rotate to it)
@MainActor var cascadeRaiseInProgress = 0

@MainActor func waitForCascadeRaises() async {
    while cascadeRaiseInProgress > 0 {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
