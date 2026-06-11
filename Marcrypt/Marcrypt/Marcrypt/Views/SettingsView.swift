import SwiftUI
import MarcryptCore

extension Notification.Name {
    static let marcryptClearHistoryRequested = Notification.Name("MarcryptClearHistoryRequested")
}

/// App appearance theme preference
enum AppTheme: String, CaseIterable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var displayName: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}


struct SettingsView: View {
    @AppStorage("AppTheme") private var appThemeRaw = AppTheme.system.rawValue
    @State private var historyCleanupStatus: String?
    @State private var isClearingHistory = false
    @ObservedObject private var processingState = AppProcessingState.shared


    // Global Docx Settings
    @AppStorage("DocxEncryptStructure") private var docxEncryptStructure = false
    @AppStorage("DocxRestrictionMode") private var docxRestrictionMode = 0
    @AppStorage("DocxMarkFinal") private var docxMarkFinal = false

    // Security
    @AppStorage("SecureShredOriginals") private var secureShredOriginals = false
    @AppStorage("PersistentAuditEnabled") private var persistentAuditEnabled = false
    @AppStorage("GenerateBatchReports") private var generateBatchReports = false
    @AppStorage("IncludeFullPathsInBatchReports") private var includeFullPathsInBatchReports = false

    // Watermark
    @AppStorage("WatermarkEnabled") private var watermarkEnabled = false
    @AppStorage("WatermarkSize") private var watermarkSize = 48
    @AppStorage("WatermarkOpacity") private var watermarkOpacity = 0.25
    @AppStorage("WatermarkLocation") private var watermarkLocation = 3 // 3 = Diagonal
    @AppStorage("WatermarkColorHex") private var watermarkColorHex = "#FF0000" // Red default

    // Splitting
    @AppStorage("AutoSplitEnabled") private var autoSplitEnabled = false
    @AppStorage("AutoSplitSizeMB") private var autoSplitSizeMB = 20 // 20MB default

    // Bates Numbering
    @AppStorage("BatesEnabled") private var batesEnabled = false
    @AppStorage("BatesPrefix") private var batesPrefix = ""
    @AppStorage("BatesStartNumber") private var batesStartNumber = 1
    @AppStorage("BatesDigitCount") private var batesDigitCount = 6
    @AppStorage("BatesLocation") private var batesLocation = 2 // Bottom Right
    @AppStorage("BatesFontFamily") private var batesFontFamily = 2 // 0=Sans, 1=Serif, 2=Mono
    @AppStorage("BatesFontSize") private var batesFontSize = 10
    @AppStorage("BatesColorHex") private var batesColorHex = "#000000" // Black default
    @AppStorage("BatesIncludeTimestamp") private var batesIncludeTimestamp = false

    // Metadata Stripping
    @AppStorage("StripMetadataBeforeEncryption") private var stripMetadata = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var appThemeBinding: Binding<AppTheme> {
        Binding(
            get: { AppTheme(rawValue: appThemeRaw) ?? .system },
            set: { appThemeRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text("Encryption Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(CustomColors.primaryText(for: colorScheme))

                Text("Configure how documents are processed and encrypted")
                    .font(.body)
                    .foregroundColor(CustomColors.secondaryText(for: colorScheme))
                    .multilineTextAlignment(.center)
            }

            Form {
                Section("Appearance") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Theme")
                            .font(.system(size: 14, weight: .medium))
                        Text("Choose light, dark, or follow system appearance.")
                            .font(.system(size: 12))
                            .foregroundColor(CustomColors.secondaryText(for: colorScheme))

                        Picker("", selection: appThemeBinding) {
                            ForEach(AppTheme.allCases, id: \.self) { theme in
                                Text(theme.displayName).tag(theme)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("settings_themePicker")
                    }
                    .padding(.vertical, 4)


                     .padding(.vertical, 4)
                }

                Section("Word Protection Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Encrypt Document", isOn: $docxEncryptStructure)
                            .accessibilityIdentifier("settings_encryptStructureToggle")
                        Text("If enabled, the main password set in the app will be used to encrypt the document (password to open).")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Divider()

                        Picker("Apply Other Restrictions", selection: $docxRestrictionMode) {
                            Text("No Restrictions").tag(0)
                            Text("Read Only").tag(1)
                            Text("Comments Only").tag(2)
                            Text("Track Changes").tag(3)
                            Text("Form Fill Only").tag(4)
                        }
                        .pickerStyle(MenuPickerStyle())
                        .accessibilityIdentifier("settings_restrictionPicker")

                         Text("Editing restrictions are advisory and can be bypassed by opening the document in other editors.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Divider()

                        Toggle("Mark as Final", isOn: $docxMarkFinal)
                            .accessibilityIdentifier("settings_markFinalToggle")
                        Text("Advisory read-only status.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Watermark (PDF & DOCX)") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable Watermark", isOn: $watermarkEnabled)
                            .accessibilityIdentifier("settings_watermarkToggle")

                        HStack {
                            Text("Watermark Text")
                                .font(.system(size: 12))
                            Spacer()
                            TextField("", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "WatermarkText") ?? "CONFIDENTIAL" },
                                set: { UserDefaults.standard.set($0, forKey: "WatermarkText") }
                            ))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .disabled(!watermarkEnabled)
                        }

                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                            GridRow {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Size (pt)").font(.system(size: 12)).foregroundColor(.secondary)
                                    Picker("", selection: $watermarkSize) {
                                        ForEach([10, 12, 18, 24, 36, 48, 72, 96, 128], id: \.self) { size in
                                            Text("\(size)pt").tag(size)
                                        }
                                    }.labelsHidden().controlSize(.small).disabled(!watermarkEnabled)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Opacity").font(.system(size: 12)).foregroundColor(.secondary)
                                    HStack {
                                        Slider(value: $watermarkOpacity, in: 0.05...1.0)
                                            .frame(width: 80)
                                        Text(String(format: "%.0f%%", watermarkOpacity * 100))
                                            .font(.caption)
                                            .monospacedDigit()
                                            .frame(width: 35, alignment: .trailing)
                                    }
                                    .disabled(!watermarkEnabled)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Location").font(.system(size: 12)).foregroundColor(.secondary)
                                    Picker("", selection: $watermarkLocation) {
                                        Text("Top Left").tag(1)
                                        Text("Top Center").tag(4)
                                        Text("Top Right").tag(5)
                                        Text("Bottom Left").tag(6)
                                        Text("Bottom Center").tag(7)
                                        Text("Bottom Right").tag(2)
                                        Text("Left Margin").tag(8)
                                        Text("Right Margin").tag(9)
                                        Text("Diagonal").tag(3)
                                        Text("Center").tag(0)
                                    }.labelsHidden().controlSize(.small).disabled(!watermarkEnabled)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Color").font(.system(size: 12)).foregroundColor(.secondary)
                                    Picker("", selection: $watermarkColorHex) {
                                        HStack { Circle().fill(Color.red).frame(width:8); Text("Red") }.tag("#FF0000")
                                        HStack { Circle().fill(Color(nsColor: PdfProcessingService.nsColor(from: "#F2C40D"))).frame(width:8); Text("Gold") }.tag("#F2C40D")
                                        HStack { Circle().fill(Color.orange).frame(width:8); Text("Orange") }.tag("#F28D0F")
                                        HStack { Circle().fill(Color.blue).frame(width:8); Text("Blue") }.tag("#2196F3")
                                        HStack { Circle().fill(Color.purple).frame(width:8); Text("Purple") }.tag("#9457CD")
                                        HStack { Circle().fill(Color.green).frame(width:8); Text("Green") }.tag("#4CAF50")
                                        HStack { Circle().fill(Color.black).frame(width:8); Text("Black") }.tag("#000000")
                                        HStack { Circle().fill(Color.gray).frame(width:8); Text("Gray") }.tag("#9E9E9E")
                                        HStack { Circle().fill(Color.white).stroke(Color.gray).frame(width:8); Text("White") }.tag("#FFFFFF")
                                    }.labelsHidden().controlSize(.small).disabled(!watermarkEnabled)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }


                Section("Bates Numbering") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable Bates Numbering", isOn: $batesEnabled)
                            .accessibilityIdentifier("settings_batesToggle")

                        if batesEnabled {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                                GridRow {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Prefix").font(.system(size: 11)).foregroundColor(.secondary)
                                        TextField("e.g. CASE-", text: $batesPrefix)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 80)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Start Number").font(.system(size: 11)).foregroundColor(.secondary)
                                        TextField("", value: $batesStartNumber, formatter: NumberFormatter())
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 80)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Digits").font(.system(size: 11)).foregroundColor(.secondary)
                                        Picker("", selection: $batesDigitCount) {
                                            ForEach([4, 6, 8, 10], id: \.self) { d in Text("\(d)").tag(d) }
                                        }.labelsHidden().controlSize(.small).frame(width: 60)
                                    }
                                }

                                GridRow {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Location").font(.system(size: 11)).foregroundColor(.secondary)
                                        Picker("", selection: $batesLocation) {
                                            Text("Bottom Right").tag(2)
                                            Text("Bottom Center").tag(7)
                                            Text("Bottom Left").tag(6)
                                            Text("Top Right").tag(5)
                                            Text("Top Center").tag(4)
                                            Text("Top Left").tag(1)
                                        }.labelsHidden().controlSize(.small).frame(width: 110)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Font").font(.system(size: 11)).foregroundColor(.secondary)
                                        Picker("", selection: $batesFontFamily) {
                                            Text("Sans Serif").tag(0)
                                            Text("Serif").tag(1)
                                            Text("Mono").tag(2)
                                        }.labelsHidden().controlSize(.small).frame(width: 90)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Size").font(.system(size: 11)).foregroundColor(.secondary)
                                        Picker("", selection: $batesFontSize) {
                                            ForEach([8, 9, 10, 11, 12, 14], id: \.self) { s in Text("\(s)pt").tag(s) }
                                        }.labelsHidden().controlSize(.small).frame(width: 60)
                                    }
                                }

                                GridRow {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Color").font(.system(size: 11)).foregroundColor(.secondary)
                                        Picker("", selection: $batesColorHex) {
                                            HStack { Circle().fill(Color.black).frame(width:8); Text("Black") }.tag("#000000")
                                            HStack { Circle().fill(Color.red).frame(width:8); Text("Red") }.tag("#FF0000")
                                            HStack { Circle().fill(Color.blue).frame(width:8); Text("Blue") }.tag("#2196F3")
                                            HStack { Circle().fill(Color.gray).frame(width:8); Text("Gray") }.tag("#9E9E9E")
                                        }.labelsHidden().controlSize(.small).frame(width: 110)
                                    }

                                    GridRow(alignment: .bottom) {
                                        Toggle("Include Timestamp", isOn: $batesIncludeTimestamp)
                                            .controlSize(.small)
                                            .font(.system(size: 11))
                                            .gridCellColumns(2)
                                    }
                                }
                            }

                            Divider().padding(.vertical, 4)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Preview:")
                                    .font(.system(size: 11)).foregroundColor(.secondary)

                                Text("\(batesPrefix)\(String(format: "%0\(batesDigitCount)d", batesStartNumber))\(batesIncludeTimestamp ? " | \(Int(Date().timeIntervalSince1970))" : "")")
                                    .font(batesFontFamily == 2 ? .system(size: 12, design: .monospaced) :
                                          batesFontFamily == 1 ? .system(size: 12, design: .serif) :
                                          .system(size: 12))
                                    .foregroundColor(Color(nsColor: PdfProcessingService.nsColor(from: batesColorHex)))
                                    .padding(8)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .cornerRadius(4)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.2)))
                            }
                        }

                        Text("Stamps sequential page numbers for legal discovery compliance.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Metadata Stripping") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Strip Metadata Before Encryption", isOn: $stripMetadata)
                            .accessibilityIdentifier("settings_stripMetadataToggle")

                        Text("Removes Author, Title, Creator, Producer, and other identifying metadata from PDF and DOCX files before encryption.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        if stripMetadata {
                            Text("ℹ️ Metadata is stripped into a temp copy. Originals are unmodified unless shredding is enabled.")
                                .font(.system(size: 11))
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Auto-Split Large Files") {
                     VStack(alignment: .leading, spacing: 12) {
                         Toggle("Auto-Split Encrypted Archives", isOn: $autoSplitEnabled)

                         HStack(alignment: .firstTextBaseline) {
                             Text("Split items larger than:")
                                 .font(.system(size: 12))
                             TextField("", value: $autoSplitSizeMB, formatter: NumberFormatter())
                                 .labelsHidden()
                                 .textFieldStyle(.roundedBorder)
                                 .frame(width: 60)
                             Text("MB")
                                 .font(.system(size: 12))
                         }
                         .disabled(!autoSplitEnabled)

                         Text("Applies to ZIP and PDF files. PDFs are split by estimated page count based on size.")
                             .font(.system(size: 12))
                             .foregroundColor(.secondary)
                     }
                     .padding(.vertical, 4)
                }

                Section("Original File Cleanup") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Overwrite & Remove Original Files After Encryption", isOn: $secureShredOriginals)
                            .accessibilityIdentifier("settings_shredToggle")

                        Text("Overwrites each original file before removing it after successful encryption. This is best-effort cleanup and cannot guarantee physical erasure on SSDs or APFS.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        if secureShredOriginals {
                            Text("⚠️ Warning: This action cannot be undone.")
                                .font(.system(size: 12))
                                .fontWeight(.bold)
                                .foregroundColor(CustomColors.destructiveColor(for: colorScheme))

                            Text("Note: SSD wear-leveling and APFS copy-on-write can leave prior data blocks outside app control.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("History & Debug") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable Debug Logging", isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: "EnableDebugLogging") },
                            set: { UserDefaults.standard.set($0, forKey: "EnableDebugLogging") }
                        ))

                        Text("When enabled, the app writes verbose diagnostics to logs for troubleshooting. This may impact performance.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Toggle("Keep Persistent Audit History", isOn: $persistentAuditEnabled)
                            .accessibilityIdentifier("settings_persistentAuditToggle")

                        Text("When enabled, Marcrypt writes audit events to Application Support. Audit entries include document names, hashes, operations, and outcomes.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Toggle("Generate Batch Reports", isOn: $generateBatchReports)
                            .accessibilityIdentifier("settings_batchReportsToggle")

                        Toggle("Include Full Paths In Batch Reports", isOn: $includeFullPathsInBatchReports)
                            .disabled(!generateBatchReports)
                            .accessibilityIdentifier("settings_fullPathsToggle")

                        Text("Batch reports are written beside processed output and can include filenames, hashes, and optional full paths. Leave full paths off unless the report itself will be handled as confidential.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        HStack {
                            Button("Open App Log") {
                                LogManager.shared.openLogFile()
                            }
                            Button("Clear History", role: .destructive) {
                                clearHistory()
                            }
                            .disabled(processingState.isProcessing || isClearingHistory)
                        }
                        .controlSize(.small)

                        Text("Clear History removes app logs, audit history, temporary processing files, dropped attachment staging, and the current in-app file list.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        if let status = historyCleanupStatus {
                            Text(status)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(status == "History cleared." ? .green : .orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("settingsForm")

            Spacer()

            // Footer Action
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(CustomColors.accentColor(for: colorScheme))
                .accessibilityIdentifier("settings_doneButton")
            }
        }
        .padding(32)
        .frame(width: 500, height: 650)
        .background(CustomColors.cardBackground(for: colorScheme))
    }

    private func clearHistory() {
        guard !processingState.isProcessing else {
            historyCleanupStatus = "Clear History is unavailable while files are processing."
            return
        }

        isClearingHistory = true
        historyCleanupStatus = "Clearing history..."

        Task {
            let result = await HistoryCleanupService.shared.clearHistoryAsync()

            await MainActor.run {
                NotificationCenter.default.post(name: .marcryptClearHistoryRequested, object: nil)
                historyCleanupStatus = result.succeeded
                    ? "History cleared."
                    : "History cleared with \(result.failedPaths.count) cleanup error(s)."
                isClearingHistory = false
            }
        }
    }
}
