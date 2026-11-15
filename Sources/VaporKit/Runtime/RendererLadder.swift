import Foundation

/// Graphics translation stacks Vapor can run a game with.
public enum Renderer: String, Sendable, CaseIterable, Codable {
    case d3dMetal        // Apple D3DMetal (GPTK): D3D11/D3D12 -> Metal, x86_64 only
    case dxmt            // DXMT: D3D10/D3D11 -> Metal, 32 and 64-bit
    case dxvkKosmicKrisp // DXVK -> Vulkan 1.3 on LunarG KosmicKrisp -> Metal
    case dxvkMoltenVK    // DXVK -> MoltenVK -> Metal
    case wined3d         // Wine's built-in D3D -> OpenGL
}

public struct LadderRung: Sendable, Equatable {
    public let renderer: Renderer
    public let arguments: [String]     // e.g. Unity's -force-d3d11
    public let experimental: Bool
    public let reason: String
    /// Run this launch entry instead of the profile's default one (nil = default).
    public var launch: LaunchPlan? = nil
    public var executable: String? { launch?.executable }
}

/// Orders the renderers worth trying for a game. The self-tuning runtime starts
/// at the first rung and moves down on crash, or reorders by measured frame time.
public enum RendererLadder {
    public static func build(for game: GameAnalysis, settings: WineSettings,
                             alternates: [LaunchPlan] = []) -> [LadderRung] {
        var rungs = rungs(apis: game.likelyAPIs, is32: game.is32Bit, engine: game.engine, settings: settings, launch: nil)

        // Alternative launch entries that unlock a different API (e.g. MK11_DX12.exe):
        // their best rung goes second so it is measured early; the rest go last.
        for plan in alternates {
            guard let other = game.otherExecutables[plan.executable.lowercased()], !other.apis.isEmpty else { continue }
            guard !other.apis.isSubset(of: Set(game.likelyAPIs)) else { continue }
            let extra = Self.rungs(apis: other.apis.sorted(by: >), is32: other.is32Bit, engine: game.engine, settings: settings,
                                   launch: plan)
            guard let first = extra.first else { continue }
            rungs.insert(first, at: min(1, rungs.count))
            rungs.append(contentsOf: extra.dropFirst().filter { e in !rungs.contains(e) })
        }
        if rungs.isEmpty { rungs.append(LadderRung(renderer: .wined3d, arguments: [], experimental: false, reason: "no graphics API detected")) }
        return rungs
    }

    static func rungs(apis: [GraphicsAPI], is32: Bool, engine: Engine, settings: WineSettings, launch: LaunchPlan?) -> [LadderRung] {
        var rungs: [LadderRung] = []
        func add(_ r: Renderer, _ reason: String, args: [String] = [], experimental: Bool = false) {
            let rung = LadderRung(renderer: r, arguments: args, experimental: experimental,
                                  reason: launch.map { "\(reason) [\(($0.executable as NSString).lastPathComponent)]" } ?? reason,
                                  launch: launch)
            if !rungs.contains(where: { $0.renderer == r && $0.arguments == args }) { rungs.append(rung) }
        }
        let forceD3D11: [String] = engine == .unity ? ["-force-d3d11"] : engine == .unreal ? ["-dx11"] : []

        for api in apis {
            switch api {
            case .d3d12:
                if is32 { continue }
                add(.d3dMetal, "D3D12 is only translated by D3DMetal")
                if apis.contains(.d3d11) && !forceD3D11.isEmpty {
                    add(.dxmt, "engine also ships a D3D11 path", args: forceD3D11)
                }
            case .d3d11:
                add(.dxmt, is32 ? "32-bit D3D11: DXMT has an i386 build" : "D3D11 straight to Metal")
                if !is32 { add(.d3dMetal, "alternative D3D11 -> Metal translator") }
                add(.dxvkMoltenVK, "D3D11 via Vulkan fallback")
                add(.wined3d, "last resort")
            case .d3d10:
                if settings.avoidD3D10Translation {
                    add(.wined3d, "Valve quirk nod3d10")
                } else {
                    add(.dxmt, "D3D10 straight to Metal")
                    add(.wined3d, "fallback")
                }
            case .d3d9, .d3d8:
                add(.dxvkKosmicKrisp, "D3D9 via DXVK on a conformant Vulkan 1.3 driver", experimental: true)
                add(.dxvkMoltenVK, "D3D9 via DXVK on MoltenVK")
                add(.wined3d, "Wine's own D3D9")
            case .ddraw:
                add(.wined3d, "DirectDraw is handled by WineD3D")
            case .opengl:
                add(.wined3d, "OpenGL game: Wine's GL path")
            case .vulkan:
                add(.dxvkMoltenVK, "native Vulkan game on MoltenVK")
                add(.dxvkKosmicKrisp, "native Vulkan game on KosmicKrisp", experimental: true)
            }
        }
        return rungs
    }
}
