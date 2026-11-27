import SwiftUI
import AuthInjectionKit

struct FeatureChoiceCard: View {
    let feature: SetupFeature
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: feature.symbol).font(.title2).frame(width: 30)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 5) {
                    Text(feature.titleKey.localized).font(.headline)
                    Text(feature.detailKey.localized).font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary).font(.title3)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
            .accessibilityLabel(feature.titleKey.localized)
            .accessibilityValue(selected ? "experience.selected".localized : "experience.notSelected".localized)
            .accessibilityHint(feature.detailKey.localized)
    }
}

struct DeviceReadinessCard: View {
    let status: DeviceReadiness
    let action: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: status.symbol).font(.system(size: 28))
                .foregroundColor(status == .ready ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(status.titleKey.localized).font(.title3.weight(.semibold))
                Text(status.detailKey.localized).font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(status.actionKey.localized, action: action).buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor.opacity(0.15)))
    }
}
