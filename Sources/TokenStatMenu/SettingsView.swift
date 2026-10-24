import SwiftUI

@MainActor struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ValueState private var draft: SeasunPreferences

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.preferences)
    }

    /// 设置状态与概览使用同一份有效后台响应，不能因 AX 兼容读取成功就标记后台已连接。
    var sourceStatusText: String {
        if model.tokenHubQuotaIsDirect {
            return model.freshTokenHubQuota(at: model.tokenHubNow()) != nil
                ? "企业后台直接来源：已直接读取"
                : "企业后台直接来源：快照已过期，等待自动刷新"
        }
        if model.tokenHubDirectFailure != nil { return model.userFacingStatus }
        return "企业后台直接来源：尚未连接，等待自动读取"
    }

    static func versionText(bundle: Bundle = .main) -> String {
        guard bundle.bundleIdentifier == "com.tupig.TokenStatMenu",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !version.isEmpty, !build.isEmpty else { return "开发运行（未打包）" }
        return "版本 \(version)（构建 \(build)）"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Seasun Token Hub") {
                    VStack(alignment: .leading, spacing: 8) {
                Text("自动复用本机已登录 Hub 的现有会话，只读获取企业额度，无需填写接口或密钥。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("企业后台额度、本地 Codex 记录和可选界面快照分开标明来源；本地记录与界面快照不能代替后台额度。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(sourceStatusText)
                    .font(.caption)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("seasun-source-status")
                    .accessibilityLabel(sourceStatusText)
                    }
                }
                .accessibilityLabel("Seasun Token Hub")

                Text(Self.versionText())
                    .font(.caption2).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("app-version")

                GroupBox("可选偏好") {
                    VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("刷新秒数（15–3600）")
                    Spacer()
                    TextField("60", value: $draft.refreshSeconds, format: .number)
                        .frame(width: 88)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .accessibilityIdentifier("refresh-seconds")
                        .accessibilityLabel("刷新秒数")
                }
                Color.clear.frame(width: 0, height: 0)
                    .accessibilityElement()
                    .accessibilityIdentifier("refresh-seconds-value")
                    .accessibilityLabel("当前刷新秒数 \(draft.refreshSeconds)")
                Toggle("Token Hub 界面兼容读取（可选）", isOn: $draft.tokenHubCompatibilityReadEnabled)
                    .accessibilityIdentifier("token-hub-compatibility-toggle")
                    .accessibilityLabel("Token Hub 界面兼容读取（可选）")
                Text("此开关只控制界面快照；关闭后仍自动读取企业后台。兼容读取默认启用，不会自动请求辅助功能授权。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("保存偏好") {
                        if model.savePreferences(draft) { draft = model.preferences }
                    }.buttonStyle(.borderedProminent)
                    Button("重新加载偏好") {
                        model.reload()
                        draft = model.preferences
                    }
                    Spacer()
                }
                if !model.message.isEmpty {
                    Text(model.message).font(.caption2).foregroundStyle(.secondary)
                }
                    }
                }

                GroupBox("兼容读取授权") {
                    VStack(alignment: .leading, spacing: 8) {
                Text(model.tokenHubQuotaStatusText)
                    .font(.caption)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("token-hub-quota-status")
                    .accessibilityLabel(model.tokenHubQuotaStatusText)
                Button("请求辅助功能访问…") {
                    model.requestTokenHubAccessibilityAccess()
                }
                .disabled(model.isTestFixture || !draft.tokenHubCompatibilityReadEnabled)
                Text("此权限仅用于读取界面快照，不用于连接企业后台。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
        .textFieldStyle(.roundedBorder)
    }
}
