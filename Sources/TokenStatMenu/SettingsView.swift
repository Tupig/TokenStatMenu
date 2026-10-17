import SwiftUI

@MainActor struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ValueState private var draft: SeasunPreferences

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.preferences)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Seasun Token Hub") {
                    VStack(alignment: .leading, spacing: 8) {
                Text(model.userFacingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("本地 Codex 历史记录与 Token Hub 界面兼容快照各自按实际观测单独展示，不代表企业后台直连。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("企业后台直接来源：尚不可用")
                    .font(.caption)
                    .accessibilityIdentifier("seasun-source-status")
                    }
                }
                .accessibilityLabel("Seasun Token Hub")

                GroupBox("可选偏好") {
                    VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("刷新秒数（15–3600）")
                    Spacer()
                    TextField("60", value: $draft.refreshSeconds, format: .number)
                        .frame(width: 88)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .accessibilityLabel("刷新秒数")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("刷新秒数（15–3600）")
                Toggle("Token Hub 界面兼容读取（可选）", isOn: $draft.tokenHubCompatibilityReadEnabled)
                    .accessibilityIdentifier("token-hub-compatibility-toggle")
                    .accessibilityLabel("Token Hub 界面兼容读取（可选）")
                Text("只读取 Token Hub 当前界面的兼容快照，不代表 Seasun 数据连接完成。默认启用，不会自动请求辅助功能授权。")
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
            .accessibilityElement(children: .contain)
        }
        .textFieldStyle(.roundedBorder)
    }
}
