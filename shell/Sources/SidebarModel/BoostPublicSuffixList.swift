import Foundation

/// Known public suffix / shared-hosting domains where registrable-domain scoping would span tenants.
public enum BoostPublicSuffixList {
    public static let sharedHostingDomains: Set<String> = [
        "github.io",
        "gitlab.io",
        "herokuapp.com",
        "vercel.app",
        "netlify.app",
        "pages.dev",
        "cloudfront.net",
        "amazonaws.com",
        "blogspot.com",
        "wordpress.com",
        "wixsite.com",
        "squarespace.com",
        "myshopify.com",
    ]

    public static func isSharedHostingRegistrableDomain(_ host: String) -> Bool {
        sharedHostingDomains.contains(host.lowercased())
    }
}
