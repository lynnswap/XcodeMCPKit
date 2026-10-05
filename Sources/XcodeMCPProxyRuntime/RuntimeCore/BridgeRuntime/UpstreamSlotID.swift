struct UpstreamSlotID: Sendable, Hashable, Comparable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static func < (lhs: UpstreamSlotID, rhs: UpstreamSlotID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

