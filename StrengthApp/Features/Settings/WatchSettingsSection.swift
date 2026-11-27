import StrengthCore
import SwiftUI

struct WatchSettingsSection: View {
    @ObservedObject var watch: WatchPairingCoordinator
    @State private var confirmingRevoke = false

    init(model: AppModel) {
        _watch = ObservedObject(wrappedValue: model.watchPairing)
    }

    var body: some View {
        Section {
            LabeledContent("Status") {
                Text(watch.statusText)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch-status")
            }
            if let link = watch.link {
                LabeledContent("Watch", value: link.label)
                LabeledContent("Credential epoch", value: String(link.epoch))
                if let lastAck = watch.lastAckText {
                    LabeledContent("Last acknowledged", value: lastAck)
                }
            }
            // Always shown: "not reported yet" is the honest state before the watch app has
            // written to this phone, and the pair of rows is what answers "did the install
            // actually reach the wrist?".
            LabeledContent("Phone build", value: BuildStamp.current)
                .accessibilityIdentifier("phone-build")
            LabeledContent("Watch build", value: watch.watchBuild ?? "unknown")
                .accessibilityIdentifier("watch-build")
            if let error = watch.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("watch-error")
            }
            Button("Test watch connection") {
                watch.testConnectivity()
            }
            .disabled(!watch.isWatchPaired || watch.link?.revoked == true)
            .accessibilityIdentifier("watch-test-connection-phone")
            if let spike = watch.connectivitySpikeStatus {
                Text(spike)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch-spike-status")
            }
            Button {
                Task {
                    await watch.pair()
                    // A watch rest is reported to the phone in the background; the tap-able
                    // notification is the only way to surface it while ActivityKit cannot start.
                    RestNotificationManager.shared.requestAuthorizationIfNeeded()
                }
            } label: {
                if watch.isMinting {
                    HStack {
                        ProgressView()
                        Text("Pairing…")
                    }
                } else {
                    Text(watch.link == nil ? "Pair Apple Watch" : "Replace Apple Watch")
                }
            }
            .disabled(!watch.canPair)
            .accessibilityIdentifier("pair-watch")

            if let link = watch.link, !link.revoked {
                Button("Revoke Apple Watch", role: .destructive) {
                    confirmingRevoke = true
                }
                .disabled(!watch.canRevoke)
                .accessibilityIdentifier("revoke-watch")
            }
        } header: {
            Text("Apple Watch")
        } footer: {
            Text("The watch uses your Home Server only. It never follows the Away route. "
                 + "Pairing mints a separate watch token; the iPhone keeps it only until the "
                 + "watch acknowledges it. Phone rest alerts need notifications enabled. "
                 + "The watch reports its build when the watch app opens; if it still names the "
                 + "previous commit, the install has not reached the watch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Revoke this Apple Watch?",
            isPresented: $confirmingRevoke,
            titleVisibility: .visible
        ) {
            Button("Revoke Apple Watch", role: .destructive) {
                Task { await watch.revoke() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The watch credential is revoked on the server. Pair again to use the watch.")
        }
    }
}
