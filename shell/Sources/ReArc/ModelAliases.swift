import SidebarModel

// SwiftUI gained its own `Tab` type (macOS 15 SDK). This module-local alias
// makes unqualified `Tab` in the shell resolve to the model's tab, which is
// the only one this app uses (the SwiftUI one is unavailable on macOS 14
// anyway).
typealias Tab = SidebarModel.Tab
