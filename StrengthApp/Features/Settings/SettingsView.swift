import SwiftUI
import StrengthCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmingForget = false
    @State private var isSavingServerSettings = false
    @State private var serverSaveMessage: String?
    @State private var deepSeekKeyInput = ""
    @State private var deepSeekStatus: String?
    @State private var isTestingDeepSeek = false
    @AppStorage(WorkoutAutomation.startShortcutKey) private var startShortcutName = ""
    @AppStorage(WorkoutAutomation.endShortcutKey) private var endShortcutName = ""
    @State private var scenes: [SceneSelection] = []
    @State private var startSceneID = WorkoutAutomation.shared.startScene?.sceneID ?? ""
    @State private var endSceneID = WorkoutAutomation.shared.endScene?.sceneID ?? ""
    @State private var automationTestMessage: String?
    @State private var automationTestSucceeded = false
    @State private var isTestingAutomation = false

    private func loadScenes() async {
        let loaded = await WorkoutAutomation.shared.availableScenes()
        scenes = loaded
        // Drop a selection whose scene no longer exists rather than running a stale identifier.
        if !startSceneID.isEmpty, !loaded.contains(where: { $0.sceneID == startSceneID }) {
            startSceneID = ""
        }
        if !endSceneID.isEmpty, !loaded.contains(where: { $0.sceneID == endSceneID }) {
            endSceneID = ""
        }
    }

    private func testShortcut(_ name: String, label: String) {
        guard !isTestingAutomation else { return }
        isTestingAutomation = true
        automationTestMessage = "Testing \(label)…"
        Task {
            let ran = await WorkoutAutomation.shared.test(name)
            automationTestSucceeded = ran
            automationTestMessage = ran
                ? "\(label) ran."
                : "\(label) did not run. Check the name and Shortcuts access."
            isTestingAutomation = false
        }
    }

    private func testScene(_ scene: SceneSelection, label: String) {
        guard !isTestingAutomation else { return }
        isTestingAutomation = true
        automationTestMessage = "Testing \(label)…"
        Task {
            let ran = await WorkoutAutomation.shared.testScene(scene)
            automationTestSucceeded = ran
            automationTestMessage = ran
                ? "\(label) ran."
                : "\(label) did not run. Check the scene and Home access."
            isTestingAutomation = false
        }
    }

    @ViewBuilder
    private var automationTestFeedback: some View {
        if let automationTestMessage {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isTestingAutomation {
                    ProgressView()
                } else {
                    Image(systemName: automationTestSucceeded
                          ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(automationTestSucceeded ? Color.green : Color.red)
                }
                Text(automationTestMessage)
                    .font(.footnote)
                    .foregroundStyle(automationTestSucceeded || isTestingAutomation
                                     ? Color.secondary : Color.red)
            }
            .accessibilityIdentifier("automation-test-result")
        }
    }

    private func availabilityText(_ availability: NarrativeAvailability) -> String {
        switch availability {
        case .available: return "The on-device model is ready."
        case .unavailable(let reason): return reason
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Home Server") {
                        TextField("http://192.168.1.10:8000", text: $model.homeServerText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Away Server") {
                        TextField("http://away.example:8000", text: $model.awayServerText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("Prefer Home Server", isOn: $model.preferHome)
                    LabeledContent("Active") {
                        Text(model.serverSelectionSummary)
                            .foregroundStyle(.secondary)
                    }
                    Text(model.pairedServerURL ?? model.serverURLText)
                        .textSelection(.enabled)
                    Text(model.homeServerStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let error = model.serverSettingsError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if isSavingServerSettings {
                        HStack {
                            ProgressView()
                            Text("Saving…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let serverSaveMessage {
                        Label(serverSaveMessage, systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("server-settings-saved")
                    }
                    Button("Save server settings") {
                        Task {
                            isSavingServerSettings = true
                            serverSaveMessage = nil
                            let saved = await model.saveServerSettings()
                            isSavingServerSettings = false
                            if saved {
                                serverSaveMessage = "Saved"
                            }
                        }
                    }
                    .accessibilityIdentifier("save-server-settings")
                    .disabled(model.isSaving || isSavingServerSettings)
                } header: {
                    Text("Server")
                } footer: {
                    Text("When Prefer Home Server is on, the app checks whether Home Server "
                         + "is reachable and otherwise uses Away Server. Turn it off to use Away "
                         + "Server manually. Both addresses should reach the same paired "
                         + "strength-coach server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Exercise library") {
                    NavigationLink {
                        ExerciseLibraryView(model: model)
                    } label: {
                        Label("Exercises", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("exercise-library-link")
                    Text("Configurations, e1RM and completed working-set history.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("HealthKit") {
                    Toggle(
                        "Readiness from HealthKit",
                        isOn: Binding(
                            get: { model.healthKitEnabled },
                            set: { value in
                                Task { await model.setHealthKitEnabled(value) }
                            }
                        )
                    )
                    .disabled(!model.canUseHealthKit && !model.healthKitEnabled)
                    .accessibilityIdentifier("healthkit-toggle")
                    if let message = model.healthKitState.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Reads only HRV, resting heart rate and bodyweight. No sleep, workouts or write access.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Chat") {
                    Toggle("Chat with your training", isOn: $model.chatEnabled)
                    if model.chatEnabled {
                        Picker("Chat model", selection: $model.chatModelChoice) {
                            ForEach(ChatModelChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .accessibilityIdentifier("chat-model-picker")

                        Toggle("Include plan and prescription data", isOn: $model.chatPlanEnabled)
                            .accessibilityIdentifier("chat-plan-toggle")
                        Text("Adds the current prescription, programme summary and adherence to chat. "
                             + "The model may suggest changes; suggestions are never applied.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if model.chatModelChoice == .deepSeek {
                            SecureField("DeepSeek API key", text: $deepSeekKeyInput)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("deepseek-key-field")
                            HStack {
                                Button("Save key") {
                                    deepSeekStatus = model.saveDeepSeekKey(deepSeekKeyInput)
                                    if model.deepSeekKeyPresent { deepSeekKeyInput = "" }
                                }
                                .accessibilityIdentifier("deepseek-save-key")
                                Button("Test key") {
                                    Task {
                                        isTestingDeepSeek = true
                                        deepSeekStatus = await model.testDeepSeekKey(deepSeekKeyInput)
                                        isTestingDeepSeek = false
                                    }
                                }
                                .disabled(isTestingDeepSeek)
                                .accessibilityIdentifier("deepseek-test-key")
                                if model.deepSeekKeyPresent {
                                    Button("Remove", role: .destructive) {
                                        deepSeekStatus = model.removeDeepSeekKey()
                                    }
                                }
                            }
                            if isTestingDeepSeek {
                                ProgressView()
                            }
                            if model.deepSeekKeyPresent {
                                Text("A key is saved in this iPhone's Keychain.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if let deepSeekStatus {
                                Text(deepSeekStatus)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Text("Only Chat uses this model. Weekly and overview explanations stay on-device. "
                                 + "DeepSeek receives your question and training facts; the key never leaves "
                                 + "the Keychain.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            let availability = FoundationNarrativeGenerator().availability()
                            Text(availabilityText(availability))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("On-device conversation over your own data. Nothing is sent to a server "
                         + "and the conversation is not saved.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Intelligence") {
                    Toggle("Explain training on this iPhone", isOn: $model.narrativeEnabled)
                    if model.narrativeEnabled {
                        Picker("Detail", selection: $model.narrativeDetail) {
                            ForEach(NarrativeDetail.allCases, id: \.self) { detail in
                                Text(detail.title).tag(detail)
                            }
                        }
                        let availability = FoundationNarrativeGenerator().availability()
                        Text(availabilityText(availability))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Uses Apple Intelligence on this iPhone. The facts stay on the device, "
                         + "nothing is sent to a server, and explanations are not saved.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField(
                        "Shortcut when a workout starts",
                        text: $startShortcutName
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    TextField(
                        "Shortcut when a workout ends",
                        text: $endShortcutName
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button("Test start shortcut") {
                        testShortcut(startShortcutName, label: "Start shortcut")
                    }
                    .disabled(startShortcutName.trimmingCharacters(in: .whitespaces).isEmpty
                              || isTestingAutomation)
                    Button("Test end shortcut") {
                        testShortcut(endShortcutName, label: "End shortcut")
                    }
                    .disabled(endShortcutName.trimmingCharacters(in: .whitespaces).isEmpty
                              || isTestingAutomation)
                    automationTestFeedback
                } header: {
                    Text("Workout automation")
                } footer: {
                    Text("Leave a field empty to turn that channel off. The Shortcut runs with no "
                         + "input, and Shortcuts comes to the foreground briefly when a workout starts.")
                }

                Section {
                    Picker("Start scene", selection: $startSceneID) {
                        Text("None").tag("")
                        ForEach(scenes, id: \.sceneID) { scene in
                            Text(scene.label).tag(scene.sceneID)
                        }
                    }
                    Picker("End scene", selection: $endSceneID) {
                        Text("None").tag("")
                        ForEach(scenes, id: \.sceneID) { scene in
                            Text(scene.label).tag(scene.sceneID)
                        }
                    }
                    Button("Test start scene") {
                        if let scene = scenes.first(where: { $0.sceneID == startSceneID }) {
                            testScene(scene, label: "Start scene")
                        }
                    }
                    .disabled(startSceneID.isEmpty || isTestingAutomation)
                    Button("Test end scene") {
                        if let scene = scenes.first(where: { $0.sceneID == endSceneID }) {
                            testScene(scene, label: "End scene")
                        }
                    }
                    .disabled(endSceneID.isEmpty || isTestingAutomation)
                    automationTestFeedback
                    Button("Reload scenes") {
                        Task { await loadScenes() }
                    }
                } header: {
                    Text("Home scenes")
                } footer: {
                    Text("Scene first, then the Shortcut. Home access is requested when scenes load. "
                         + "A missing home or scene is skipped, and the workout is never blocked.")
                }
                .task { await loadScenes() }
                .onChange(of: startSceneID) { _, newValue in
                    WorkoutAutomation.shared.startScene = scenes.first { $0.sceneID == newValue }
                    model.syncSceneMappingToWatch()
                }
                .onChange(of: endSceneID) { _, newValue in
                    WorkoutAutomation.shared.endScene = scenes.first { $0.sceneID == newValue }
                    model.syncSceneMappingToWatch()
                }

                WatchSettingsSection(model: model)

                Section("This device") {
                    if let device = model.device {
                        LabeledContent("Label", value: device.label)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Device id")
                                .font(.subheadline)
                            Text(device.deviceID)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("No device details stored.")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("App version", value: model.appVersion)
                }

                Section {
                    Button("Forget this device", role: .destructive) {
                        confirmingForget = true
                    }
                    .accessibilityIdentifier("forget-device")
                } footer: {
                    Text("This deletes the token from this iPhone only. To invalidate it on the "
                         + "server, run strength-coach ios revoke DEVICE_ID.")
                }

                Section("Pair again") {
                    Text("Forget this device, then run strength-coach ios pair on the server "
                         + "and enter the new code. The server URL is kept so you only need the code.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onChange(of: model.homeServerText) { _, _ in serverSaveMessage = nil }
            .onChange(of: model.awayServerText) { _, _ in serverSaveMessage = nil }
            .onChange(of: model.preferHome) { _, _ in serverSaveMessage = nil }
            .confirmationDialog(
                "Forget this device?",
                isPresented: $confirmingForget,
                titleVisibility: .visible
            ) {
                Button("Forget this device", role: .destructive) {
                    model.forgetDevice()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The token is deleted from this iPhone. You will need a new pairing code to reconnect.")
            }
        }
    }
}
