import AVFoundation
import SwiftUI

struct MainWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var loginItem: LoginItemManager
    @ObservedObject var location: AppLocationManager
    @ObservedObject var updater: AppUpdater

    var body: some View {
        HSplitView {
            settings
                .frame(minWidth: 400, idealWidth: 460, maxWidth: 520)
            preview
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1160, minHeight: 920)
        .background(NativeWindowStyle(minimumContentSize: CGSize(width: 1160, height: 920)))
        .onAppear {
            location.checkLocation()
            installer.prepareForActivation = model.prepareForExtensionUpdate
            installer.captureSuspensionChanged = model.setCaptureSuspended
            model.setCaptureSuspended(installer.blocksCapture)
            installer.refreshCamera = model.refreshCameras
            installer.checkForUpgrade()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshCameras()
            if installer.state == .awaitingApproval || installer.state == .disabled { installer.refresh() }
        }
        .onReceive(model.$virtualCameraStatus) { installer.observeCameraStatus($0) }
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

    private var settings: some View {
        Form {
            Section("Camera") {
                Picker("Source", selection: Binding(get: { model.selectedCameraID }, set: model.selectCamera)) {
                    if model.cameras.isEmpty { Text("No cameras found").tag("") }
                    ForEach(model.cameras) { Text($0.name).tag($0.id) }
                }
                .disabled(model.isBusy)
                Button("Refresh Cameras", action: model.retryCamera)
                Text("Your camera starts when a video app uses MovemberCam and stops when it is no longer in use.")
                    .font(.caption).foregroundStyle(.secondary)
            }

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
                Text("The QR destination opens when scanned. The written URL is displayed below it.")
            }

            Section("Overlay") {
                Picker("QR position", selection: $model.draft.corner) {
                    ForEach(OverlayConfiguration.Corner.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Mirror camera image", isOn: $model.draft.mirrorCamera)
                Text("The logo, QR code and URL stay readable when mirroring.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(model.isApplying ? "Applying…" : "Apply Changes", action: model.apply)
                        .disabled(!model.hasChanges || model.validationMessage != nil || model.isApplying)
                }
                if let validation = model.validationMessage {
                    Text(validation).font(.caption).foregroundStyle(.red)
                } else if model.hasChanges {
                    Text("Changes have not been applied.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Virtual Camera") {
                if !location.isInApplications {
                    Button("Move to Applications and Restart", action: location.moveAndRestart)
                        .disabled(location.isMoving)
                }
                extensionControls
            }

            Section("Startup") {
                LoginItemControls(manager: loginItem)
            }
        }
        .formStyle(.grouped)
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Camera Preview").font(.headline)
                ZStack {
                    Color.black
                    VideoPreviewSurface(feed: model.previewFeed)
                    if !model.isRunning {
                        Label(model.isBusy ? "Updating camera…" : "Waiting for a video app", systemImage: "video.slash")
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(10)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .aspectRatio(model.previewFormat.aspectRatio, contentMode: .fit)
                .accessibilityLabel("Camera preview with fundraising overlay")

                HStack {
                    Text(installer.busy ? "Updating virtual camera…" :
                        installer.state == .unavailable ? "Restart MovemberCam to reconnect" : model.outputStatus)
                    Spacer()
                    Text(model.isRunning
                         ? "Auto · \(model.previewFormat.width) × \(model.previewFormat.height) · Up to 30 fps"
                         : "Auto resolution · Up to 30 fps").foregroundStyle(.secondary)
                }.font(.caption)

                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).font(.callout)
                    if model.cameraDenied {
                        Button("Open Camera Settings", action: model.openCameraSettings)
                    }
                }

                GroupBox("Using MovemberCam in Zoom") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Choose MovemberCam in Zoom → Settings → Video & effects. Your camera starts automatically while Zoom uses it.")
                            .font(.callout)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                GroupBox("Updates") {
                    UpdateControls(updater: updater)
                }
                Text("Closing this window keeps MovemberCam running in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var extensionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if installer.isReady && model.virtualCameraStatus.isUsable {
                Label("Virtual camera ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    if installer.busy { ProgressView().controlSize(.small) }
                    Text(installer.message).font(.callout).textSelection(.enabled)
                }
                if let title = installer.recoveryAction.title, location.isInApplications {
                    Button(title, action: recoverExtension)
                        .buttonStyle(.borderedProminent)
                        .disabled(!installer.recoveryEnabled ||
                            (installer.recoveryAction == .restartApp && (model.isBusy || location.isMoving)))
                }
            }
        }
    }

    private func recoverExtension() {
        switch installer.recoveryAction {
        case .install: installer.install()
        case .retry: installer.refresh()
        case .openSettings: installer.openSettings()
        case .restartApp:
            model.prepareForRestart {
                installer.noteAppRestart()
                location.restart()
            }
        case .none: break
        }
    }
}
