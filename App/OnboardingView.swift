import AVFoundation
import SwiftUI

private enum SetupStage: Int, CaseIterable {
    case camera, installation, zoom, check
    var title: String {
        switch self {
        case .camera: return "Your Camera"
        case .installation: return "Virtual Camera"
        case .zoom: return "Zoom"
        case .check: return "Check Your Setup"
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var loginItem: LoginItemManager
    @ObservedObject var location: AppLocationManager
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @AppStorage("MovemberCam.setupStep.v1") private var step = 0
    @AppStorage("MovemberCam.setupCompleted.v1") private var completed = false
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var inMeeting = false
    @AppStorage("MovemberCam.zoomConfirmed.v1") private var confirmedZoom = false
    @State private var requestingCameraAccess = false
    @State private var returningFromCameraSettings = false

    private var stage: SetupStage { SetupStage(rawValue: step) ?? .camera }
    private var previewBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MovemberCamPreviewBuild") as? String == "YES"
    }
    private var readiness: SetupReadiness {
        SetupReadiness(cameraAccessAllowed: permission == .authorized, isInApplications: location.isInApplications,
            virtualCameraAvailable: model.virtualCameraAvailable, zoomConfirmed: confirmedZoom)
    }
    private var ready: Bool { readiness.canFinish }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Set up MovemberCam").font(.title2.bold())
                HStack(spacing: 16) {
                    ForEach(SetupStage.allCases, id: \.rawValue) { item in
                        Button {
                            step = item.rawValue
                        } label: {
                            Label(item.title, systemImage: "\(item.rawValue + 1).circle\(stage == item ? ".fill" : "")")
                                .foregroundStyle(stage == item ? Color.accentColor : Color.secondary)
                        }.buttonStyle(.plain)
                    }
                }.font(.callout)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(stage.title).font(.title3.bold())
                    switch stage {
                    case .camera: cameraStep
                    case .installation: installationStep
                    case .zoom: zoomStep
                    case .check: checkStep
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            Divider()
            HStack(spacing: 12) {
                Button("Set Up Later") { dismissWindow(id: "setup") }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Step \(stage.rawValue + 1) of 4").foregroundStyle(.secondary).font(.caption)
                Button("Back") { step = max(0, stage.rawValue - 1) }.disabled(stage == .camera)
                Button(stage == .check ? "Finish Setup" : "Continue") {
                    if stage == .check {
                        completed = true
                        dismissWindow(id: "setup")
                    } else { step = stage.rawValue + 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(stage == .check && !ready)
            }.padding(20)
        }
        .frame(minWidth: 760, minHeight: 640)
        .background(NativeWindowStyle())
        .onAppear {
            if completed { confirmedZoom = true }
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
            if returningFromCameraSettings {
                returningFromCameraSettings = false
                openWindow(id: "setup")
            }
        }
        .onChange(of: model.isBusy) { _, busy in if !busy { refresh() } }
    }

    private var cameraStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose the real camera you want to use. MovemberCam adds your logo, QR code and URL to that feed.")
            Picker("Camera", selection: Binding(get: { model.selectedCameraID }, set: model.selectCamera)) {
                if model.cameras.isEmpty { Text("No cameras found").tag("") }
                ForEach(model.cameras) { Text($0.name).tag($0.id) }
            }.disabled(model.isBusy)

            if permission == .authorized {
                Label("Camera access allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text(permission == .notDetermined
                     ? "macOS will ask whether MovemberCam can use your camera. Choose Allow."
                     : "Allow MovemberCam in System Settings → Privacy & Security → Camera, then return to this guide.")
                Button(requestingCameraAccess ? "Waiting for Permission…" : permission == .notDetermined
                       ? "Allow Camera Access…" : "Open Camera Settings…", action: allowCameraAccess)
                    .disabled(requestingCameraAccess)
            }
            GroupBox("Your Fundraiser") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("QR destination", text: $model.draft.qrURL)
                    TextField("Written URL", text: $model.draft.displayURL)
                    HStack {
                        Text("These links are saved in preferences.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save Links", action: model.apply)
                            .disabled(!model.hasChanges || model.validationMessage != nil || model.isApplying)
                    }
                    if let validation = model.validationMessage { Text(validation).font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            GroupBox("Startup") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Would you like MovemberCam to open automatically when you log in?")
                    LoginItemControls(manager: loginItem)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
        }
    }

    private var installationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if readiness.installationComplete {
                Label("MovemberCam is available as a camera", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("The virtual camera is already installed and enabled. This step is complete.")
                Text("Continue to check your Zoom camera selection.").foregroundStyle(.secondary)
            } else {
                Text("Install MovemberCam’s virtual camera once so Zoom can see it as a camera source.")
                Label("Virtual camera not available yet", systemImage: "info.circle").foregroundStyle(.secondary)
                if previewBuild {
                    Text("This preview can show your overlay. Installing the Zoom camera requires the signed version of the app.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                instruction(1, "Open MovemberCam from Applications.", detail: "Move the app to your Applications folder before installing the camera.")
                if !location.isInApplications {
                    Button("Move to Applications and Restart", action: location.moveAndRestart)
                        .disabled(location.isMoving)
                }
                instruction(2, "Install the virtual camera.", detail: "Click the button below, then follow the macOS approval prompt.")
                HStack {
                    Button(installer.busy ? "Installing…" : "Install Virtual Camera", action: installer.install)
                        .disabled(previewBuild || installer.busy || model.virtualCameraAvailable)
                    Button("Check Again", action: refresh)
                }
                instruction(3, "Approve MovemberCam in System Settings.", detail: "On recent macOS versions: General → Login Items & Extensions → Camera Extensions. Enable MovemberCam, then return here.")
                Button("Open System Settings", action: installer.openSettings)
                Text(installer.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if installer.needsAppRestart {
                    Button("Restart MovemberCam", action: location.restart)
                }
                Text("You can continue to preview the Zoom instructions while installation is pending.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var zoomStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Start your camera in MovemberCam first, then choose MovemberCam as the camera Zoom uses.")
            HStack {
                Button(model.isRunning ? "Camera Running" : "Start Camera", action: model.start)
                    .disabled(model.isRunning || model.isBusy || model.selectedCameraID.isEmpty)
                Button("Open Zoom", action: openZoom)
            }
            Picker("Where are you in Zoom?", selection: $inMeeting) {
                Text("Before a Meeting").tag(false)
                Text("During a Call").tag(true)
            }.pickerStyle(.segmented)
            if inMeeting {
                instruction(1, "Find Video in Zoom’s meeting toolbar.", detail: "Click the small up arrow next to Video (or Start / Stop Video).")
                instruction(2, "Choose MovemberCam under Select a Camera.", detail: "Your existing call continues with the overlaid feed. The main Video button switches video on or off; its arrow opens camera choices.")
                Link("Zoom’s guide to meeting controls", destination: URL(string: "https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0062674")!)
            } else {
                instruction(1, "Open Zoom Settings → Video & effects.", detail: "In Zoom, press ⌘, or click the Settings gear. Select Video & effects in the sidebar.")
                screenshot("ZoomVideoEffects", description: "Zoom Settings sidebar with Video & effects selected", maxHeight: 150)
                instruction(2, "Open the Camera menu and choose MovemberCam.", detail: "Use the Camera selector shown below. MovemberCam appears after the virtual camera is installed and approved.")
                screenshot("ZoomCameraSelection", description: "Zoom Video settings showing the Camera drop-down menu", maxHeight: 230)
                Text("Example: Zoom Workplace 7.2.2. The screenshot shows the selector before MovemberCam is installed; choose MovemberCam from that menu on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Zoom’s guide to video settings", destination: URL(string: "https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0060612")!)
            }
            DisclosureGroup("MovemberCam isn’t listed in Zoom") {
                Text("Check that the virtual camera is installed and enabled in System Settings. Fully quit and reopen Zoom after installing. Keep MovemberCam open with its camera running. If macOS asks Zoom for camera access, allow it.")
                    .font(.callout).padding(.top, 8)
            }
        }
    }

    private var checkStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(permission == .authorized ? "Camera access allowed" : "Camera access still needed",
                  systemImage: permission == .authorized ? "checkmark.circle" : "circle")
            Label(model.virtualCameraAvailable ? "Virtual camera available" : "Virtual camera installation still needed",
                  systemImage: model.virtualCameraAvailable ? "checkmark.circle" : "circle")
            if !model.virtualCameraAvailable {
                Button("Return to Camera Installation") { step = SetupStage.installation.rawValue }
            }
            instruction(1, "Check Zoom’s video preview.", detail: "You should see your real camera feed with the Movember logo, QR code and written URL.")
            instruction(2, "Scan the QR code from another device.", detail: "Confirm that it opens your configured fundraising page. Zoom’s mirrored self-view affects only your local preview.")
            instruction(3, "Try the menu bar toggle.", detail: "Open MovemberCam’s moustache menu and disable the overlay. Your real camera feed should continue. Re-enable the overlay when you’re ready.")
            Toggle("I selected MovemberCam in Zoom and checked the QR code.", isOn: $confirmedZoom)
            Text("Keep MovemberCam running during calls. Closing its settings window leaves the app in the menu bar. Use Quit MovemberCam to stop it completely.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func instruction(_ number: Int, _ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "\(number).circle").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func screenshot(_ name: String, description: String, maxHeight: CGFloat) -> some View {
        Group {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Label("Screenshot could not be loaded", systemImage: "photo")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(description)
    }

    private func refresh() {
        permission = AVCaptureDevice.authorizationStatus(for: .video)
        model.refreshCameras()
    }

    private func allowCameraAccess() {
        if permission == .denied || permission == .restricted {
            returningFromCameraSettings = true
            model.openCameraSettings()
            return
        }
        guard !requestingCameraAccess else { return }
        requestingCameraAccess = true
        let guideWindow = NSApp.keyWindow
        Task { @MainActor in
            // Permission is its own onboarding action. Starting capture is a later, explicit step.
            _ = await AVCaptureDevice.requestAccess(for: .video)
            requestingCameraAccess = false
            refresh()
            openWindow(id: "setup")
            NSApp.activate(ignoringOtherApps: true)
            guideWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func openZoom() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "us.zoom.xos") else {
            NSWorkspace.shared.open(URL(string: "https://zoom.us/download")!)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
