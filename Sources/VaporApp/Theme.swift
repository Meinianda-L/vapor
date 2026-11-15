import SwiftUI
import VaporKit

/// Restrained, type-led look: neutral near-black, Apple greys, hairlines.
/// One accent (the ember from the icon) is reserved for Play and selection.
enum Theme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let sidebar = Color(red: 0.082, green: 0.082, blue: 0.090)
    static let surface = Color(white: 1, opacity: 0.04)
    static let hairline = Color(white: 1, opacity: 0.08)
    static let text = Color(white: 0.95)
    static let secondary = Color(red: 0.557, green: 0.557, blue: 0.576)   // systemGray
    static let tertiary = Color(white: 1, opacity: 0.32)
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.26)

    static let ok = Color(red: 0.36, green: 0.78, blue: 0.54)
    static let warn = Color(red: 0.90, green: 0.71, blue: 0.31)
    static let bad = Color(red: 0.90, green: 0.33, blue: 0.29)

    static func verdictColor(_ v: GameProfile.Verdict?) -> Color {
        switch v {
        case .expected: return ok
        case .needsTesting, .needsLauncher: return warn
        case .blocked: return bad
        case nil: return tertiary
        }
    }

    static func verdictLabel(_ v: GameProfile.Verdict?) -> String {
        switch v {
        case .expected: return "可运行"
        case .needsTesting: return "待测试"
        case .needsLauncher: return "需要第三方启动器"
        case .blocked: return "无法运行"
        case nil: return "—"
        }
    }

    /// Chinese wording for VaporKit's ladder reasons (kept English in the library).
    static func reasonLabel(_ reason: String) -> String {
        var exe = ""
        var text = reason
        if let r = text.range(of: " ["), text.hasSuffix("]") {
            exe = "，\(text[r.upperBound..<text.index(before: text.endIndex)])"
            text = String(text[..<r.lowerBound])
        }
        let map = [
            "D3D12 is only translated by D3DMetal": "D3D12 只有 D3DMetal 能转译",
            "engine also ships a D3D11 path": "引擎也带 D3D11 渲染路径",
            "32-bit D3D11: DXMT has an i386 build": "32 位 D3D11，DXMT 有 i386 版本",
            "D3D11 straight to Metal": "D3D11 直接转 Metal",
            "alternative D3D11 -> Metal translator": "另一条 D3D11 → Metal 路径",
            "D3D11 via Vulkan fallback": "经 Vulkan 的后备路径",
            "last resort": "最后的后备",
            "Valve quirk nod3d10": "Valve 配置 nod3d10",
            "D3D10 straight to Metal": "D3D10 直接转 Metal",
            "fallback": "后备",
            "D3D9 via DXVK on a conformant Vulkan 1.3 driver": "D3D9 经 DXVK，跑在 KosmicKrisp 上",
            "D3D9 via DXVK on MoltenVK": "D3D9 经 DXVK，跑在 MoltenVK 上",
            "Wine's own D3D9": "Wine 自带的 D3D9",
            "DirectDraw is handled by WineD3D": "DirectDraw 交给 WineD3D",
            "OpenGL game: Wine's GL path": "OpenGL，走 Wine 的 GL 路径",
            "native Vulkan game on MoltenVK": "原生 Vulkan，跑在 MoltenVK 上",
            "native Vulkan game on KosmicKrisp": "原生 Vulkan，跑在 KosmicKrisp 上",
            "no graphics API detected": "没有检测到图形 API",
        ]
        return (map[text] ?? text) + exe
    }

    static func engineLabel(_ e: Engine) -> String {
        switch e {
        case .source: return "Source"
        case .source2: return "Source 2"
        case .unity: return "Unity"
        case .unreal: return "Unreal"
        case .unknown: return "未识别"
        }
    }

    static func machineLabel(_ m: PEFile.Machine?) -> String {
        switch m {
        case .i386: return "x86 · 32 位"
        case .amd64: return "x86-64"
        case .arm64: return "ARM64"
        default: return "未知"
        }
    }

    static func apiLabel(_ a: GraphicsAPI) -> String {
        switch a {
        case .d3d8: return "DirectX 8"
        case .d3d9: return "DirectX 9"
        case .d3d10: return "DirectX 10"
        case .d3d11: return "DirectX 11"
        case .d3d12: return "DirectX 12"
        case .ddraw: return "DirectDraw"
        case .opengl: return "OpenGL"
        case .vulkan: return "Vulkan"
        }
    }

    static func rendererLabel(_ r: Renderer) -> String {
        switch r {
        case .d3dMetal: return "D3DMetal"
        case .dxmt: return "DXMT"
        case .dxvkKosmicKrisp: return "DXVK + KosmicKrisp"
        case .dxvkMoltenVK: return "DXVK + MoltenVK"
        case .wined3d: return "WineD3D"
        }
    }
}

/// "a · b · c" metadata line.
struct MetaLine: View {
    let parts: [String]
    var size: CGFloat = 12
    var body: some View {
        Text(parts.filter { !$0.isEmpty }.joined(separator: "  ·  "))
            .font(.system(size: size))
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 6, height: 6) }
}

/// Small section heading used throughout.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .kerning(0.4)
    }
}
