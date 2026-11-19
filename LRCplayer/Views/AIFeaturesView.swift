import SwiftUI

/// Settings › Tools › AI Features: the switch, the user's own Mistral key
/// and what it's used for.
struct AIFeaturesView: View {
    @State private var isEnabled = AIFeatures.isEnabled
    @AppStorage(LyricsGenerator.wordByWordKey) private var generateWordByWord = true
    @State private var savedKey = AIFeatures.apiKey
    @State private var draftKey = ""
    @State private var isChecking = false
    @State private var keyError: String?
    @FocusState private var isKeyFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                card {
                    Toggle("Enable AI Features", isOn: $isEnabled.animation(.smooth))
                        .onChange(of: isEnabled) { _, value in AIFeatures.isEnabled = value }
                    Text("Runs on Mistral's models, with your own free key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // Apple Intelligence runs it without a key: always shown.
                AssistantSettingsCard()

                if isEnabled {
                    keyCard
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    featuresCard
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .glassEffect(.regular.tint(Color.aiTint.opacity(0.25)), in: .circle)
            HStack(spacing: 8) {
                Text("AI Features").font(.title2.bold())
                BetaBadge()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var keyCard: some View {
        card {
            Text("Mistral API Key").font(.headline)
            if let savedKey {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\(savedKey.suffix(4))")
                        .font(.body.monospaced())
                    Spacer()
                    Button("Remove", role: .destructive) {
                        withAnimation(.smooth) {
                            AIFeatures.apiKey = nil
                            self.savedKey = nil
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            } else {
                HStack(spacing: 10) {
                    SecureField("Paste your API key", text: $draftKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($isKeyFocused)
                        .submitLabel(.done)
                        .onSubmit(saveKey)
                        .onChange(of: draftKey) { keyError = nil }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 14))
                    Button(action: saveKey) {
                        if isChecking {
                            ProgressView()
                        } else {
                            Text("Save").fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(trimmedDraft.isEmpty || isChecking)
                }
                if let keyError {
                    Text(keyError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Link(destination: URL(string: "https://console.mistral.ai/api-keys")!) {
                    Label("Get a free key on console.mistral.ai", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.medium))
                }
            }
            Divider()
            ExpandableFootnote(
                summary: "Kept in this iPhone's Keychain, only sent to Mistral.",
                detail: "Your key stays private on this iPhone, in its Keychain: it isn't synced to iCloud nor included in backups, and it's only ever sent to Mistral, when you use an AI feature."
            )
        }
    }

    private var featuresCard: some View {
        card {
            Text("Features").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "quote.bubble.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Generate Lyrics")
                        BetaBadge()
                    }
                    ExpandableFootnote(
                        summary: "Transcribes and syncs the lyrics no source has.",
                        detail: "When neither an LRC file nor LRCLIB has a song's lyrics, the No Results popup (or the end of LRCLIB's results) offers to generate them: Mistral's Voxtral transcribes the vocals a minute at a time, then they're laid out in short lines synced to the song. The song's audio is sent to Mistral. Results vary with the mix; Delete AI Lyrics in the song's \u{2022}\u{2022}\u{2022} menu removes them from the app."
                    )
                    Toggle(isOn: $generateWordByWord) {
                        Label("Word by Word", systemImage: "text.word.spacing")
                    }
                    .font(.subheadline)
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "text.word.spacing")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Sync Word by Word")
                        BetaBadge()
                    }
                    ExpandableFootnote(
                        summary: "Lights each word up as it's sung, like Apple Music.",
                        detail: "For songs with synced lyrics, Sync Word by Word in the player's \u{2022}\u{2022}\u{2022} menu lights each word up as it's sung, like Apple Music: Mistral's Voxtral listens to the vocals and every word of your lyrics gets its time. The lyrics' text, line breaks and LRC file stay untouched. The song's audio is sent to Mistral. The same menu hides the word by word sync (back to line by line, kept for later) or deletes it."
                    )
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    // MARK: Key

    private var trimmedDraft: String {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Kept only once Mistral accepts it, so a typo shows up here rather
    /// than in the middle of a feature.
    private func saveKey() {
        let key = trimmedDraft
        guard !key.isEmpty, !isChecking else { return }
        isChecking = true
        keyError = nil
        Task {
            do {
                try await MistralClient.validate(key: key)
                AIFeatures.apiKey = key
                withAnimation(.smooth) {
                    savedKey = key
                    draftKey = ""
                }
                isKeyFocused = false
            } catch MistralError.invalidKey {
                keyError = String(localized: "Mistral didn't accept this key. Copy it again from console.mistral.ai.")
            } catch {
                keyError = error.localizedDescription
            }
            isChecking = false
        }
    }
}

/// A one-line summary that opens onto the full explanation.
struct ExpandableFootnote: View {
    let summary: String
    let detail: String
    @State private var isExpanded = false

    init(summary: LocalizedStringResource, detail: LocalizedStringResource) {
        self.summary = String(localized: summary)
        self.detail = String(localized: detail)
    }

    /// Dynamic text, shown as is.
    @_disfavoredOverload
    init<S: StringProtocol>(summary: S, detail: S) {
        self.summary = String(summary)
        self.detail = String(detail)
    }

    var body: some View {
        Button {
            guard SettingsSwipe.allowsTaps else { return }
            withAnimation(.smooth) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(isExpanded ? detail : summary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// The small "BETA" capsule next to features that may still misbehave.
struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.tint.opacity(0.18), in: .capsule)
            .overlay(Capsule().stroke(.tint.opacity(0.35), lineWidth: 0.5))
    }
}
