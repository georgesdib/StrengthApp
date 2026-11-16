import SwiftUI
import StrengthCore

struct ExplainView: View {
    @ObservedObject var model: AppModel
    @State private var question = ""
    @State private var response: ExplainResponse?
    @State private var errorMessage: String?
    @State private var isSending = false

    private func destination(_ citation: ExplainCitation) -> URL? {
        guard let raw = citation.url else { return nil }
        if raw.hasPrefix("#docs?doc="), let base = model.pairedServerURL {
            return URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + raw)
        }
        return URL(string: raw)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("How is readiness calculated?", text: $question, axis: .vertical)
                        .lineLimit(2...5)
                    Button {
                        Task { await ask() }
                    } label: {
                        if isSending { ProgressView() } else { Text("Explain") }
                    }
                    .disabled(isSending || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Uses the paired server's local docs, code, selected tests and private notes. "
                         + "Private citations are copy-only; no conversation is saved.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }

                if let response {
                    Section {
                        HStack {
                            Text(response.grounded ? "Grounded in project sources" : "Ungrounded answer")
                                .font(.footnote.weight(.semibold))
                            Spacer()
                            if let model = response.model { Text(model).font(.caption2).foregroundStyle(.secondary) }
                        }
                        Text(response.answer)
                            .textSelection(.enabled)
                    } header: {
                        Text("Answer")
                    }

                    if !response.citations.isEmpty {
                        Section("Sources") {
                            ForEach(response.citations) { citation in
                                if let url = destination(citation) {
                                    Link(citation.label, destination: url)
                                        .font(.footnote)
                                } else {
                                    Text(citation.label)
                                        .font(.footnote)
                                        .textSelection(.enabled)
                                }
                                if let warning = citation.warning {
                                    Text(warning).font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    if !response.warnings.isEmpty {
                        Section("Checks") {
                            ForEach(response.warnings, id: \.self) { warning in
                                Text(warning).font(.footnote).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Explain")
        }
    }

    private func ask() async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            response = try await model.explain(question)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
