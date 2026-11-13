import Foundation

/// Identifies one file on one disk. Every hard link to a file has the same key.
struct FileKey: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

/// Totals for one file extension.
struct ExtensionTotals: Equatable, Sendable {
    var size: Int64 = 0
    var allocated: Int64 = 0
    var count: Int = 0

    mutating func add(size: Int64, allocated: Int64) {
        self.size += size
        self.allocated += allocated
        self.count += 1
    }

    mutating func merge(_ other: ExtensionTotals) {
        size += other.size
        allocated += other.allocated
        count += other.count
    }

    mutating func subtract(_ other: ExtensionTotals) {
        size = max(0, size - other.size)
        allocated = max(0, allocated - other.allocated)
        count = max(0, count - other.count)
    }
}

/// What a set of files adds to the File Types and Ages views.
struct FileTally: Equatable, Sendable {
    var extensions: [String: ExtensionTotals] = [:]
    var ageAllocated = [Int64](repeating: 0, count: AgeBands.count)
    var ageCounts = [Int](repeating: 0, count: AgeBands.count)

    /// `now` is the scan's clock, so a file always falls in the same age band.
    mutating func add(ext: String, size: Int64, allocated: Int64, modified: Int64, now: Int64) {
        extensions[ext, default: ExtensionTotals()].add(size: size, allocated: allocated)
        let band = AgeBands.index(ageSeconds: max(0, now - modified))
        ageAllocated[band] += allocated
        ageCounts[band] += 1
    }

    mutating func merge(_ other: FileTally) {
        for (ext, totals) in other.extensions {
            extensions[ext, default: ExtensionTotals()].merge(totals)
        }
        for i in ageAllocated.indices {
            ageAllocated[i] += other.ageAllocated[i]
            ageCounts[i] += other.ageCounts[i]
        }
    }
}

/// One of the largest files found in a scan.
struct TopFile: Identifiable, Hashable {
    let path: String
    let size: Int64
    let allocated: Int64
    let modified: Int64
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var modifiedDate: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }
}

/// Keeps the N largest files (by allocated space) with a min-heap.
struct TopFileHeap {
    let capacity: Int
    private(set) var items: [TopFile] = []

    init(capacity: Int) { self.capacity = max(0, capacity) }

    @inline(__always)
    func wants(_ allocated: Int64) -> Bool {
        capacity > 0 && (items.count < capacity || allocated > items[0].allocated)
    }

    mutating func insert(_ file: TopFile) {
        guard capacity > 0 else { return }
        if items.count < capacity {
            items.append(file)
            siftUp(items.count - 1)
        } else if file.allocated > items[0].allocated {
            items[0] = file
            siftDown(0)
        }
    }

    mutating func merge(_ other: TopFileHeap) {
        for file in other.items where wants(file.allocated) { insert(file) }
    }

    func sortedDescending() -> [TopFile] {
        items.sorted { $0.allocated > $1.allocated }
    }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            if items[child].allocated < items[parent].allocated {
                items.swapAt(child, parent)
                child = parent
            } else {
                break
            }
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < items.count && items[left].allocated < items[smallest].allocated { smallest = left }
            if right < items.count && items[right].allocated < items[smallest].allocated { smallest = right }
            if smallest == parent { return }
            items.swapAt(parent, smallest)
            parent = smallest
        }
    }
}

/// Age bands for the "Ages" view, by last modification date.
enum AgeBands {
    static let labels = [
        "Last 7 days", "1–4 weeks", "1–3 months", "3–6 months",
        "6–12 months", "1–2 years", "2–5 years", "Over 5 years",
    ]
    /// Upper bounds in days for every band except the last.
    private static let limitsInDays: [Int64] = [7, 30, 91, 182, 365, 730, 1826]
    static var count: Int { labels.count }

    @inline(__always)
    static func index(ageSeconds: Int64) -> Int {
        let days = ageSeconds / 86_400
        for (i, limit) in limitsInDays.enumerated() where days < limit { return i }
        return labels.count - 1
    }
}

/// Everything a finished scan produced. Built on a background thread, then handed to the
/// main thread, which is the only thread that touches it afterwards.
final class ScanResult: @unchecked Sendable {
    let root: Node
    let rootPath: String
    let displayName: String
    let started: Date
    var duration: TimeInterval = 0
    var extensions: [String: ExtensionTotals] = [:]
    var ageAllocated = [Int64](repeating: 0, count: AgeBands.count)
    var ageCounts = [Int](repeating: 0, count: AgeBands.count)
    var topFiles: [TopFile] = []
    var unreadableFolders = 0
    var unreadableSamples: [String] = []
    var otherVolumeFolders = 0
    /// Folders only in the cloud (not downloaded) that haven't been read: they take no space here.
    var cloudOnlyFolders = 0
    /// Those folders and where they are, for reading them after the scan.
    var cloudFolders: [CloudFolder] = []
    var hardLinkDuplicates = 0
    var statErrors = 0
    /// False while the scan is still running, and for a scan that was stopped before it finished.
    var isComplete = false

    // For reading more of the tree later (cloud folders) the same way the scan did.
    let rootDevice: UInt64
    let topCount: Int
    let links: HardLinkRegistry

    init(root: Node, rootPath: String, displayName: String, started: Date,
         rootDevice: UInt64 = 0, topCount: Int = 100, links: HardLinkRegistry = HardLinkRegistry()) {
        self.root = root
        self.rootPath = rootPath
        self.displayName = displayName
        self.started = started
        self.rootDevice = rootDevice
        self.topCount = topCount
        self.links = links
    }

    /// Adds a part of the scan read later: its file types, ages, largest files and counts.
    /// (Its folders are added to the tree with `Node.adopt(contentsOf:)`.)
    func absorb(_ stats: ScanAccumulator) {
        for (ext, totals) in stats.tally.extensions {
            extensions[ext, default: ExtensionTotals()].merge(totals)
        }
        for i in ageAllocated.indices {
            ageAllocated[i] += stats.tally.ageAllocated[i]
            ageCounts[i] += stats.tally.ageCounts[i]
        }
        if !stats.top.items.isEmpty {
            var heap = TopFileHeap(capacity: topCount)
            for file in topFiles + stats.top.items where heap.wants(file.allocated) { heap.insert(file) }
            topFiles = heap.sortedDescending()
        }
        unreadableFolders += stats.unreadable
        for sample in stats.unreadableSamples where unreadableSamples.count < ScanAccumulator.sampleLimit {
            unreadableSamples.append(sample)
        }
        otherVolumeFolders += stats.otherVolumes
        cloudOnlyFolders += stats.cloudOnly
        cloudFolders += stats.cloudFolders
        hardLinkDuplicates += stats.hardLinkDuplicates
        statErrors += stats.statErrors
    }

    /// Pieces that arrived before the piece holding their folder; see `fillIn(_ pieces:)`.
    private var waitingPieces: [ObjectIdentifier: ScanPiece] = [:]

    /// Pieces that couldn't be filled in yet (their folder is inside a piece not in the tree yet).
    var piecesWaiting: Int { waitingPieces.count }

    /// Fills in folders read later (during the scan, or cloud folders after it), in an order that
    /// works: a piece whose folder was handed off from inside another piece waits until that one
    /// is in the tree. Returns how many pieces went in.
    @discardableResult
    func fillIn(_ pieces: [ScanPiece]) -> Int {
        var ready: [ScanPiece] = []
        for piece in pieces {
            if contains(piece.placeholder) {
                ready.append(piece)
            } else {
                waitingPieces[ObjectIdentifier(piece.placeholder)] = piece
            }
        }
        var added = 0
        while let piece = ready.popLast() {
            fillIn(piece)
            added += 1
            guard !waitingPieces.isEmpty else { continue }
            // Pieces waiting for this one: their placeholders are now in the tree.
            var stack = piece.placeholder.children
            while let node = stack.popLast() {
                if node.pending, let next = waitingPieces.removeValue(forKey: ObjectIdentifier(node)) {
                    ready.append(next)
                }
                stack.append(contentsOf: node.children)
            }
        }
        return added
    }

    /// True when `node` is part of this scan's tree (not of a piece still on its way).
    func contains(_ node: Node) -> Bool {
        var current: Node? = node
        while let candidate = current {
            if candidate === root { return true }
            current = candidate.parent
        }
        return false
    }

    /// Fills in one folder read later. Its placeholder must already be in the tree.
    func fillIn(_ piece: ScanPiece) {
        let wasCloud = piece.placeholder.cloudOnly
        piece.placeholder.adopt(contentsOf: piece.contents)
        if wasCloud && !piece.placeholder.cloudOnly { cloudOnlyFolders = max(0, cloudOnlyFolders - 1) }
        absorb(piece.stats)
    }

    /// The clock the scan measured file ages against (seconds since 1970).
    var scanTime: Int64 { Int64(started.timeIntervalSince1970) }

    /// Takes files out of the File Types and Ages totals, after they were moved to the Trash.
    func remove(_ tally: FileTally) {
        for (ext, totals) in tally.extensions {
            guard var current = extensions[ext] else { continue }
            current.subtract(totals)
            extensions[ext] = current.count > 0 ? current : nil
        }
        for i in ageAllocated.indices {
            ageAllocated[i] = max(0, ageAllocated[i] - tally.ageAllocated[i])
            ageCounts[i] = max(0, ageCounts[i] - tally.ageCounts[i])
        }
    }
}

/// How a scan ended.
enum ScanOutcome: @unchecked Sendable {
    case finished(ScanResult)
    case cancelled
    case failed(String)
}
