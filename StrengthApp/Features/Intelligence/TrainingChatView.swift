import SwiftUI
import StrengthCore

struct TrainingChatView: View {
    @StateObject private var chat: TrainingChatModel

    init(model: AppModel) {
        _chat = StateObject(wrappedValue: model.makeChatModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Model: \(chat.modelLabel) · Plan data: \(chat.planEnabled ? "on" : "off")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            if !chat.availability.isAvailable {
                ContentUnavailableView(
                    "Chat unavailable",
                    systemImage: "sparkles",
                    description: Text(chat.availability.reasonText)
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if chat.messages.isEmpty {
                                Text("Ask about this week, a lift, a session or readiness.")
                                    .foregroundStyle(.secondary)
                                ForEach(TrainingChatModel.suggested, id: \.self) { prompt in
                                    Button(prompt) { Task { await chat.send(prompt) } }
                                        .buttonStyle(.bordered)
                                }
                            }
                            ForEach(chat.messages) { message in
                                messageBubble(message).id(message.id)
                            }
                            if chat.isSending {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Checking your data…").foregroundStyle(.secondary)
                                }
                            }
                            if let error = chat.errorMessage {
                                Text(error).font(.footnote).foregroundStyle(.orange)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: chat.messages.count) { _, _ in
                        if let last = chat.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    TextField("Ask about your training", text: $chat.input, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("chat-input")
                    Button {
                        Task { await chat.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(chat.input.trimmingCharacters(in: .whitespaces).isEmpty || chat.isSending)
                    .accessibilityIdentifier("chat-send")
                }
                .padding()
                Text("On this iPhone only. Nothing is sent to a server and the conversation is not saved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
        .navigationTitle("Chat")
        .onDisappear { chat.reset() }
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            Text(message.text)
                .padding(10)
                .background(
                    message.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            if !message.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        "Suggestion — not applied. Not medical advice.",
                        systemImage: "lightbulb"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    ForEach(Array(message.suggestions.enumerated()), id: \.offset) { _, line in
                        Text("• \(line)").font(.callout)
                    }
                }
                .padding(8)
                .background(
                    Color.orange.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
            if !message.unverifiedNumbers.isEmpty {
                Label(
                    "Unverified numbers: \(message.unverifiedNumbers.joined(separator: ", "))",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
            if !message.sources.isEmpty {
                Text("Based on: \(message.sources.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}
