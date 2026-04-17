import SwiftUI

struct AssistantStructuredUserInputView: View {
    let request: AssistantPermissionRequest
    let accent: Color
    let secondaryText: Color
    let fieldBackground: Color
    let submitTitle: String
    let cancelTitle: String
    let onSubmit: ([String: [String]]) -> Void
    let onCancel: () -> Void

    @State private var selectedOptionIDs: [String: String] = [:]
    @State private var customAnswers: [String: String] = [:]

    private var introText: String {
        request.userInputQuestions.count == 1
            ? "Answer the question below to continue."
            : "Answer each question below to continue."
    }

    private var resolvedAnswers: [String: [String]] {
        Dictionary(uniqueKeysWithValues: request.userInputQuestions.compactMap { question in
            if let customAnswer = normalizedCustomAnswer(for: question), !customAnswer.isEmpty {
                return (question.id, [customAnswer])
            }

            guard let selectedOptionID = selectedOptionIDs[question.id],
                  let option = question.options.first(where: { $0.id == selectedOptionID }) else {
                return nil
            }
            return (question.id, [option.label])
        })
    }

    private var canSubmit: Bool {
        request.userInputQuestions.allSatisfy { resolvedAnswers[$0.id]?.isEmpty == false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(introText)
                .font(.caption)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(request.userInputQuestions) { question in
                questionSection(question)
            }

            Button(submitTitle) {
                onSubmit(resolvedAnswers)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .disabled(!canSubmit)

            Button(cancelTitle) {
                onCancel()
            }
            .buttonStyle(.plain)
            .foregroundStyle(secondaryText)
        }
        .id(request.id)
    }

    private func questionSection(_ question: AssistantUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if question.header.caseInsensitiveCompare(question.prompt) != .orderedSame {
                Text(question.header)
                    .font(.callout.weight(.semibold))
            }

            Text(question.prompt)
                .font(.subheadline)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(question.options) { option in
                let isSelected = selectedOptionIDs[question.id] == option.id && normalizedCustomAnswer(for: question) == nil

                Button {
                    selectedOptionIDs[question.id] = option.id
                    customAnswers[question.id] = ""
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.label)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let detail = option.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected ? accent.opacity(0.18) : fieldBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isSelected ? accent.opacity(0.85) : AppVisualTheme.foreground(0.08), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            if question.allowsCustomAnswer {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Other answer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryText)

                    TextField(
                        "Type your answer",
                        text: Binding(
                            get: { customAnswers[question.id] ?? "" },
                            set: { newValue in
                                customAnswers[question.id] = newValue
                                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                                    selectedOptionIDs[question.id] = nil
                                }
                            }
                        ),
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(fieldBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(normalizedCustomAnswer(for: question) == nil ? AppVisualTheme.foreground(0.08) : accent.opacity(0.85), lineWidth: 1)
                    )
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppVisualTheme.foreground(0.03))
        )
    }

    private func normalizedCustomAnswer(for question: AssistantUserInputQuestion) -> String? {
        customAnswers[question.id]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }
}

struct AssistantStructuredApprovalView: View {
    let accent: Color
    let secondaryText: Color
    let approveTitle: String
    let rejectTitle: String
    let cancelTitle: String
    let onApprove: () -> Void
    let onReject: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Approve or reject to continue.")
                .font(.caption)
                .foregroundStyle(secondaryText)

            HStack(spacing: 10) {
                Button(approveTitle) {
                    onApprove()
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)

                Button(rejectTitle) {
                    onReject()
                }
                .buttonStyle(.bordered)
            }

            Button(cancelTitle) {
                onCancel()
            }
            .buttonStyle(.plain)
            .foregroundStyle(secondaryText)
        }
    }
}
