import Foundation
import Testing
@testable import CursorTrail

/// Ring buffer edge cases: empty state, filling to capacity, wrap-around overwrite of the
/// oldest point, removal, and clearing.
@Suite("RingBuffer")
struct RingBufferTests {

    @Test("a new buffer is empty")
    func emptyBuffer() {
        let buffer = RingBuffer<Int>(capacity: 5)

        #expect(buffer.isEmpty)
        #expect(buffer.count == 0)
        #expect(buffer.first == nil)
    }

    @Test("appending up to capacity grows the count")
    func appendUntilFull() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)

        #expect(buffer.count == 3)
        #expect(buffer.isEmpty == false)
        #expect(buffer[0] == 1)
        #expect(buffer[2] == 3)
    }

    @Test("appending past capacity overwrites the oldest entry")
    func overwriteOldest() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)
        buffer.append(4)

        #expect(buffer.count == 3)
        #expect(buffer[0] == 2, "the oldest value must be dropped")
        #expect(buffer[1] == 3)
        #expect(buffer[2] == 4)
    }

    @Test("clear() empties the buffer and rewinds the indices")
    func clear() {
        var buffer = RingBuffer<Int>(capacity: 5)
        buffer.append(1)
        buffer.append(2)
        buffer.clear()

        #expect(buffer.isEmpty)
        #expect(buffer.count == 0)
        #expect(buffer.first == nil)

        // Reuse after clear must start writing from index 0 again.
        buffer.append(9)
        #expect(buffer[0] == 9)
    }

    @Test("removing drains in insertion order and stops at empty")
    func removeFirstOrder() {
        var buffer = RingBuffer<Int>(capacity: 4)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)

        #expect(buffer.removeFirst() == 1)
        #expect(buffer.removeFirst() == 2)
        #expect(buffer.removeFirst() == 3)
        #expect(buffer.isEmpty)
        #expect(buffer.removeFirst() == nil, "removing from an empty buffer returns nil")
    }

    @Test("removal after wrap-around still yields the oldest live value")
    func removeAfterWrapAround() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 {
            buffer.append(value)
        }
        #expect(buffer[0] == 3)

        #expect(buffer.removeFirst() == 3)
        #expect(buffer.count == 2)
        #expect(buffer[0] == 4)
    }

    @Test("first reflects the oldest live element, not index 0 of storage")
    func firstAfterWrapAround() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...4 {
            buffer.append(value)
        }

        #expect(buffer.first == 2)
    }

    @Test("a single-element buffer wraps onto itself")
    func capacityOne() {
        var buffer = RingBuffer<Int>(capacity: 1)
        buffer.append(1)
        #expect(buffer.count == 1)
        #expect(buffer[0] == 1)

        buffer.append(2)
        #expect(buffer.count == 1)
        #expect(buffer[0] == 2)
        #expect(buffer.first == 2)
    }

    @Test("the count never exceeds capacity and every index stays readable")
    func countIsBoundedByCapacity() {
        let capacity = 7
        var buffer = RingBuffer<Int>(capacity: capacity)

        for value in 0..<100 {
            buffer.append(value)
            #expect(buffer.count <= capacity)
        }

        #expect(buffer.count == capacity)
        for index in 0..<buffer.count {
            let _ = buffer[index]
        }
    }
}