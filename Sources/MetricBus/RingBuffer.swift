/// Fixed-capacity circular history buffer.
///
/// Stores `Float`, not `Double`: history exists to be *drawn*, and no graph
/// that is 34 points wide can express more than ~7 significant digits. Halving
/// the storage means an hour of 1Hz history for 60 metrics costs about 860 KB
/// rather than 1.7 MB.
///
/// Capacity is allocated once at init and never grows, so appending in the hot
/// path is a store and two integer updates -- no reallocation, ever.
public struct RingBuffer<Element>: Sendable where Element: Sendable {
    private var storage: [Element]
    /// Index where the next element will be written.
    private var next = 0
    public private(set) var count = 0

    public let capacity: Int

    public init(capacity: Int, filler: Element) {
        precondition(capacity > 0, "RingBuffer needs a positive capacity")
        self.capacity = capacity
        self.storage = Array(repeating: filler, count: capacity)
    }

    public var isEmpty: Bool { count == 0 }

    public mutating func append(_ element: Element) {
        storage[next] = element
        next = (next + 1) % capacity
        if count < capacity { count += 1 }
    }

    /// The most recently appended element, if any.
    public var last: Element? {
        guard count > 0 else { return nil }
        return storage[(next - 1 + capacity) % capacity]
    }

    /// The last `n` elements in chronological order (oldest first).
    ///
    /// Allocates. That is fine at the call sites that use it -- a graph pulls
    /// its window once per redraw, at most a few times a second -- but it is
    /// why the *write* path above is separate and allocation-free.
    public func suffix(_ n: Int) -> [Element] {
        let wanted = Swift.min(n, count)
        guard wanted > 0 else { return [] }

        var result = [Element]()
        result.reserveCapacity(wanted)
        let start = (next - wanted + capacity) % capacity
        for offset in 0..<wanted {
            result.append(storage[(start + offset) % capacity])
        }
        return result
    }

    /// Chronological view of everything retained.
    public func ordered() -> [Element] { suffix(count) }
}
