public struct SelectionState: Equatable, Sendable {
    public private(set) var ids: Set<FileIdentity> = []

    public init() {}

    public mutating func toggle(_ id: FileIdentity) {
        ids.formSymmetricDifference([id])
    }

    public mutating func setSelected(_ values: [FileIdentity], selected: Bool) {
        if selected {
            ids.formUnion(values)
        } else {
            ids.subtract(values)
        }
    }

    public mutating func retainOnly(_ valid: Set<FileIdentity>) {
        ids.formIntersection(valid)
    }

    public mutating func removeAll() {
        ids.removeAll()
    }
}
