import Foundation

/// Tab rings the surfaces a reader opens directly; a sub-screen exits to the launcher.
enum PaletteTabAction: Equatable {
    /// The typed text rides along, because both ends narrow their own list by the same query.
    case carryQuery(PaletteMode)
    /// A fresh screen: a half-written field holds state which is nobody else's search.
    case freshScreen(PaletteMode)

    static func resolve(mode: PaletteMode, clipboardEnabled: Bool) -> Self {
        switch mode {
        case .launcher:
            return clipboardEnabled ? .carryQuery(.clipboard) : .carryQuery(.launcher)
        case .clipboard: return .carryQuery(.launcher)
        default: return .carryQuery(.launcher)
        }
    }
}
