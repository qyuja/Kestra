import SwiftUI

struct MenuBarIconSettingsView: View {
    @ObservedObject var squatRunner: SquatRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle
            iconOptions
            actionRow

            if !squatRunner.pluginErrors.isEmpty {
                errorList
            }
        }
    }

    private var sectionTitle: some View {
        Text("状态栏图标")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(StatusPopoverStyle.secondaryText)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private var iconOptions: some View {
        VStack(spacing: 6) {
            if squatRunner.options.isEmpty {
                Text("暂无可用图标")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StatusPopoverStyle.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 9)
            } else {
                ForEach(squatRunner.options, id: \.id) { option in
                    iconOptionRow(option)
                }
            }
        }
    }

    private func iconOptionRow(_ option: MenuBarIconOption) -> some View {
        let isSelected = squatRunner.selectedIconID == option.id

        return Button {
            squatRunner.selectIcon(option.id)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(
                        isSelected
                            ? StatusPopoverStyle.selectionColor
                            : StatusPopoverStyle.selectionColor.opacity(0.35)
                    )
                    .frame(width: 5, height: 5)

                Text(option.name)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(
                        isSelected
                            ? StatusPopoverStyle.primaryText
                            : StatusPopoverStyle.primaryText.opacity(0.58)
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(StatusPopoverStyle.selectionColor)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(
                isSelected
                    ? StatusPopoverStyle.selectedTile
                    : StatusPopoverStyle.tile,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button(action: squatRunner.openPluginsDirectory) {
                Label("打开插件目录", systemImage: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(StatusPopoverStyle.primaryText.opacity(0.68))
            .font(.system(size: 11, weight: .medium))

            Spacer(minLength: 8)

            Button(action: squatRunner.reloadPlugins) {
                Label("重新加载", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(StatusPopoverStyle.selectionColor)
            .font(.system(size: 11, weight: .medium))
        }
        .frame(minHeight: 28)
    }

    private var errorList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(squatRunner.pluginErrors.enumerated()), id: \.offset) { _, error in
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
