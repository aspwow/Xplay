import Foundation
import CoreVideo
import os.lock

struct QueuedFrame {
    let pixelBuffer: CVPixelBuffer
    let ptsHostTime: UInt64
}

final class FrameQueue {
    private let state = OSAllocatedUnfairLock<[QueuedFrame]>(initialState: [])
    private let maxSlots = 4

    private let stats = OSAllocatedUnfairLock<Stats>(initialState: Stats())
    struct Stats {
        var pushed: UInt64 = 0
        var picked: UInt64 = 0
        var doubled: UInt64 = 0
        var droppedUnused: UInt64 = 0
        var lastPickedPTS: UInt64 = 0
    }

    func push(_ frame: QueuedFrame) {
        state.withLock { slots in
            slots.append(frame)
            if slots.count > maxSlots {
                let evictCount = slots.count - maxSlots
                stats.withLock { $0.droppedUnused &+= UInt64(evictCount) }
                slots.removeFirst(evictCount)
            }
        }
        stats.withLock { $0.pushed &+= 1 }
    }

    /// Pick the frame whose PTS is closest to (and ≤) target time, with
    /// half-frame vsync bias tolerance. Evicts strictly older frames; keeps
    /// the chosen one for potential frame-doubling on the next call.
    func pickForHostTime(_ target: UInt64, halfFrameUnits: UInt64) -> QueuedFrame? {
        let result: QueuedFrame? = state.withLock { slots in
            guard !slots.isEmpty else { return nil }

            let cutoff = target &+ halfFrameUnits
            var chosen = slots.count - 1
            for i in (0..<slots.count).reversed() {
                if slots[i].ptsHostTime <= cutoff {
                    chosen = i
                    break
                }
            }
            let picked = slots[chosen]
            if chosen > 0 {
                let evicted = chosen
                stats.withLock { $0.droppedUnused &+= UInt64(evicted) }
                slots.removeFirst(evicted)
            }
            return picked
        }

        if let picked = result {
            stats.withLock {
                $0.picked &+= 1
                if picked.ptsHostTime == $0.lastPickedPTS {
                    $0.doubled &+= 1
                }
                $0.lastPickedPTS = picked.ptsHostTime
            }
        }
        return result
    }

    func flush() {
        state.withLock { $0.removeAll() }
    }

    func snapshotStats() -> Stats {
        stats.withLock { $0 }
    }

    func resetStats() {
        stats.withLock { $0 = Stats() }
    }
}
