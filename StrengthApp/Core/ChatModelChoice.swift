import Foundation

enum ChatModelChoice: String, CaseIterable, Identifiable {
    case onDevice
    case deepSeek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: return "On-device"
        case .deepSeek: return "DeepSeek"
        }
    }
}
