import Foundation

/// Fixed-capacity Float ring buffer. Pre-allocated once; `append` is O(k), `snapshot` is O(n).
/// When full, the oldest samples are overwritten.
struct RingBuffer {
    private var storage: [Float]
    private var head = 0          // next write index
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        // Only the last `capacity` samples can survive.
        let src = samples.count > capacity ? UnsafeBufferPointer(rebasing: samples.suffix(capacity)) : samples
        var remaining = src.count
        var srcIdx = 0
        storage.withUnsafeMutableBufferPointer { dst in
            while remaining > 0 {
                let n = min(remaining, capacity - head)
                for i in 0..<n { dst[head + i] = src[srcIdx + i] }
                head = (head + n) % capacity
                srcIdx += n
                remaining -= n
            }
        }
        count = min(capacity, count + src.count)
    }

    mutating func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// Samples in chronological order.
    func snapshot() -> [Float] {
        guard count > 0 else { return [] }
        let start = (head - count + capacity) % capacity
        if start + count <= capacity {
            return Array(storage[start..<(start + count)])
        }
        return Array(storage[start..<capacity]) + Array(storage[0..<(head)])
    }

    mutating func reset() {
        head = 0
        count = 0
    }
}
