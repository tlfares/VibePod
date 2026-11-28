import SwiftUI

/// Settings › Tools › AI Features: the switch, the provider (Groq or
/// Mistral), the user's own key for it and what it's used for.
struct AIFeaturesView: View {
    @State private var isEnabled = AIFeatures.isEnabled
    @AppStorage(LyricsGenerator.wordByWordKey) private var generateWordByWord = true
    @State private var provider = AIProvider.current
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
                    Text("Runs on Groq's free plan or on Mistral, with your own key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // Apple Intelligence runs it without a key: always shown.
                AssistantSettingsCard()

                if isEnabled {
                    keyCard
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    SpeechmaticsCard(provider: provider)
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
            Text("Provider").font(.headline)
            Picker("Provider", selection: $provider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.name).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: provider) { _, value in
                AIProvider.current = value
                withAnimation(.smooth) {
                    savedKey = AIFeatures.key(for: value)
                    draftKey = ""
                    keyError = nil
                }
            }
            Text(provider == .groq
                 ? String(localized: "Free, with daily limits. Uses Whisper to hear the songs.")
                 : String(localized: "Needs an API plan on Mistral's side. Uses Voxtral to hear the songs."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            Divider()
            Text("\(provider.name) API Key").font(.headline)
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
                Link(destination: provider.keysPage) {
                    Label("Get a key on \(provider.consoleHost)", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.medium))
                }
            }
            Divider()
            ExpandableFootnote(
                summary: "Kept in the Keychain, only sent to \(provider.name).",
                detail: "Your key stays private, in the Keychain: it isn't included in backups and it's only ever sent to \(provider.name), when you use an AI feature. With Device Sync, it goes to your other devices through your private, encrypted iCloud database."
            )
            .id(provider)
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
                        detail: "When neither an LRC file nor LRCLIB has a song's lyrics, the No Results popup (or the end of LRCLIB's results) offers to generate them: the vocals are transcribed, then laid out in short lines synced to the song. The song's audio is sent to the provider you chose. Results vary with the mix; Delete AI Lyrics in the song's \u{2022}\u{2022}\u{2022} menu removes them from the app."
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
                        detail: "For songs with synced lyrics, Sync Word by Word in the player's \u{2022}\u{2022}\u{2022} menu lights each word up as it's sung, like Apple Music: the vocals are listened to and every word of your lyrics gets its time. The lyrics' text, line breaks and LRC file stay untouched. The song's audio is sent to the provider you chose. The same menu hides the word by word sync (back to line by line, kept for later) or deletes it."
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

    /// Kept only once the provider accepts it, so a typo shows up here
    /// rather than in the middle of a feature.
    private func saveKey() {
        let key = trimmedDraft
        guard !key.isEmpty, !isChecking else { return }
        isChecking = true
        keyError = nil
        let provider = provider
        Task {
            do {
                try await MistralClient.validate(key: key, provider: provider)
                AIFeatures.setKey(key, for: provider)
                guard self.provider == provider else { isChecking = false; return }
                withAnimation(.smooth) {
                    savedKey = key
                    draftKey = ""
                }
                isKeyFocused = false
            } catch MistralError.invalidKey {
                keyError = String(localized: "\(provider.name) didn't accept this key. Copy it again from \(provider.consoleHost).")
            } catch {
                keyError = error.localizedDescription
            }
            isChecking = false
        }
    }
}

/// The optional Speechmatics key: songs are heard through it (lyrics
/// generation, word by word sync), everything else stays on the provider.
private struct SpeechmaticsCard: View {
    let provider: AIProvider
    @State private var savedKey = AIFeatures.speechmaticsKey
    @State private var draftKey = ""
    @State private var isChecking = false
    @State private var keyError: String?
    @FocusState private var isKeyFocused: Bool

    private var trimmedDraft: String {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Speechmatics").font(.headline)
                Text("Optional")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text("For more accurate transcription and word timing when generating or syncing lyrics. Everything else stays on \(provider.name).")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let savedKey {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\(savedKey.suffix(4))")
                        .font(.body.monospaced())
                    Spacer()
                    Button("Remove", role: .destructive) {
                        withAnimation(.smooth) {
                            AIFeatures.speechmaticsKey = nil
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
                Link(destination: Speechmatics.keysPage) {
                    Label("Get a key on \(Speechmatics.consoleHost)", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.medium))
                }
            }
            Divider()
            ExpandableFootnote(
                summary: "Kept in the Keychain, only sent to Speechmatics.",
                detail: "Your key stays private, in the Keychain, and is only sent to Speechmatics, with the song's vocals (or the song itself), when lyrics are generated or synced word by word. Each transcription is deleted from Speechmatics as soon as it's back. With Device Sync, the key goes to your other devices through your private, encrypted iCloud database."
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    /// Kept only once Speechmatics accepts it.
    private func saveKey() {
        let key = trimmedDraft
        guard !key.isEmpty, !isChecking else { return }
        isChecking = true
        keyError = nil
        Task {
            do {
                try await Speechmatics.validate(key: key)
                AIFeatures.speechmaticsKey = key
                withAnimation(.smooth) {
                    savedKey = key
                    draftKey = ""
                }
                isKeyFocused = false
            } catch Speechmatics.Failure.invalidKey {
                keyError = String(localized: "Speechmatics didn't accept this key. Copy it again from \(Speechmatics.consoleHost).")
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
