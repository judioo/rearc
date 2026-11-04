import Foundation

/// Arc's Copy URL "without any trackers": query parameters from the tracker
/// table in Arc 1.171.0's binary are removed before the link is copied
/// (docs/SHORTCUTS.md "Copy URL"). A name ending in `_` is a prefix; the rest
/// match exactly. The site groups follow the table's order after its
/// twitter.com / x.com entry; which site each later group belongs to is
/// inferred from the names (eBay, YouTube, Amazon).
public enum LinkCleaner {
    static let anywhere: Set<String> = [
        "_bta_c", "_bta_tid", "_ga", "_hsenc", "_hsmi", "_ke", "_openstat", "dm_i", "ef_id", "epik", "gclsrc",
        "gdffi", "gdfms", "gdftrk", "hsa_", "igsh", "matomo_", "mc_", "mkwid", "msclkid", "mtm_", "ns_",
        "oly_anon_id", "oly_enc_id", "otc", "pcrid", "piwik_", "pk_", "rb_clickid", "ref", "s_kwcid",
        "sb_referer_host", "soc_src", "soc_trk", "spm", "sr_", "stm_", "trk_", "utm_", "vero_",
        "cm_mmc", "fbclid", "gad_source", "gclid", "pla", "si", "trackingId", "mt", "mcid", "linkCode",
        "srsltid", "ocid", "trk", "ncid", "mtc", "srcid", "_pos", "_sid", "_ss", "share_id",
    ]

    /// Host suffix → extra names for that site.
    static let sites: [(hosts: [String], names: Set<String>)] = [
        (["twitter.com", "x.com"], ["t", "s"]),
        (["ebay.com", "ebay.co.uk", "ebay.de"], ["_trkparms", "_trksid", "_from", "hash", "_skw", "itmmeta", "itmprp"]),
        (["youtube.com", "youtu.be"], ["feature", "app", "source_ve_path"]),
        (["amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.ca", "amazon.co.jp", "amazon.in"], [
            "_encoding", "ascsubtag", "pd_rd_", "pf", "pf_rd_", "psc", "tag", "ie", "hv", "content-id", "crid",
            "dib", "dib_tag", "keywords", "qid", "rnid", "s", "sprefix", "th",
        ]),
    ]

    /// The URL without tracking parameters, and whether any were removed.
    public static func clean(_ url: URL) -> (url: URL, removedTrackers: Bool) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return (url, false) }
        let names = anywhere.union(siteNames(for: components.host))
        let kept = items.filter { !matches($0.name, names) }
        guard kept.count != items.count else { return (url, false) }
        components.queryItems = kept.isEmpty ? nil : kept
        return (components.url ?? url, true)
    }

    static func siteNames(for host: String?) -> Set<String> {
        guard let host = host?.lowercased() else { return [] }
        return sites.filter { group in
            group.hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }.reduce(into: Set<String>()) { $0.formUnion($1.names) }
    }

    static func matches(_ name: String, _ names: Set<String>) -> Bool {
        if names.contains(name) { return true }
        return names.contains { $0.hasSuffix("_") && name.hasPrefix($0) }
    }
}
