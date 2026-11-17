import SwiftUI
import VaporKit

/// Steam's profile editor: name, real name, summary and location, saved through the web session as Steam's own page does.
struct ProfileEditSheet: View {
    let steamID: String
    var saved: () -> Void = {}
    var dismiss: () -> Void = {}

    @State private var edit: ProfileEditData?
    @State private var loadFailed = false
    @State private var countries: [LocationOption] = []
    @State private var states: [LocationOption] = []
    @State private var cities: [LocationOption] = []
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("编辑个人资料").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            if let binding = Binding($edit) {
                form(binding)
            } else if loadFailed {
                Text("无法读取当前资料，请稍后再试。").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            } else {
                CommunitySkeleton(rows: 3)
            }
            HStack(spacing: 18) {
                Spacer()
                Button("取消", action: dismiss).buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Button(saving ? String(localized: "正在保存…") : String(localized: "保存")) { Task { await save() } }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(edit == nil || saving ? Theme.tertiary : Theme.accent).disabled(edit == nil || saving)
            }
        }
        .padding(24).frame(width: 460).background(Theme.background).preferredColorScheme(.dark)
        .task { await load() }
    }

    private func form(_ e: Binding<ProfileEditData>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            field(String(localized: "昵称"), text: e.personaName)
            field(String(localized: "真实姓名"), text: e.realName)
            VStack(alignment: .leading, spacing: 5) {
                Text("简介").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                TextEditor(text: e.summary).scrollContentBackground(.hidden).font(.system(size: 13)).foregroundStyle(Theme.text)
                    .frame(height: 84).padding(6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            picker(String(localized: "国家/地区"), options: countries, code: e.countryCode, name: e.countryName) {
                e.wrappedValue.stateCode = ""; e.wrappedValue.stateName = ""; e.wrappedValue.cityCode = ""; e.wrappedValue.cityName = ""
                Task { await loadStates(e.wrappedValue.countryCode) }
            }
            if !states.isEmpty {
                picker(String(localized: "省/州"), options: states, code: e.stateCode, name: e.stateName) {
                    e.wrappedValue.cityCode = ""; e.wrappedValue.cityName = ""
                    Task { await loadCities(e.wrappedValue.countryCode, e.wrappedValue.stateCode) }
                }
            }
            if !cities.isEmpty { picker(String(localized: "城市"), options: cities, code: e.cityCode, name: e.cityName) {} }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.warn) }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            TextField("", text: text).textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func picker(_ title: String, options: [LocationOption], code: Binding<String>, name: Binding<String>, changed: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            Picker("", selection: Binding(get: { code.wrappedValue }, set: { new in
                code.wrappedValue = new
                name.wrappedValue = options.first { $0.code == new }?.name ?? ""
                changed()
            })) {
                Text("未设置").tag("")
                ForEach(options) { Text($0.name).tag($0.code) }
            }
            .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() async {
        guard let cookie = await CommunitySession.cookieHeader(), let data = try? await ProfileEditClient.load(steamID: steamID, cookie: cookie) else {
            if !Task.isCancelled { loadFailed = true }
            return
        }
        guard !Task.isCancelled else { return }
        edit = data
        let zh = Locale(identifier: "zh_CN")
        countries = ((try? await ProfileEditClient.locations()) ?? [])
            .map { LocationOption(code: $0.code, name: zh.localizedString(forRegionCode: $0.code) ?? $0.name, hasChildren: $0.hasChildren) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        await loadStates(data.countryCode, keepCity: data.cityCode)
    }

    private func loadStates(_ country: String, keepCity: String? = nil) async {
        states = []; cities = []
        guard !country.isEmpty, countries.first(where: { $0.code == country })?.hasChildren == true else { return }
        states = (try? await ProfileEditClient.locations(country)) ?? []
        if let state = edit?.stateCode, !state.isEmpty, keepCity != nil { await loadCities(country, state) }
    }

    private func loadCities(_ country: String, _ state: String) async {
        cities = state.isEmpty ? [] : ((try? await ProfileEditClient.locations("\(country)/\(state)")) ?? [])
    }

    private func save() async {
        guard let edit else { return }
        saving = true
        problem = nil
        defer { saving = false }
        guard let cookie = await CommunitySession.cookieHeader() else { problem = String(localized: "网页登录还没有就绪，请稍后再试。"); return }
        do {
            try await ProfileEditClient.save(edit, steamID: steamID, cookie: cookie)
            saved()
            dismiss()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? String(localized: "没有保存成功，请稍后再试。")
        }
    }
}
