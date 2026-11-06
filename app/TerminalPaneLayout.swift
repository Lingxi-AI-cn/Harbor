import AppKit

enum PaneDirection: String, Codable { case left, right, up, down }

indirect enum PaneLayoutSnapshot: Codable, Equatable {
    case leaf(UUID)
    case split(PaneDirection, Double, PaneLayoutSnapshot, PaneLayoutSnapshot)
    var ids: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_,_,let first,let second): return first.ids + second.ids
        }
    }
    func valid(depth: Int = 0) -> Bool {
        guard depth < 32 else { return false }
        switch self {
        case .leaf: return true
        case .split(_,let ratio,let first,let second):
            return ratio.isFinite && (0.05...0.95).contains(ratio) && first.valid(depth:depth+1) && second.valid(depth:depth+1)
        }
    }
    func remapping(_ ids: [UUID:UUID]) -> PaneLayoutSnapshot {
        switch self {
        case .leaf(let id): return .leaf(ids[id] ?? id)
        case .split(let direction,let ratio,let first,let second):
            return .split(direction,ratio,first.remapping(ids),second.remapping(ids))
        }
    }
}

/// Owns layout only. Sessions and their asynchronous shutdown remain with the host.
final class TerminalPaneLayout: NSView, NSSplitViewDelegate {
    private final class Node {
        let id: UUID
        var leaf: NSView?
        var direction: PaneDirection = .right
        var first: Node?
        var second: Node?
        var ratio: CGFloat = 0.5
        weak var split: NSSplitView?
        init(id: UUID = UUID(), leaf: NSView) { self.id = id; self.leaf = leaf }
        init(direction: PaneDirection, first: Node, second: Node) {
            id = UUID(); self.direction = direction; self.first = first; self.second = second
        }
        var leaves: [UUID] { leaf != nil ? [id] : (first?.leaves ?? []) + (second?.leaves ?? []) }
        func find(_ id: UUID) -> Node? { self.id == id ? self : first?.find(id) ?? second?.find(id) }
    }
    private var root: Node?
    private var arranging = false
    private(set) var focusedID: UUID?
    var onFocusRequested: ((UUID) -> Void)?
    var paneIDs: [UUID] { root?.leaves ?? [] }
    func snapshot() -> PaneLayoutSnapshot? {
        captureRatios(root)
        func encode(_ node: Node) -> PaneLayoutSnapshot {
            if node.leaf != nil { return .leaf(node.id) }
            return .split(node.direction,Double(node.ratio),encode(node.first!),encode(node.second!))
        }
        return root.map(encode)
    }
    /// Validate the entire tree before detaching any live view.
    @discardableResult func restore(_ snapshot: PaneLayoutSnapshot, views: [UUID:NSView], focused: UUID?) -> Bool {
        guard snapshot.valid() else { return false }
        let ids = snapshot.ids
        guard ids.count <= 64, Set(ids).count == ids.count, Set(ids) == Set(views.keys),
              Set(views.values.map(ObjectIdentifier.init)).count == ids.count else { return false }
        func decode(_ tree: PaneLayoutSnapshot) -> Node {
            switch tree {
            case .leaf(let id): return Node(id:id,leaf:views[id]!)
            case .split(let direction,let ratio,let first,let second):
                let node = Node(direction:direction,first:decode(first),second:decode(second))
                node.ratio = CGFloat(ratio); return node
            }
        }
        root = decode(snapshot); focusedID = focused.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        rebuild(); return true
    }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        guard let focusedID, let view = root?.find(focusedID)?.leaf else { return false }
        return window?.makeFirstResponder(view) ?? false
    }
    @discardableResult func setInitial(_ view: NSView, id: UUID = UUID()) -> UUID {
        precondition(root == nil, L("Initial pane can only be set on an empty layout"))
        root = Node(id:id,leaf:view); focusedID = id; rebuild(); return id
    }
    func markFocused(_ id: UUID) {
        guard paneIDs.contains(id) else { return }; focusedID = id
    }
    func requestFocus(_ id: UUID) {
        guard let view = root?.find(id)?.leaf else { return }
        focusedID = id; window?.makeFirstResponder(view); onFocusRequested?(id)
    }
    @discardableResult func split(_ id: UUID, with view: NSView, direction: PaneDirection, newID: UUID = UUID()) -> Bool {
        guard let node = root?.find(id), node.leaf != nil, !paneIDs.contains(newID),
              !paneIDs.contains(where: { root?.find($0)?.leaf === view }) else { return false }
        captureRatios(root)
        let fresh = Node(id:newID,leaf:view)
        let branch = direction == .left || direction == .up
            ? Node(direction:direction,first:fresh,second:node)
            : Node(direction:direction,first:node,second:fresh)
        root = replacing(root, id:id, with:branch)
        focusedID = newID; rebuild(); requestFocus(newID); return true
    }
    /// Collapse the empty branch and keep the nearest surviving sibling focused.
    @discardableResult func remove(_ id: UUID) -> NSView? {
        guard let removed = root?.find(id)?.leaf else { return nil }
        captureRatios(root)
        let order = paneIDs, oldIndex = order.firstIndex(of:id)!
        root = removing(root,id:id)
        removed.removeFromSuperview()
        if focusedID == id { focusedID = paneIDs.isEmpty ? nil : paneIDs[min(oldIndex,paneIDs.count - 1)] }
        rebuild()
        if let focusedID { requestFocus(focusedID) }
        return removed
    }
    func equalize() {
        func reset(_ node: Node?) { guard let node else { return }; node.ratio = 0.5; reset(node.first); reset(node.second) }
        reset(root); needsLayout = true; layoutSubtreeIfNeeded()
    }
    func focusNext(backwards: Bool = false) {
        let ids = paneIDs; guard !ids.isEmpty else { return }
        let index = focusedID.flatMap { ids.firstIndex(of:$0) } ?? 0
        requestFocus(ids[(index + (backwards ? ids.count - 1 : 1)) % ids.count])
    }
    func focus(from id: UUID, direction: PaneDirection) {
        guard let origin = paneFrame(id) else { return }
        let candidates = paneIDs.filter { $0 != id }.compactMap { candidate -> (UUID,CGFloat)? in
            guard let frame = paneFrame(candidate) else { return nil }
            let dx = frame.midX - origin.midX, dy = frame.midY - origin.midY
            let forward: CGFloat, cross: CGFloat
            switch direction {
            case .left: forward = -dx; cross = abs(dy)
            case .right: forward = dx; cross = abs(dy)
            case .up: forward = dy; cross = abs(dx)
            case .down: forward = -dy; cross = abs(dx)
            }
            guard forward > 1 else { return nil }
            return (candidate,forward + cross*2)
        }
        if let target = candidates.min(by:{ $0.1 < $1.1 }) { requestFocus(target.0) }
    }
    func resize(from id: UUID, direction: PaneDirection, amount: CGFloat) {
        guard amount.isFinite, amount > 0 else { return }
        let vertical = direction == .left || direction == .right
        func ancestor(_ node: Node?) -> Node? {
            guard let node, node.leaves.contains(id), node.leaf == nil else { return nil }
            return ancestor(node.first) ?? ancestor(node.second) ?? ((node.direction == .left || node.direction == .right) == vertical ? node : nil)
        }
        guard let node = ancestor(root), let split = node.split else { return }
        captureRatios(root)
        let length = (vertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
        guard length > 0 else { return }
        let delta = direction == .left || direction == .up ? -amount : amount
        node.ratio = min(0.95,max(0.05,node.ratio + delta/length))
        needsLayout = true; layoutSubtreeIfNeeded(); captureRatios(root)
    }
    func paneFrame(_ id: UUID) -> NSRect? { root?.find(id)?.leaf.map { $0.convert($0.bounds,to:self) } }
    private func replacing(_ node: Node?, id: UUID, with replacement: Node) -> Node? {
        guard let node else { return nil }; if node.id == id { return replacement }
        node.first = replacing(node.first,id:id,with:replacement); node.second = replacing(node.second,id:id,with:replacement); return node
    }
    private func removing(_ node: Node?, id: UUID) -> Node? {
        guard let node else { return nil }; if node.id == id { return nil }
        guard node.leaf == nil else { return node }
        node.first = removing(node.first,id:id); node.second = removing(node.second,id:id)
        if node.first == nil { return node.second }; if node.second == nil { return node.first }; return node
    }
    private func captureRatios(_ node: Node?) {
        guard let node else { return }
        if let split = node.split, let first = split.subviews.first {
            let available = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
            if available > 0 { node.ratio = min(0.95,max(0.05,(split.isVertical ? first.frame.width : first.frame.height)/available)) }
        }
        captureRatios(node.first); captureRatios(node.second)
    }
    private func build(_ node: Node) -> NSView {
        if let leaf = node.leaf { leaf.removeFromSuperview(); return leaf }
        let split = NSSplitView(); split.isVertical = node.direction == .left || node.direction == .right
        split.dividerStyle = .thin; split.delegate = self
        split.addArrangedSubview(build(node.first!)); split.addArrangedSubview(build(node.second!))
        node.split = split; return split
    }
    private func rebuild() {
        arranging = true
        subviews.forEach { $0.removeFromSuperview() }
        if let root { let view = build(root); addSubview(view); view.frame = bounds }
        arranging = false; needsLayout = true; layoutSubtreeIfNeeded()
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout(); arranging = true; defer { arranging = false }
        subviews.first?.frame = bounds
        func arrange(_ node: Node?) {
            guard let node, let split = node.split else { return }
            let length = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
            split.setPosition(max(0,length)*node.ratio,ofDividerAt:0)
            arrange(node.first); arrange(node.second)
        }
        arrange(root)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        if !arranging { captureRatios(root) }
    }
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let length = (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness
        let minimum = min(100,max(0,length/2))
        return min(max(minimum,proposedPosition),max(minimum,length - minimum))
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}
