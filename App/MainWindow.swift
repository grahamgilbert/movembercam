import AVFoundation
import SwiftUI

struct MainWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var loginItem: LoginItemManager
    @ObservedObject var location: AppLocationManager
    @ObservedObject var updater: AppUpdater
    @ObservedObject var attention: CameraAttentionController
    var onPreviewTabChanged: (Bool) -> Void

    enum SettingsTab: String { case camera, overlay, app }
    @AppStorage("MovemberCam.settingsTab") var selectedTab = SettingsTab.camera

    var body: some View {
        VStack(spacing: 0) {
            if let issue = attention.issue {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.title).font(.headline)
                        Text(issue.message).font(.callout).textSelection(.enabled)
                        if attention.notificationsAvailable == false {
                            Text("Notifications are off. Camera warnings remain in the menu bar.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if issue.recovery != .showSettings {
                        VStack(alignment: .trailing, spacing: 8) {
                            Button(issue.recovery.title, action: attention.recover)
                                .disabled(!attention.canRecover)
                            if issue.recovery == .restartZoom {
                                Button("Camera is already listed", action: attention.acknowledgeZoomCamera)
                            }
                        }
                    }
                }.padding(16).background(Color.orange.opacity(0.1))
                Divider()
            }
            TabView(selection: $selectedTab) {
                cameraTab
                    .tabItem { Label("Camera", systemImage: "video") }.tag(SettingsTab.camera)
                overlayTab
                    .tabItem { Label("Overlay", systemImage: "qrcode") }.tag(SettingsTab.overlay)
                appTab
                    .tabItem { Label("App", systemImage: "gearshape") }.tag(SettingsTab.app)
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 420)
        .background(NativeWindowStyle(minimumContentSize: CGSize(width: 860, height: 560)))
        .onAppear {
            location.checkLocation()
            onPreviewTabChanged(selectedTab != .app)
        }
        .onChange(of: selectedTab) { _, tab in onPreviewTabChanged(tab != .app) }
        .onDisappear { onPreviewTabChanged(false) }
        .alert("Move MovemberCam to Applications?", isPresented: $location.isOfferingMove) {
            Button("Move to Applications and Restart", action: location.moveAndRestart)
            Button("Quit", role: .cancel) { NSApp.terminate(nil) }
        } message: {
            Text("The virtual camera can only be installed when MovemberCam runs from Applications. \(location.replacesExistingCopy ? "This will replace the installed copy, keeping the old one in Trash. " : "")Your saved preferences will be preserved.")
        }
        .alert("Couldn’t Move MovemberCam", isPresented: Binding(get: { location.error != nil }, set: { if !$0 { location.error = nil } })) {
            Button("Try Again", action: location.moveAndRestart)
            Button("Show in Finder and Quit") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                NSApp.terminate(nil)
            }
            Button("Quit", role: .cancel) { NSApp.terminate(nil) }
        } message: { Text(location.error ?? "") }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.isOverlayEnabled.toggle()
                } label: {
                    Text(model.isOverlayEnabled ? "Disable Overlay" : "Enable Overlay")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .fixedSize()
                if model.cameraControls.action != nil {
                    Button(action: model.performCameraAction) {
                        Text(model.cameraControls.title)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .disabled(!model.cameraControls.isEnabled)
                }
            }
        }
    }

    private var cameraTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Camera", selection: Binding(get: { model.selectedCameraID }, set: model.selectCamera)) {
                    if model.cameras.isEmpty { Text("No cameras found").tag("") }
                    ForEach(model.cameras) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 460)
                .disabled(model.isBusy)
                Button("Refresh Cameras", action: model.retryCamera).disabled(model.isBusy)
                Spacer(minLength: 0)
            }
            Text("Your camera runs while this preview is visible or a video app uses MovemberCam.")
                .font(.caption).foregroundStyle(.secondary)
            preview
            Text("In Zoom, choose MovemberCam in Settings → Video & effects.")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(16)
    }

    private var overlayTab: some View {
        HSplitView {
            Form {
                Section {
                    TextField("QR destination", text: $model.draft.qrURL,
                              prompt: Text("https://movember.com/t/musta-ch"))
                        .accessibilityLabel("QR code destination")
                    TextField("Written URL", text: $model.draft.displayURL,
                              prompt: Text("https://movember.com/t/musta-ch"))
                        .accessibilityLabel("Written URL")
                } header: {
                    Text("Fundraising Links")
                } footer: {
                    Text("The QR destination opens when scanned. The written URL appears below it.")
                }
                Section("Appearance") {
                    Picker("QR position", selection: $model.draft.corner) {
                        ForEach(OverlayConfiguration.Corner.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Mirror camera image", isOn: $model.draft.mirrorCamera)
                    Text("The logo, QR code and URL stay readable when mirroring.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(model.isApplying ? "Applying…" : "Apply Changes", action: model.apply)
                        .disabled(!model.hasChanges || model.validationMessage != nil || model.isApplying)
                    if let validation = model.validationMessage {
                        Text(validation).font(.caption).foregroundStyle(.red)
                    } else if model.hasChanges {
                        Text("Changes have not been applied.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            preview
                .padding(16)
                .frame(minWidth: 360, maxWidth: .infinity)
        }
    }

    private var appTab: some View {
        Form {
            Section("Virtual Camera") {
                if !location.isInApplications {
                    Button("Move to Applications and Restart", action: location.moveAndRestart)
                        .disabled(location.isMoving)
                }
                extensionControls
            }
            Section("Startup") { LoginItemControls(manager: loginItem) }
            Section("Updates") { UpdateControls(updater: updater) }
            Section {
                Text("Closing this window keeps MovemberCam running in the menu bar.")
                    .foregroundStyle(.secondary)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                let width = min(geometry.size.width, geometry.size.height * model.previewFormat.aspectRatio)
                ZStack {
                    Color.black
                    VideoPreviewSurface(feed: model.previewFeed)
                    if !model.isRunning {
                        Label(model.previewStatus, systemImage: "video.slash")
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(10)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(width: width, height: width / model.previewFormat.aspectRatio)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .accessibilityLabel("Camera preview with fundraising overlay")
            }
            .frame(minHeight: 180)
            VStack(alignment: .leading, spacing: 4) {
                Text(installer.state.connectionSummary ?? model.outputStatus)
                Text(model.isRunning
                     ? "Auto · \(model.previewFormat.width) × \(model.previewFormat.height) · Up to 30 fps"
                     : "Auto resolution · Up to 30 fps").foregroundStyle(.secondary)
            }.font(.caption)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.callout)
                if model.cameraDenied { Button("Open Camera Settings", action: model.openCameraSettings) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var extensionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if attention.issue?.kind == .videoAppRestart {
                Label("Restart Zoom to finish camera setup", systemImage: "arrow.clockwise")
                    .foregroundStyle(.orange)
            } else if installer.isReady && model.virtualCameraStatus.isUsable {
                Label("Virtual camera ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    if installer.showsProgress { ProgressView().controlSize(.small) }
                    Text(installer.message).font(.callout).textSelection(.enabled)
                }
                if installer.offersStatusCheck && location.isInApplications {
                    Button(installer.isCheckingStatus ? "Checking Status…" : "Recheck Camera Status", action: installer.refresh)
                        .disabled(installer.isCheckingStatus)
                }
                if let title = installer.recoveryAction.title, location.isInApplications {
                    Button(title, action: recoverExtension)
                        .buttonStyle(.borderedProminent)
                        .disabled(!installer.recoveryEnabled ||
                            (installer.recoveryAction == .restartApp && (model.isBusy || location.isMoving)))
                }
                if installer.offersAppRestart {
                    Button("Restart MovemberCam", action: restartApp)
                        .disabled(model.isBusy || location.isMoving)
                }
            }
        }
    }

    private func restartApp() {
        model.prepareForRestart {
            installer.noteAppRestart()
            location.restart()
        }
    }

    private func recoverExtension() {
        switch installer.recoveryAction {
        case .install: installer.install()
        case .retry: installer.refresh()
        case .reconnect: installer.retryConnection()
        case .repairRegistration: installer.repairRegistration()
        case .openSettings: installer.openSettings()
        case .restartApp: restartApp()
        case .none: break
        }
    }
}
