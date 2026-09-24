import Testing
@testable import MetricBus

@Suite("Ring buffer")
struct RingBufferTests {

    @Test("keeps the most recent samples once full")
    func wraps() {
        var buffer = RingBuffer<Float>(capacity: 3, filler: .nan)
        for value in 1...5 { buffer.append(Float(value)) }

        #expect(buffer.count == 3)
        #expect(buffer.ordered() == [3, 4, 5])
        #expect(buffer.last == 5)
    }

    @Test("suffix is chronological and clamped")
    func suffix() {
        var buffer = RingBuffer<Float>(capacity: 5, filler: .nan)
        for value in 1...4 { buffer.append(Float(value)) }

        #expect(buffer.suffix(2) == [3, 4])
        #expect(buffer.suffix(99) == [1, 2, 3, 4])
        #expect(buffer.suffix(0).isEmpty)
    }

    @Test("is empty before anything is written")
    func startsEmpty() {
        let buffer = RingBuffer<Float>(capacity: 4, filler: .nan)
        #expect(buffer.isEmpty)
        #expect(buffer.last == nil)
        #expect(buffer.ordered().isEmpty)
    }
}
