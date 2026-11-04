import Foundation

/// Deterministic sidebars for `--rearc-bench` (docs/PERFORMANCE-PLAN.md
/// §2.2). The same size and seed give the same structure, titles and URLs;
/// item IDs are fresh UUIDs. Every tab URL comes from `pageURL`, so the bench
/// points them at its loopback server and no tab touches the network.
public enum BenchFixture {
    public enum Size: String, CaseIterable, Sendable {
        /// 5 spaces in 2 profiles; the first space has 40 pinned tabs (6 of
        /// them in folders three levels deep) and 250 Today tabs.
        case items300
        /// As items300 with 450 Today tabs in the first space: 500 rows to scroll.
        case items500
        case items1000
    }

    public struct Layout: Equatable, Sendable {
        /// Per space: owning profile index, pinned tab count, Today tab count.
        public var spaces: [(profile: Int, pinned: Int, today: Int)]
        public var profiles: Int
        /// Folders in the first space's pinned section, each nested in the previous
        /// until `folderDepth`, then a new chain.
        public var folders: Int
        public var folderDepth: Int
        /// Pinned tabs moved into each folder.
        public var tabsPerFolder: Int

        public static func == (a: Layout, b: Layout) -> Bool {
            a.profiles == b.profiles && a.folders == b.folders && a.folderDepth == b.folderDepth
                && a.tabsPerFolder == b.tabsPerFolder
                && a.spaces.map { [$0.profile, $0.pinned, $0.today] } == b.spaces.map { [$0.profile, $0.pinned, $0.today] }
        }

        /// Rows of the first space: pinned tabs, folders and Today tabs.
        public var firstSpaceRows: Int { spaces[0].pinned + folders + spaces[0].today }
    }

    public static func layout(_ size: Size) -> Layout {
        let today: Int
        switch size {
        case .items300: today = 250
        case .items500: today = 450
        case .items1000: today = 950
        }
        return Layout(
            spaces: [(0, 40, today), (0, 4, 12), (0, 4, 12), (1, 4, 12), (1, 4, 12)],
            profiles: 2, folders: 6, folderDepth: 3, tabsPerFolder: 1
        )
    }

    public struct Result {
        public let store: SidebarStore
        /// Spaces in sidebar order; `spaceIDs[0]` holds the large lists.
        public let spaceIDs: [Space.ID]
        public let profileIDs: [Profile.ID]
        /// Every tab created, in creation order.
        public let tabIDs: [Tab.ID]
    }

    /// Words for titles, picked by a seeded generator (SplitMix64).
    static let words = ["Arc", "notes", "design", "release", "budget", "review", "draft", "kernel", "travel", "recipe",
                        "photos", "invoice", "metrics", "roadmap", "sprint", "garden", "lecture", "podcast", "report", "launch"]

    public static func make(_ size: Size, seed: UInt64, pageURL: (Int) -> URL) -> Result {
        let layout = layout(size)
        var random = SplitMix64(seed: seed)
        let store = SidebarStore()
        var profiles = [store.profiles[0].id]
        for index in 1 ..< layout.profiles {
            profiles.append(store.addProfile(name: "Bench Profile \(index + 1)").id)
        }
        var spaceIDs: [Space.ID] = []
        var tabIDs: [Tab.ID] = []
        var page = 0
        func title() -> String {
            let a = words[Int(random.next() % UInt64(words.count))]
            let b = words[Int(random.next() % UInt64(words.count))]
            return "\(a) \(b) \(random.next() % 1000)"
        }
        for (index, spec) in layout.spaces.enumerated() {
            let profile = profiles[spec.profile]
            let spaceID: Space.ID
            if index == 0, let first = store.spaces(in: profile).first {
                spaceID = first.id
            } else {
                var draft = SpaceDraft.suggested(in: store, profileID: profile)
                draft.name = "Bench \(index + 1)"
                guard let space = store.createSpace(from: draft) else { continue }
                spaceID = space.id
            }
            spaceIDs.append(spaceID)
            var pinned: [Tab.ID] = []
            for _ in 0 ..< spec.pinned {
                let tab = store.addTab(kind: .pinned, title: title(), url: pageURL(page), in: spaceID)
                page += 1
                pinned.append(tab.id)
                tabIDs.append(tab.id)
            }
            if index == 0 {
                var parent: UUID?
                for folder in 0 ..< layout.folders {
                    if folder % layout.folderDepth == 0 { parent = nil }
                    let start = folder * layout.tabsPerFolder
                    let members = Array(pinned[start ..< min(start + layout.tabsPerFolder, pinned.count)])
                    let created = store.createFolder(title: "Folder \(folder + 1)", in: spaceID, parentFolderID: parent, containing: members)
                    parent = created?.id
                }
            }
            for _ in 0 ..< spec.today {
                let tab = store.addTab(kind: .today, title: title(), url: pageURL(page), in: spaceID)
                page += 1
                tabIDs.append(tab.id)
            }
        }
        if let first = spaceIDs.first { store.selectSpace(first) }
        return Result(store: store, spaceIDs: spaceIDs, profileIDs: profiles, tabIDs: tabIDs)
    }
}

/// Small deterministic generator (Steele et al., SplitMix64).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
