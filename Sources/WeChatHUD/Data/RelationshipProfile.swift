import Foundation

struct RelationshipProfile: Codable {
    let username: String
    let displayName: String
    let relationship: String        // "直属领导", "同事-平级", etc.
    let hierarchy: Hierarchy
    let tonePreference: TonePreference
    let context: String?            // "负责审批我的方案"
    let confidence: Double          // 0.0-1.0
    let userNote: String?           // user manual note
    let userEdited: Bool            // if user manually edited, don't auto-overwrite
    let inferredAt: Date
    let updatedAt: Date

    enum Hierarchy: String, Codable, CaseIterable {
        case superior
        case peer
        case subordinate
        case external
        case personal

        var label: String {
            switch self {
            case .superior: return "上级"
            case .peer: return "平级"
            case .subordinate: return "下属"
            case .external: return "外部"
            case .personal: return "私人"
            }
        }
    }

    enum TonePreference: String, Codable, CaseIterable {
        case formal
        case casual
        case brief

        var label: String {
            switch self {
            case .formal: return "正式"
            case .casual: return "随意"
            case .brief: return "简洁"
            }
        }
    }
}
