import SwiftUI

struct PopupView: View {
    @ObservedObject var viewModel: PopupViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            indicator
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .padding(6)
    }

    @ViewBuilder private var indicator: some View {
        switch viewModel.state {
        case .recording:
            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)
                .scaleEffect(viewModel.pulse ? 1.35 : 1.0)
                .opacity(viewModel.pulse ? 0.6 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: viewModel.pulse)
        case .transcribing:
            ProgressView().controlSize(.small)
        case .refining:
            Image(systemName: "sparkles")
                .foregroundStyle(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                .font(.system(size: 16, weight: .semibold))
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16, weight: .semibold))
        case .doneWithLanguageWarning:
            Image(systemName: "globe")
                .foregroundStyle(.yellow)
                .font(.system(size: 16, weight: .semibold))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16, weight: .semibold))
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.state {
        case .recording:
            VStack(alignment: .leading, spacing: 2) {
                Text("Listening…").font(.system(size: 14, weight: .semibold))
                Text("Tap right ⌥ again to finish").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .transcribing:
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcribing…").font(.system(size: 14, weight: .semibold))
                Text("Whisper large-v3-turbo").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .refining(let text):
            VStack(alignment: .leading, spacing: 2) {
                Text(text.isEmpty ? "Refining…" : text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                Text("Refining with Apple Intelligence…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .done(let text):
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 13)).lineLimit(3).truncationMode(.tail)
                Text("Pasted").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .doneWithLanguageWarning(let text, let detected, let pinned):
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 13)).lineLimit(3).truncationMode(.tail)
                Text("Pasted — heard \(detected.uppercased()), pinned \(pinned.uppercased())")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text("Dictation failed").font(.system(size: 14, weight: .semibold))
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
        case .hidden:
            EmptyView()
        }
    }
}
