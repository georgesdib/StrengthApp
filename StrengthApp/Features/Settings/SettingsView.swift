import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmingForget = false
    @State private var isSavingServerSettings = false
    @State private var serverSaveMessage: String?

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
