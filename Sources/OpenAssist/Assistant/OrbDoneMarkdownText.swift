import MarkdownUI
import SwiftUI

struct OrbDoneMarkdownText: View {
    let text: String

    var body: some View {
        Markdown(text)
            .markdownTheme(orbDoneTheme)
            .markdownCodeSyntaxHighlighter(.plainText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var orbDoneTheme: MarkdownUI.Theme {
        .init()
            .text {
                ForegroundColor(.white.opacity(0.88))
                FontSize(13)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(16)
                        FontWeight(.bold)
                        ForegroundColor(.white.opacity(0.92))
                    }
                    .markdownMargin(top: 10, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(14.5)
                        FontWeight(.bold)
                        ForegroundColor(.white.opacity(0.90))
                    }
                    .markdownMargin(top: 8, bottom: 5)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(13.5)
                        FontWeight(.semibold)
                        ForegroundColor(.white.opacity(0.88))
                    }
                    .markdownMargin(top: 6, bottom: 4)
            }
            .strong {
                FontWeight(.semibold)
                ForegroundColor(.white.opacity(0.92))
            }
            .emphasis {
                FontStyle(.italic)
            }
            .link {
                ForegroundColor(AppVisualTheme.accentTint)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(12)
                ForegroundColor(.white.opacity(0.82))
                BackgroundColor(Color(red: 0.10, green: 0.10, blue: 0.13))
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(12)
                            ForegroundColor(.white.opacity(0.82))
                        }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.06, green: 0.06, blue: 0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                        )
                )
                .markdownMargin(top: 4, bottom: 4)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(AppVisualTheme.accentTint.opacity(0.4))
                        .frame(width: 2.5)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(.white.opacity(0.7))
                            FontStyle(.italic)
                        }
                        .padding(.leading, 8)
                }
                .markdownMargin(top: 3, bottom: 3)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 3, bottom: 3)
            }
    }
}
