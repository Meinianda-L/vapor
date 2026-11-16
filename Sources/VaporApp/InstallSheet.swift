import SwiftUI
import VaporKit

struct InstallSheet: View {
    let appid: UInt32
    let name: String
    var dismiss: () -> Void
    @EnvironmentObject var engine: EngineModel
    @State private var probe: SteamUI.Install?
    @State private var probing = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("安装 \(name)").font(.system(size: 15, weight: .semibold))
            Group {
                if probing {
                    Text("正在向 Steam 查询大小…")
                } else if let p = probe, p.required > 0 {
                    Text("需要 \(bytes(p.required))，磁盘剩余 \(bytes(p.available))。由后台的 Windows Steam 下载。")
                } else if let size = engine.downloadSize(appid) {
                    Text("下载约 \(bytes(size))。由后台的 Windows Steam 下载。")
                } else {
                    Text("由后台的 Windows Steam 下载。")
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消", action: dismiss).keyboardShortcut(.cancelAction)
                Button("安装") { engine.install(appid); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(probing || (probe.map { $0.required >= $0.available && $0.available > 0 } ?? false))
            }
        }
        .padding(22)
        .frame(width: 400)
        .task {
            probe = await engine.probeInstall(appid)
            probing = false
        }
    }
}
