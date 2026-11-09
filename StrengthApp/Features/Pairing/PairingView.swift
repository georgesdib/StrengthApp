import SwiftUI

struct PairingView: View {
    private enum Field: Hashable {
        case server
        case code
        case label
    }

    @ObservedObject var model: AppModel
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Server") {
                        TextField(
                            "http://192.168.1.10:8000",
                            text: $model.serverURLText
                        )
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Server address")
                        .accessibilityIdentifier("server-url")
                        .focused($focusedField, equals: .server)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Use the IP address and port of the machine running strength-coach. "
                         + "Plain HTTP is expected on your trusted home network.")
                }

                Section {
                    LabeledContent("Code") {
                        TextField("1234 5678", text: $model.pairingCodeText)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Pairing code")
                            .accessibilityIdentifier("pairing-code")
                            .focused($focusedField, equals: .code)
                    }
                    LabeledContent("Device label") {
                        TextField("iPhone", text: $model.pairingLabelText)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Device label")
                            .accessibilityIdentifier("pairing-label")
                            .focused($focusedField, equals: .label)
                    }
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("Run strength-coach ios pair on the server and enter the code it prints. "
                         + "The code works once and expires after five minutes.")
                }

                if let error = model.pairingError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Pairing failed: \(error)")
                    }
                }

                Section {
                    Button {
                        Task { await model.pair() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.isPairing {
                                ProgressView()
                            } else {
                                Text("Pair")
                            }
                            Spacer()
                        }
                    }
                    .disabled(model.isPairing)
                    .accessibilityIdentifier("pair-button")
                }

                Section {
                    Text("The app talks only to the server address you enter. After pairing, "
                         + "configure Home Server and Away Server in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("The app uses the iPhone's local-network permission on the first "
                         + "connection; if you deny it, pairing will fail until you allow it in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pair iPhone")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
        }
    }
}
