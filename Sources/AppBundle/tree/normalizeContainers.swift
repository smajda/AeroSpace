extension Workspace {
    @MainActor func normalizeContainers() {
        rootTilingContainer.unbindEmptyAndAutoFlatten() // Beware! rootTilingContainer may change after this line of code
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            rootTilingContainer.normalizeOppositeOrientationForNestedContainers()
        }
        if config.accordionRolodex {
            rootTilingContainer.rotateRolodexAccordions()
        }
    }
}

extension TilingContainer {
    /// Rolodex accordion: the most recent (focused) child is always the last one (the frontmost card).
    /// Any focus change (command, mouse click, focus by window id) is turned into a rotation of the stack
    @MainActor fileprivate func rotateRolodexAccordions() {
        if layout == .accordion, let mru = mostRecentChild {
            rotateChildren(makeLast: mru)
        }
        for child in children {
            (child as? TilingContainer)?.rotateRolodexAccordions()
        }
    }
}

extension TilingContainer {
    @MainActor fileprivate func unbindEmptyAndAutoFlatten() {
        if let child = children.singleOrNil(), config.enableNormalizationFlattenContainers && (child is TilingContainer || !isRootContainer) {
            child.unbindFromParent()
            let mru = parent?.mostRecentChild
            let previousBinding = unbindFromParent()
            child.bind(to: previousBinding.parent, adaptiveWeight: previousBinding.adaptiveWeight, index: previousBinding.index)
            (child as? TilingContainer)?.unbindEmptyAndAutoFlatten()
            if mru != self {
                mru?.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
        } else {
            for child in children {
                (child as? TilingContainer)?.unbindEmptyAndAutoFlatten()
            }
            if children.isEmpty && !isRootContainer {
                unbindFromParent()
            }
        }
    }
}
