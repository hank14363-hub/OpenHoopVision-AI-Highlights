import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        ScrollView {
            Text(String(localized: "Settings", bundle: AppLanguage.current.bundle))
                .font(.system(size: 30, weight: .black, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 21).padding(.top, 18).padding(.bottom, 4)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    settingIcon("globe")
                    Text(String(localized: "Language", bundle: AppLanguage.current.bundle))
                    Spacer(minLength: 8)
                    Picker(String(localized: "Language", bundle: AppLanguage.current.bundle), selection: $language) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(verbatim: option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .accessibilityIdentifier("settings.language")
                }
                .frame(height: 52)
                rowDivider
                ConfidenceThresholdControl()
                rowDivider
                ConfidenceThresholdControl(kind: .uncertain)
                rowDivider
                NumericSettingRow(title: String(localized: "Lead-in", bundle: AppLanguage.current.bundle), icon: "backward.end", value: Binding(
                    get: { model.clipSettings.before },
                    set: { model.setClipSettings(before: $0, after: model.clipSettings.after) }
                ), unit: String(localized: "s", bundle: AppLanguage.current.bundle), range: 0...30, fractionDigits: 1, accessibilityID: "settings.clipLeadIn")
                rowDivider
                NumericSettingRow(title: String(localized: "Lead-out", bundle: AppLanguage.current.bundle), icon: "forward.end", value: Binding(
                    get: { model.clipSettings.after },
                    set: { model.setClipSettings(before: model.clipSettings.before, after: $0) }
                ), unit: String(localized: "s", bundle: AppLanguage.current.bundle), range: 0...30, fractionDigits: 1, accessibilityID: "settings.clipLeadOut")
                rowDivider
                DisclosureGroup {
                    Text(String(localized: "Visual candidates require a nearby rim and repeated detections. A readable score strip can add candidates after a stable 1–3 point increase. Score changes need timing review and include at least 8 seconds before and 3 seconds after the estimated event. Missing score graphics do not disable visual detection. Thresholds affect visual candidates; score changes are listed for review. Distant or obscured baskets can still be missed.", bundle: AppLanguage.current.bundle))
                        .font(.system(size: 12)).foregroundStyle(Color.hoopMuted).padding(.bottom, 14)
                } label: {
                    HStack(spacing: 10) {
                        settingIcon("questionmark.circle")
                        Text(String(localized: "Detection Help", bundle: AppLanguage.current.bundle))
                    }
                    .frame(height: 52)
                }
                rowDivider
                infoRow(String(localized: "Version", bundle: AppLanguage.current.bundle),
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                    icon: "info.circle")
            }
            .font(.system(size: 13))
            .padding(.horizontal, 16).padding(.vertical, 4)
            .background(Color.hoopPanel, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(Color.hoopStroke, lineWidth: 1) }
            .padding(.horizontal, 21).padding(.vertical, 12)
        }
        .hoopScreen()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var rowDivider: some View { Divider().overlay(Color.hoopStroke) }

    private func settingIcon(_ name: String) -> some View {
        Image(systemName: name).foregroundStyle(Color.hoopOrange).frame(width: 20)
    }

    private func infoRow(_ title: String, value: String, icon: String, color: Color = .hoopMuted) -> some View {
        HStack(spacing: 10) {
            settingIcon(icon)
            Text(title)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(color).multilineTextAlignment(.trailing)
        }
        .frame(height: 52)
    }
}

struct ConfidenceThresholdControl: View {
    @Environment(AppModel.self) private var model
    var accessibilityPrefix = "settings"
    var kind: ConfidenceThresholdKind = .candidate
    var value: Binding<Double>? = nil

    var body: some View {
        let thresholdBinding = value ?? Binding(
            get: { kind == .candidate ? model.confidenceThreshold : model.uncertainConfidenceThreshold },
            set: {
                if kind == .candidate { model.setConfidenceThreshold($0) }
                else { model.setUncertainConfidenceThreshold($0) }
            }
        )
        NumericSettingRow(
            title: kind == .candidate ? String(localized: "Detection Threshold", bundle: AppLanguage.current.bundle) : String(localized: "Review Threshold", bundle: AppLanguage.current.bundle),
            icon: kind == .candidate ? "scope" : "exclamationmark.triangle",
            value: Binding(
                get: { thresholdBinding.wrappedValue * 100 },
                set: { thresholdBinding.wrappedValue = $0 / 100 }
            ), unit: "%", range: 5...95, fractionDigits: 0,
            accessibilityID: "\(accessibilityPrefix).\(kind == .candidate ? "confidenceThreshold" : "uncertainThreshold")"
        )
    }
}

enum ConfidenceThresholdKind { case candidate, uncertain }

struct NumericSettingRow: View {
    let title: String
    let icon: String
    @Binding var value: Double
    let unit: String
    let range: ClosedRange<Double>
    let fractionDigits: Int
    let accessibilityID: String
    var focusOnAppear = false
    @State private var text = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.hoopOrange).frame(width: 20)
            Text(title)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                TextField(text: $text) { Text(verbatim: "") }
                    .keyboardType(fractionDigits == 0 ? .numberPad : .decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($isEditing)
                    .frame(width: 44)
                    .accessibilityLabel(String(format: String(localized: "settings.value.accessibilityLabel", bundle: AppLanguage.current.bundle), title,
                        unit == "%" ? String(localized: "percent", bundle: AppLanguage.current.bundle) : String(localized: "seconds", bundle: AppLanguage.current.bundle)))
                    .accessibilityIdentifier(accessibilityID)
                Text(unit)
            }
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.hoopOrange)
            .padding(.horizontal, 10).frame(height: 34)
            .background(Color.hoopElevated, in: RoundedRectangle(cornerRadius: 9))
            .frame(minHeight: 44).contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { isEditing = true })
        }
        .frame(height: 52)
        .onAppear { synchronize() }
        .task {
            guard focusOnAppear else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            isEditing = true
        }
        .onChange(of: text) { _, input in
            guard let number = parsed(input), range.contains(number) else { return }
            value = number
        }
        .onChange(of: isEditing) { _, editing in if !editing { commit() } }
        .onChange(of: value) { _, _ in if !isEditing { synchronize() } }
        .onSubmit { commit(); isEditing = false }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if isEditing {
                    Spacer()
                    Button(String(localized: "Done", bundle: AppLanguage.current.bundle)) { commit(); isEditing = false }
                }
            }
        }
    }

    private func parsed(_ input: String) -> Double? {
        guard let number = Double(input.replacingOccurrences(of: ",", with: ".")), number.isFinite else { return nil }
        return number
    }

    private func synchronize() { text = String(format: "%.*f", fractionDigits, value) }
    private func commit() {
        if let number = parsed(text) { value = min(range.upperBound, max(range.lowerBound, number)) }
        synchronize()
    }
}

struct ThresholdEditorSheet: View {
    @Binding var value: Double
    let onApply: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(String(localized: "Adjust Detection Threshold", bundle: AppLanguage.current.bundle))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            NumericSettingRow(
                title: String(localized: "Detection Threshold", bundle: AppLanguage.current.bundle),
                icon: "scope",
                value: $value,
                unit: "%",
                range: 5...95,
                fractionDigits: 0,
                accessibilityID: "analysis.confidenceThreshold",
                focusOnAppear: true
            )

            Button(String(localized: "Filter Again", bundle: AppLanguage.current.bundle), action: onApply)
                .buttonStyle(HoopPrimaryButtonStyle())
        }
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hoopInk.ignoresSafeArea())
        .presentationDetents([.height(230)])
        .presentationDragIndicator(.visible)
    }
}
