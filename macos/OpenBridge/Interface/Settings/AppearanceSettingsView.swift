//
//  AppearanceSettingsView.swift
//  OpenBridge
//
//  Created by Claude Code on 11/9/25.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(SettingsManager.self) private var settingsManager

    private var languages: [String] {
        AppLanguageSelection.availableLocalizations(from: Bundle.main.localizations)
    }

    var body: some View {
        @Bindable var settingsManager = settingsManager

        Form {
            Section {
                SettingInfoBanner(
                    iconName: "paintbrush",
                    title: "Appearance",
                    info: "Customize the look and feel of OpenBridge"
                )
            }

            Section {
                VStack(alignment: .leading, spacing: 24) {
                    // Appearance Setting
                    SettingOptionPicker(
                        title: "Appearance",
                        options: Appearance.allCases,
                        selection: $settingsManager.appearance,
                        animateSelection: false
                    ) { appearance, isSelected in
                        appearancePreview(for: appearance, isSelected: isSelected)
                    } label: { appearance, _ in
                        appearance.displayName
                    }
                    .onChange(of: settingsManager.appearance) { _, newAppearance in
                        NSApp.appearance = newAppearance.nsAppearance
                    }

                    Divider()

                    // Accent Color Setting
                    SettingOptionPicker(
                        title: "Accent color",
                        options: SystemAccentColor.allCases,
                        selection: $settingsManager.accentColorName
                    ) { color, isSelected in
                        Circle()
                            .fill(color.color)
                            .frame(width: 24, height: 24, alignment: .center)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color(NSColor.windowBackgroundColor), lineWidth: isSelected ? 2 : 0)
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(settingsManager.accentColor, lineWidth: isSelected ? 3 : 0)
                                    .padding(-2)
                            )
                    } label: { color, isSelected in
                        isSelected ? color.displayName : nil
                    }
                }
                .padding(.vertical, 8)

                languageSetting
            }

            Section {
                SettingOptionPicker(
                    title: "App icon",
                    options: AppIcon.allCases,
                    selection: $settingsManager.appIcon
                ) { icon, isSelected in
                    iconView(for: icon, isSelected: isSelected)
                } label: { icon, _ in
                    icon.displayName
                }
                .onChange(of: settingsManager.appIcon) { _, newIcon in
                    newIcon.apply()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }
}

extension AppearanceSettingsView {
    @ViewBuilder
    private func appearancePreview(for appearance: Appearance, isSelected: Bool) -> some View {
        let previewContent = switch appearance {
        case .light:
            AnyView(
                Image("AppearanceLight")
            )

        case .dark:
            AnyView(
                Image("AppearanceDark")
            )

        case .system:
            AnyView(
                Image("AppearanceAuto")
            )
        }

        previewContent
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? settingsManager.accentColor : Color.clear, lineWidth: 3)
            )
    }

    private func iconView(for icon: AppIcon, isSelected: Bool) -> some View {
        Image(nsImage: icon.image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.blue, lineWidth: isSelected ? 2 : 0)
            )
    }

    private var languageSetting: some View {
        Picker("Language", selection: languageSelection) {
            ForEach(languages, id: \.self) { code in
                Text(AppLanguageSelection.displayName(for: code)).tag(code)
            }
        }
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: {
                AppLanguageSelection.resolvedSelection(
                    for: settingsManager.language,
                    availableLocalizations: languages
                )
            },
            set: { language in
                settingsManager.language = language
            }
        )
    }
}

#Preview {
    AppearanceSettingsView()
        .environment(SettingsManager()).frame(minHeight: 600)
}
