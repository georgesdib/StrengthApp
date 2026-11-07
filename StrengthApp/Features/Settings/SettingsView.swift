import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmingForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    Text(model.pairedServerURL ?? model.serverURLText)
                        .textSelection(.enabled)
                    Text("Plain HTTP on your trusted home network.")
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
