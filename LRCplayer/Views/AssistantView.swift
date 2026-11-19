import SwiftUI

/// The assistant's settings, read by the button and the sheet.
enum AssistantSettings {
    static let swapPressKey = "assistantSwapPress"
    static let autoListenKey = "assistantAutoListen"
    static let showButtonKey = "assistantShowButton"
}

// MARK: - Button

/// Library's sparkles button: a tap opens the chat, a long press talks
/// (or the other way around, in Settings).
struct AssistantBarButton: View {
    @EnvironmentObject private var router: AppRouter
    @AppStorage(AssistantSettings.swapPressKey) private var swapsPress = false
    @State private var didLongPress = false
    @State private var longPresses = 0

    var body: some View {
        Button {
            if didLongPress {
                didLongPress = false
            } else {
                router.assistant = swapsPress ? .voice : .text
            }
        } label: {
            BarIcon("Assistant", systemImage: "sparkles")
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                didLongPress = true
                longPresses += 1
                router.assistant = swapsPress ? .text : .voice
            }
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: longPresses)
        .accessibilityHint(swapsPress ? "Touch and hold to type" : "Touch and hold to talk")
    }
}

// MARK: - Sheet

struct AssistantView: View {
    @StateObject private var assistant = AssistantService.shared
    @StateObject private var voice = AssistantVoice()
    @EnvironmentObject private var router: AppRouter
    @AppStorage(AssistantSettings.autoListenKey) private var autoListens = true

    @State private var detent: PresentationDetent
    /// Voice expands into text, never the other way by dragging: pulling
    /// the chat down closes it.
    @State private var mode: AssistantMode
    @State private var draft = ""
    /// When a message last left the bar: the keyboard may still commit
    /// its pending word (an autocorrection, a prediction) just after.
    @State private var sentAt = Date.distantPast
    @State private var voiceTask: Task<Void, Never>?
    @State private var voiceReply: AssistantMessage?
    @State private var showsMemories = false
    @State private var showsTips = false
    /// The question being rewritten in the input bar.
    @State private var editingID: UUID?
    @FocusState private var isInputFocused: Bool

    /// Shown as a tab's page rather than a sheet: no close button, and voice
    /// opens in its own sheet over it.
    private let isTab: Bool

    private static let voiceDetent = PresentationDetent.height(400)

    init(mode: AssistantMode, isTab: Bool = false) {
        self.isTab = isTab
        _detent = State(initialValue: mode == .voice ? Self.voiceDetent : .large)
        _mode = State(initialValue: mode)
    }

    private var detents: Set<PresentationDetent> {
        mode == .voice ? [Self.voiceDetent, .large] : [.large]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if mode == .voice {
                    voiceMode
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
                } else {
                    textMode
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.4), value: mode)
            .background { AssistantBackdrop(isVoice: mode == .voice) }
            .toolbar { toolbar }
            .navigationTitle(mode == .text ? "Assistant" : "")
            .navigationSubtitle(mode == .text ? (assistant.lastEngine?.title ?? "") : "")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsMemories) { AssistantMemoryList() }
            .sheet(isPresented: $showsTips) {
                AssistantTipsView { destination in
                    showsTips = false
                    if !isTab { router.assistant = nil }
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        router.openSettings(at: destination)
                    }
                }
            }
        }
        // Neutral controls: colour comes from the music, not the app.
        .tint(.primary)
        .presentationDetents(detents, selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(mode == .voice ? 44 : nil)
        .onChange(of: detent) { _, detent in
            if detent == .large, mode == .voice { mode = .text }
        }
        .onChange(of: mode, initial: true) { _, mode in
            if mode == .voice {
                isInputFocused = false
                startVoice()
            } else {
                stopVoice()
            }
        }
        .onChange(of: assistant.requestedRoute) { _, route in
            guard let route else { return }
            assistant.requestedRoute = nil
            show(route)
        }
        .onDisappear {
            stopVoice()
            if !isTab { assistant.cancel() }
        }
        .task { AssistantEngines.prewarm() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if mode == .text {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        showsMemories = true
                    } label: {
                        Label(AssistantService.prefersFrench ? "Ce que je retiens" : "What I Remember", systemImage: "bookmark")
                    }
                    Button("Improve the Assistant", systemImage: "wand.and.stars") {
                        showsTips = true
                    }
                    Button("Clear Conversation", destructiveImage: "trash") {
                        withAnimation(.smooth) { assistant.clear() }
                    }
                    .disabled(assistant.messages.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        if !isTab {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .close) {
                    router.assistant = nil
                }
            }
        }
    }

    private func show(_ route: LibraryRoute) {
        router.assistant = nil
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            router.open(route)
        }
    }

    // MARK: Text

    private var textMode: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a conversation is short, and estimated heights made
                // the view jump while the keyboard closed.
                VStack(alignment: .leading, spacing: 0) {
                    if assistant.messages.isEmpty {
                        AssistantHome(canAnswer: assistant.canAnswer, onPick: send)
                            .transition(.opacity)
                    }
                    ForEach(Array(assistant.messages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(message: message, assistant: assistant, onOpen: show, onEdit: startEditing)
                            .id(message.id)
                            // A new turn breathes; an answer stays close to its question.
                            .padding(.top, index == 0 ? 8 : (message.role == .user ? 28 : 12))
                            .transition(.asymmetric(
                                insertion: .offset(y: 24).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                    if assistant.isWorking {
                        ShimmerText(text: assistant.activity ?? "…")
                            .padding(.top, 14)
                            .id("thinking")
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .animation(.smooth(duration: 0.4), value: assistant.messages)
                .animation(.smooth(duration: 0.3), value: assistant.isWorking)
            }
            .scrollDismissesKeyboard(.interactively)
            // The bottom stays put as answers grow and the keyboard comes and
            // goes; no scripted scrolls fighting the keyboard's own animation.
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onChange(of: assistant.messages.count) {
                // Only a sent question jumps down (when scrolled up to read).
                guard assistant.messages.last?.role == .user else { return }
                proxy.scrollTo(assistant.messages.last?.id, anchor: .bottom)
            }
            .safeAreaBar(edge: .bottom) { inputBar }
        }
    }

    private func startEditing(_ message: AssistantMessage) {
        withAnimation(.snappy(duration: 0.25)) {
            editingID = message.id
            draft = message.text
        }
        sentAt = .distantPast
        isInputFocused = true
    }

    private func stopEditing() {
        withAnimation(.snappy(duration: 0.25)) {
            editingID = nil
            draft = ""
        }
    }

    private var inputBar: some View {
        let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let french = AssistantService.prefersFrench
        return VStack(alignment: .leading, spacing: 0) {
        if editingID != nil {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .font(.footnote.weight(.semibold))
                Text(french ? "Modification du message" : "Editing Message")
                    .font(.footnote.weight(.semibold))
                Spacer()
                Button {
                    stopEditing()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(french ? "Annuler la modification" : "Cancel Editing")
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.top, 8)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        HStack(alignment: .bottom, spacing: 8) {
            TextField(AssistantService.prefersFrench ? "Demande n'importe quoi" : "Ask anything", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($isInputFocused)
                .submitLabel(.send)
                .onSubmit { send(draft) }
                .onChange(of: draft) { _, new in
                    if !new.isEmpty, Date().timeIntervalSince(sentAt) < 0.5 { draft = "" }
                }
                .padding(.leading, 18)
                .padding(.vertical, 13)

            ZStack {
                if assistant.isWorking {
                    InputBarButton(systemImage: "stop.fill", isProminent: true) { assistant.cancel() }
                        .accessibilityLabel("Stop")
                } else if isEmpty {
                    InputBarButton(systemImage: "waveform", isProminent: false) {
                        if isTab {
                            router.assistant = .voice
                        } else { withAnimation(.smooth) {
                            mode = .voice
                            detent = Self.voiceDetent
                        } }
                    }
                    .accessibilityLabel("Talk")
                } else {
                    InputBarButton(systemImage: "arrow.up", isProminent: true) { send(draft) }
                        .accessibilityLabel("Send")
                }
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .padding(.trailing, 6)
            .padding(.bottom, 6)
        }
        }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 25))
        .animation(.snappy(duration: 0.25), value: editingID)
        .animation(.snappy(duration: 0.25), value: isEmpty)
        .animation(.snappy(duration: 0.25), value: assistant.isWorking)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !assistant.isWorking else { return }
        sentAt = Date()
        draft = ""
        if let id = editingID {
            withAnimation(.snappy(duration: 0.25)) { editingID = nil }
            Task { await assistant.edit(id, to: text) }
        } else {
            Task { await assistant.send(text) }
        }
    }

    // MARK: Voice

    private var voiceMode: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(voiceStatus)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.25), value: voiceStatus)
                .padding(.top, 22)

            ScrollView {
                Text(voiceCaption)
                    .font(isHearing ? .title.weight(.bold) : .title2.weight(.semibold))
                    .foregroundStyle(voiceCaptionIsQuiet ? .tertiary : .primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.25), value: voiceCaption)
                    .padding(.top, 10)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12)], startPoint: .top, endPoint: .bottom)
            }

            if let receipt = voiceReply?.receipts.first(where: { !$0.isFailure }) ?? voiceReply?.receipts.first {
                ReceiptCard(receipt: receipt, assistant: assistant, onOpen: show)
                    .padding(.top, 12)
                    .transition(.offset(y: 16).combined(with: .opacity))
            }

            HStack {
                Button {
                    withAnimation(.smooth) {
                        mode = .text
                        detent = .large
                    }
                } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .opacity(isTab ? 0 : 1)
                .accessibilityLabel("Type")

                Spacer()

                Button(action: tapOrb) {
                    VoiceLevelBars(level: voice.level, phase: voice.phase)
                        .frame(width: 84, height: 84)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voice.phase == .listening ? "Stop Listening" : "Talk")

                Spacer()

                Color.clear.frame(width: 48, height: 48)
            }
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 24)
        .animation(.smooth, value: voiceReply)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var isHearing: Bool {
        voice.phase == .listening && !voice.transcript.isEmpty
    }

    private var voiceCaptionIsQuiet: Bool {
        switch voice.phase {
        case .listening: voice.transcript.isEmpty
        case .thinking: true
        case .idle: voiceReply == nil
        case .failed: false
        }
    }

    private var voiceStatus: String {
        let french = AssistantService.prefersFrench
        switch voice.phase {
        case .listening: return french ? "À l'écoute" : "Listening"
        case .thinking: return french ? "Réflexion" : "Thinking"
        case .failed: return french ? "Oups" : "Hmm"
        case .idle: return voiceReply == nil ? "Assistant" : (assistant.lastEngine?.title ?? "Assistant")
        }
    }

    private var voiceCaption: String {
        let french = AssistantService.prefersFrench
        switch voice.phase {
        case .idle:
            if let voiceReply { return voiceReply.text }
            return french ? "Touche pour parler" : "Tap to talk"
        case .listening:
            return voice.transcript.isEmpty ? (french ? "Je t'écoute…" : "Listening…") : voice.transcript
        case .thinking:
            return assistant.activity ?? (french ? "Réflexion…" : "Thinking…")
        case let .failed(message):
            return message
        }
    }

    private func tapOrb() {
        switch voice.phase {
        case .listening: voice.finishListening()
        case .thinking: break
        default: startVoice()
        }
    }

    private func startVoice() {
        voiceTask?.cancel()
        voiceTask = Task { await runVoice() }
    }

    private func stopVoice() {
        voiceTask?.cancel()
        voiceTask = nil
        voice.endSession()
    }

    /// Listen, answer, speak; again while the assistant asks something back.
    private func runVoice() async {
        let problem = await voice.authorize()
        // Closed while the permission prompt was up: don't take the audio.
        guard !Task.isCancelled else { return }
        if let problem {
            voice.endSession()
            voiceReply = AssistantMessage(role: .assistant, text: problem, isError: true)
            return
        }
        voiceReply = nil
        var turns = 0
        while !Task.isCancelled, turns < 6 {
            turns += 1
            let heard = await voice.listen()
            guard !Task.isCancelled else { return }
            guard !heard.isEmpty else {
                // Ending the session clears the phase: keep its reason.
                var note = AssistantService.prefersFrench ? "Je n'ai rien entendu. Touche le cercle pour réessayer." : "I didn't hear anything. Tap the circle to try again."
                if case let .failed(reason) = voice.phase { note = reason }
                voice.endSession()
                voice.show(note)
                return
            }
            voice.setThinking()
            guard let answer = await assistant.send(heard, viaVoice: true), !Task.isCancelled else { break }
            voiceReply = answer
            guard !Task.isCancelled else { return }
            if answer.expectsAnswer, autoListens { continue }
            // Music's on: nothing left to do here.
            let played = answer.receipts.contains { !$0.isFailure && ["play.fill", "shuffle", "text.line.first.and.arrowtriangle.forward", "text.line.last.and.arrowtriangle.forward"].contains($0.symbol) }
            if played, !answer.isError {
                voice.endSession()
                try? await Task.sleep(for: .seconds(1.2))
                if !Task.isCancelled, mode == .voice { router.assistant = nil }
                return
            }
            break
        }
        voice.endSession()
    }
}

// MARK: - Rows

private struct MessageRow: View {
    let message: AssistantMessage
    @ObservedObject var assistant: AssistantService
    let onOpen: (LibraryRoute) -> Void
    var onEdit: (AssistantMessage) -> Void = { _ in }

    var body: some View {
        if message.role == .user {
            HStack(alignment: .bottom) {
                Spacer(minLength: 56)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if message.viaVoice {
                        Image(systemName: "waveform")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(message.text)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 21))
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 21))
                .contextMenu { questionMenu }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if message.isError {
                    Label {
                        Text(message.text)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else {
                    Text(Self.markdown(message.text))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(message.receipts) { receipt in
                    ReceiptCard(receipt: receipt, assistant: assistant, onOpen: onOpen)
                }
            }
        }
    }

    /// Hold a question: copy it, rewrite it (its answer is replaced), take
    /// it back; while it's answered, stop.
    @ViewBuilder
    private var questionMenu: some View {
        let french = AssistantService.prefersFrench
        Button(french ? "Copier" : "Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = message.text
        }
        if assistant.waitingID == message.id {
            Button(french ? "Annuler la demande" : "Cancel Request", systemImage: "xmark.circle", role: .destructive) {
                withAnimation(.smooth) { assistant.delete(message.id) }
            }
        } else {
            Button(french ? "Modifier" : "Edit", systemImage: "pencil") {
                onEdit(message)
            }
            .disabled(assistant.isWorking)
            Button(french ? "Supprimer" : "Delete", systemImage: "trash", role: .destructive) {
                withAnimation(.smooth) { assistant.delete(message.id) }
            }
        }
    }

    /// Markdown line by line: headings get a bigger bold font, list markers
    /// become bullets, rules disappear, the rest keeps its inline styles.
    static func markdown(_ text: String) -> AttributedString {
        var result = AttributedString()
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var body = line
            var font: Font?
            if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"), trimmed[hashes] == " " {
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
                body = String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)
                font = level <= 2 ? .title3.bold() : .headline
            } else if trimmed.allSatisfy({ "-*_".contains($0) }), trimmed.count >= 3 {
                continue
            } else if let marker = ["- ", "* ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
                let indent = line.prefix { $0 == " " }.count >= 2 ? "    " : ""
                body = indent + "• " + trimmed.dropFirst(marker.count)
            }
            var part = (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body)
            if let font { part.font = font }
            result += part
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }
}

/// What the assistant did: songs and playlists get their covers, player
/// controls a slim line.
private struct ReceiptCard: View {
    let receipt: AssistantReceipt
    @ObservedObject var assistant: AssistantService
    let onOpen: (LibraryRoute) -> Void

    var body: some View {
        if receipt.songIDs.isEmpty, receipt.destination == nil, !assistant.isAwaiting(receipt) {
            Label {
                Text(receipt.detail.isEmpty ? receipt.title : "\(receipt.title) · \(receipt.detail)")
            } icon: {
                Image(systemName: receipt.symbol)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(receipt.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(receipt.isFailure ? .secondary : .primary)
                        .lineLimit(1)
                    if !receipt.detail.isEmpty {
                        Text(receipt.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if receipt.destination != nil, !receipt.awaitsConfirmation {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            if assistant.isAwaiting(receipt) {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.smooth) { assistant.cancelPending() }
                    } label: {
                        Text(AssistantService.prefersFrench ? "Annuler" : "Cancel")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    Button(role: .destructive) {
                        withAnimation(.smooth) { assistant.confirmPending() }
                    } label: {
                        Text(AssistantService.prefersFrench ? "Supprimer" : "Delete")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                }
                .controlSize(.large)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .padding(.trailing, 6)
        .glassEffect(.regular.interactive(receipt.destination != nil), in: .rect(cornerRadius: 22))
        .contentShape(.rect(cornerRadius: 22))
        .onTapGesture {
            if let destination = receipt.destination, !receipt.awaitsConfirmation { onOpen(destination.route) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(receipt.destination != nil ? .isButton : [])
    }

    @ViewBuilder
    private var artwork: some View {
        if !receipt.songIDs.isEmpty {
            CoverMosaic(ids: receipt.songIDs, cornerRadius: 12, points: 56)
                .frame(width: 56, height: 56)
        } else {
            Image(systemName: receipt.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(Color(.quaternarySystemFill), in: .rect(cornerRadius: 12))
        }
    }
}

/// Four covers in a square, like Music's playlist artwork; one when there
/// aren't four.
private struct CoverMosaic: View {
    let ids: [UUID]
    var cornerRadius: CGFloat
    var points: CGFloat

    var body: some View {
        Group {
            if ids.count >= 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        tile(ids[0])
                        tile(ids[1])
                    }
                    GridRow {
                        tile(ids[2])
                        tile(ids[3])
                    }
                }
            } else if let id = ids.first {
                ArtworkImage(source: .song(id), cornerRadius: 0, points: points, placeholderSymbol: "music.note")
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
    }

    private func tile(_ id: UUID) -> some View {
        ArtworkImage(source: .song(id), cornerRadius: 0, points: points / 2, placeholderSymbol: "music.note")
            .aspectRatio(1, contentMode: .fill)
    }
}

/// The activity line while the assistant works, with a light sweeping
/// across it.
private struct ShimmerText: View {
    let text: String
    @State private var sweep = false

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.tertiary)
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, .primary.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(proxy.size.width * 0.5, 60))
                        .offset(x: sweep ? proxy.size.width : -max(proxy.size.width * 0.5, 60))
                }
                .mask {
                    Text(text).font(.subheadline.weight(.medium))
                }
            }
            .contentTransition(.opacity)
            .animation(.smooth, value: text)
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { sweep = true }
            }
    }
}

private struct InputBarButton: View {
    let systemImage: String
    let isProminent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isProminent ? Color(.systemBackground) : .primary)
                .frame(width: 36, height: 36)
                .background {
                    if isProminent { Circle().fill(.primary) }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Home

/// The empty chat: a greeting and a few things to ask, each
/// shown as a quiet tile.
private struct AssistantHome: View {
    let canAnswer: Bool
    let onPick: (String) -> Void

    @State private var ideas: [Idea] = []

    struct Idea: Identifiable {
        let id: String
        let title: String
        let prompt: String
        let symbol: String
        let hue: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.greeting)
                    .font(.largeTitle.weight(.bold))
                Text(AssistantService.prefersFrench
                     ? "Je connais ta bibliothèque et tes écoutes. Demande une musique, une playlist, un récap, ou un roast."
                     : "I know your library and your listening. Ask for music, a playlist, a recap, or a roast.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !canAnswer {
                Label(AssistantEngines.appleUnavailableReason ?? "", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                ForEach(ideas) { idea in
                    Button {
                        onPick(idea.prompt)
                    } label: {
                        IdeaCard(idea: idea)
                    }
                    .buttonStyle(PressableCardStyle())
                }
            }
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if ideas.isEmpty { ideas = Self.ideas() } }
    }

    private static var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if AssistantService.prefersFrench {
            return hour >= 18 || hour < 5 ? "Bonsoir" : "Bonjour"
        }
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private static func ideas() -> [Idea] {
        let french = AssistantService.prefersFrench
        return [
            Idea(id: "top", title: french ? "Mes plus écoutés du mois" : "My most played this month",
                 prompt: french ? "Joue mes titres les plus joués du mois" : "Play my most played songs this month",
                 symbol: "chart.bar.fill", hue: 0.98),
            Idea(id: "recap", title: french ? "Le récap de ma semaine" : "Recap my week",
                 prompt: french ? "Fais-moi le récap de ma semaine" : "Give me a recap of my week",
                 symbol: "calendar", hue: 0.6),
            Idea(id: "forgotten", title: french ? "Mes sons oubliés" : "My forgotten favorites",
                 prompt: french ? "Crée une playlist de mes sons oubliés" : "Make a playlist of my forgotten favorites",
                 symbol: "clock.arrow.circlepath", hue: 0.08),
            Idea(id: "unplayed", title: french ? "Jamais écoutés" : "Never played",
                 prompt: french ? "Crée une playlist de titres de ma bibliothèque que je n'ai jamais écoutés"
                                : "Make a playlist of songs in my library I've never played",
                 symbol: "sparkles", hue: 0.47),
            Idea(id: "now", title: french ? "Un mix pour maintenant" : "A mix for right now",
                 prompt: french ? "Fais-moi un mix pour ce moment de la journée" : "Make me a mix for this time of day",
                 symbol: "waveform", hue: 0.75),
            Idea(id: "roast", title: french ? "Roast mes goûts" : "Roast my taste",
                 prompt: french ? "Roast mes goûts musicaux" : "Roast my music taste",
                 symbol: "flame.fill", hue: 0.03),
        ]
    }
}

/// Like the App Store's browse tiles, quieter: a muted wash of colour, the
/// idea's name top-left and its symbol tucked in the corner. Same size as
/// Search's cards.
private struct IdeaCard: View {
    let idea: AssistantHome.Idea

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(hue: idea.hue, saturation: 0.38, brightness: 0.62),
                         Color(hue: idea.hue, saturation: 0.48, brightness: 0.42)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: idea.symbol)
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.white.opacity(0.32))
                .rotationEffect(.degrees(12))
                .offset(x: 6, y: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 10)
            Text(idea.title)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .padding(12)
        }
        .frame(height: 108)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .overlay { GlassRim(cornerRadius: 12) }
        .contentShape(.rect(cornerRadius: 12, style: .continuous))
    }
}

private struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - Backdrop

/// A wash of the playing cover's colour from the top, so the assistant
/// sits in the music like the rest of the app.
private struct AssistantBackdrop: View {
    let isVoice: Bool
    @State private var tint: Color?

    var body: some View {
        LinearGradient(
            colors: [(tint ?? .clear).opacity(isVoice ? 0.38 : 0.22), .clear],
            startPoint: .top,
            endPoint: isVoice ? .bottom : .center
        )
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.6), value: tint)
        .onReceive(MusicPlayerService.shared.$currentSong.removeDuplicates { $0?.id == $1?.id }) { song in
            tint = song?.coverTint
        }
    }
}

// MARK: - Voice bars

/// Five bars in a glass circle: still with a mic when idle, following the
/// voice while listening, a slow wave while thinking.
private struct VoiceLevelBars: View {
    var level: Float
    var phase: AssistantVoice.Phase

    @State private var smoothedLevel: CGFloat = 0

    var body: some View {
        ZStack {
            if phase == .idle || isFailed {
                Image(systemName: "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                TimelineView(.animation) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 5) {
                        ForEach(0..<5) { index in
                            Capsule()
                                .frame(width: 6, height: height(index, time: time))
                        }
                    }
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.circle)
        .animation(.smooth(duration: 0.3), value: phase)
        .onChange(of: level) { _, level in
            withAnimation(.smooth(duration: 0.12)) { smoothedLevel = CGFloat(level) }
        }
        .onChange(of: phase) { _, phase in
            if phase != .listening { withAnimation(.smooth) { smoothedLevel = 0 } }
        }
        .accessibilityHidden(true)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func height(_ index: Int, time: TimeInterval) -> CGFloat {
        // The middle bars move most, like a voice memo's meter.
        let weight: [CGFloat] = [0.55, 0.85, 1, 0.85, 0.55]
        if phase == .thinking {
            return 8 + 14 * CGFloat((sin(time * 4 - Double(index) * 0.7) + 1) / 2)
        }
        let wobble = CGFloat((sin(time * 9 + Double(index) * 1.9) + 1) / 2)
        return 6 + weight[index] * (4 + smoothedLevel * 30) * (0.7 + 0.3 * wobble)
    }
}

// MARK: - Memories

/// Everything the user asked the assistant to remember, newest first, each
/// one deletable on its own.
struct AssistantMemoryList: View {
    @ObservedObject private var memory = AssistantMemory.shared
    @State private var confirmsClear = false

    private var french: Bool { AssistantService.prefersFrench }

    var body: some View {
        List {
            if !memory.items.isEmpty {
                Section {
                    ForEach(memory.items.reversed()) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text)
                            Text(item.date, format: .relative(presentation: .named))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .swipeActions {
                            Button(role: .destructive) {
                                withAnimation { memory.remove(item) }
                            } label: {
                                Label(french ? "Oublier" : "Forget", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                        .contextMenu {
                            Button(french ? "Oublier" : "Forget", destructiveImage: "trash") {
                                withAnimation { memory.remove(item) }
                            }
                        }
                    }
                } footer: {
                    Text(french
                         ? "L'assistant s'en sert dans toutes ses réponses. Ça reste sur cet iPhone, et n'est envoyé qu'au modèle qui répond."
                         : "The assistant uses these in every answer. They stay on this iPhone and only go to the model answering.")
                }
            }
        }
        .overlay {
            if memory.items.isEmpty {
                ContentUnavailableView {
                    Label(french ? "Rien de retenu" : "Nothing Remembered", systemImage: "bookmark")
                } description: {
                    Text(french
                         ? "Dis « retiens que… » à l'assistant pour qu'il garde quelque chose en tête."
                         : "Say “remember that…” to the assistant to have it keep something in mind.")
                }
            }
        }
        .animation(.smooth, value: memory.items)
        .navigationTitle(french ? "Ce que je retiens" : "What I Remember")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !memory.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(french ? "Tout oublier" : "Forget All", role: .destructive) {
                        confirmsClear = true
                    }
                    .confirmationDialog(french ? "Tout oublier ?" : "Forget everything?", isPresented: $confirmsClear) {
                        Button(french ? "Tout oublier" : "Forget All", role: .destructive) {
                            withAnimation { memory.removeAll() }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Settings

/// Settings › Tools › AI Features: the assistant's card.
struct AssistantSettingsCard: View {
    @AppStorage(AssistantEngineChoice.storageKey) private var engine = AssistantEngineChoice.automatic
    @AppStorage(AssistantSettings.swapPressKey) private var swapsPress = false
    @AppStorage(AssistantSettings.autoListenKey) private var autoListens = true
    @ObservedObject private var memory = AssistantMemory.shared
    @State private var showsMemories = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Assistant").font(.headline)
                BetaBadge()
            }
            Text("Ask for music, playlists or recaps of your listening.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Divider()
            GlassSegmentedPicker(
                "Model",
                options: [.apple, .mistral, .automatic],
                selection: $engine,
                title: \.shortTitle,
                commitsWhenSettled: true
            )
            Text(engineSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("Touch and Hold to Type", isOn: $swapsPress)
            Text(swapsPress ? "A tap talks, touching and holding types." : "A tap types, touching and holding talks.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("Keep Listening for Answers", isOn: $autoListens)
            Text("When the assistant asks something back in voice mode, it listens again without a tap.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Divider()
            Button {
                showsMemories = true
            } label: {
                HStack {
                    Text(AssistantService.prefersFrench ? "Ce que je retiens" : "What I Remember")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(memory.items.count)")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showsMemories) {
            NavigationStack {
                AssistantMemoryList()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(role: .close) { showsMemories = false }
                        }
                    }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .onChange(of: engine) { AssistantEngines.prewarm() }
    }

    private var engineSummary: LocalizedStringResource {
        switch engine {
        case .automatic: "Apple Intelligence first, Mistral as a backup."
        case .apple: AssistantEngines.appleUnavailableReason == nil ? "On this iPhone: private and free." : "Not available on this iPhone."
        case .mistral: AIFeatures.isAvailable ? "Mistral's larger models, with your key." : "Needs AI Features and a Mistral key."
        }
    }
}

// MARK: - Improve the Assistant

/// What makes the assistant know the library better, each with its state
/// and the button that does it.
private struct AssistantTipsView: View {
    let openSettings: (SettingsDestination?) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @ObservedObject private var summaries = LyricsSummaries.shared
    @ObservedObject private var analysis = LibrarySoundAnalysis.shared
    @ObservedObject private var memory = AssistantMemory.shared
    @AppStorage(WorkoutListening.enabledKey) private var workoutsOn = false
    @State private var statsOn = ListeningStatsService.shared.isEnabled
    @State private var enablingWorkouts = false

    private var songs: [Song] { libraryVM.songs }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Text("The more it knows about your music, the better it answers.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    summariesTip
                    lyricsTip
                    soundTip
                    statsTip
                    if WorkoutListening.isAvailable { workoutsTip }
                    metadataTip
                    memoryTip
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("Improve the Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: Tips

    @ViewBuilder
    private var summariesTip: some View {
        let withLyrics = songs.filter { !LyricsAutoMatcher.lacksLyrics($0) }
        let summarized = summaries.summarizedCount(in: withLyrics)
        let pending = withLyrics.count - summarized
        TipCard(
            symbol: "text.quote",
            color: .tileShade(hue: 0.73),
            title: "Know What Songs Are About",
            detail: "Mistral sums up each song's lyrics in one sentence, so the assistant finds a song by its subject and builds mixes around a theme. Visible and editable in the song's Info.",
            status: withLyrics.isEmpty ? String(localized: "No song has lyrics yet.") : String(localized: "\(summarized) of \(withLyrics.count) songs with lyrics summed up."),
            isDone: !withLyrics.isEmpty && pending == 0
        ) {
            if !AIFeatures.isAvailable {
                Text("Needs a Mistral key in AI Features.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open AI Features") { openSettings(.ai) }
                    .buttonStyle(.glass)
            } else if summaries.isRunning {
                ProgressView(value: Double(summaries.done), total: Double(max(summaries.total, 1)))
                HStack {
                    (summaries.isWaiting ? Text("Mistral asked to slow down. Resuming shortly…") : Text("\(summaries.done) of \(summaries.total)"))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Spacer()
                    Button("Stop", role: .cancel) { summaries.cancel() }
                        .buttonStyle(.glass)
                }
            } else if pending > 0 {
                Button {
                    summaries.run(songs: songs)
                } label: {
                    Label("Sum Up \(pending) Songs", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                Text("About \(Int((Double(pending) / Double(LyricsSummaries.batchSize)).rounded(.up))) requests with your Mistral key.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if summarized > 0 {
                NavigationLink {
                    LyricsSummariesList(songs: withLyrics)
                } label: {
                    Label("See Summaries", systemImage: "list.bullet")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            if let error = summaries.lastError, !summaries.isRunning {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var lyricsTip: some View {
        let missing = songs.filter(LyricsAutoMatcher.lacksLyrics).count
        TipCard(
            symbol: "quote.bubble.fill",
            color: .tileShade(hue: 0.57),
            title: "Find Missing Lyrics",
            detail: "Lyrics let it search songs by their words, explain them and sum them up.",
            status: missing == 0 ? String(localized: "Every song has lyrics.") : String(localized: "\(missing) songs without lyrics."),
            isDone: missing == 0
        ) {
            if missing > 0 {
                AutoMatchLyricsButton(songs: songs)
            }
        }
    }

    @ViewBuilder
    private var soundTip: some View {
        let pending = analysis.pending(in: songs).count
        TipCard(
            symbol: "waveform.badge.magnifyingglass",
            color: .tileShade(hue: 0.08),
            title: "Analyze the Library",
            detail: "Measures each song's energy, mood and tempo on this \(UIDevice.current.model), for calm, energetic or running mixes.",
            status: pending == 0 ? String(localized: "Every song is analyzed.") : String(localized: "\(pending) songs not analyzed yet."),
            isDone: pending == 0
        ) {
            if analysis.isRunning {
                ProgressView(value: analysis.progress)
                Button("Stop", role: .cancel) { analysis.cancel() }
                    .buttonStyle(.glass)
            } else if pending > 0 {
                Button {
                    analysis.start(songs: songs)
                } label: {
                    Label("Analyze \(pending) Songs", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    private var statsTip: some View {
        TipCard(
            symbol: "chart.bar.xaxis",
            color: .tileShade(hue: 0.57),
            title: "Record Listening Stats",
            detail: "Your plays over time: favorites of the month, recaps, what's on repeat, roasts.",
            status: statsOn ? String(localized: "Recording.") : String(localized: "Off."),
            isDone: statsOn
        ) {
            if !statsOn {
                Button("Turn On Listening Stats") {
                    ListeningStatsService.shared.setEnabled(true)
                    withAnimation(.smooth) { statsOn = true }
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    private var workoutsTip: some View {
        TipCard(
            symbol: "figure.run",
            color: .tileShade(hue: 0.30),
            title: "Know Your Workout Music",
            detail: "Your workouts from Apple Health tell it what you play while you exercise.",
            status: workoutsOn ? String(localized: "\(WorkoutListening.storedSessions().count) workouts found.") : String(localized: "Off."),
            isDone: workoutsOn
        ) {
            if !workoutsOn {
                Button {
                    enablingWorkouts = true
                    Task {
                        _ = await WorkoutListening.enable()
                        enablingWorkouts = false
                    }
                } label: {
                    HStack {
                        Text("Sync with Apple Health")
                        if enablingWorkouts { ProgressView().controlSize(.small) }
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(enablingWorkouts)
            }
        }
    }

    @ViewBuilder
    private var metadataTip: some View {
        let missing = songs.filter { $0.genre.trimmingCharacters(in: .whitespaces).isEmpty || $0.year <= 0 }.count
        TipCard(
            symbol: "photo.badge.arrow.down",
            color: .tileShade(hue: 0.47),
            title: "Fill In Genres and Years",
            detail: "Genres and release years make requests like “90s rap” or “some jazz” work.",
            status: missing == 0 ? String(localized: "Every song has a genre and a year.") : String(localized: "\(missing) songs miss a genre or a year."),
            isDone: missing == 0
        ) {
            if missing > 0 {
                Button("Open Missing Metadata") { openSettings(.metadata) }
                    .buttonStyle(.glass)
            }
        }
    }

    private var memoryTip: some View {
        TipCard(
            symbol: "bookmark.fill",
            color: .tileShade(hue: 0.92),
            title: "Tell It About You",
            detail: "Say “remember that…” to the assistant: favorite versions, artists to avoid, what you like when you work.",
            status: memory.items.isEmpty ? String(localized: "Nothing remembered yet.") : String(localized: "\(memory.items.count) things remembered."),
            isDone: !memory.items.isEmpty
        ) {
            EmptyView()
        }
    }
}

private struct TipCard<Actions: View>: View {
    let symbol: String
    let color: Color
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let status: String
    let isDone: Bool
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label {
                        Text(status)
                    } icon: {
                        Image(systemName: isDone ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(isDone ? color : .secondary)
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.top, 2)
                    .contentTransition(.numericText())
                }
            }
            // No actions (a tip already done): no room left for them.
            Group(subviews: actions) { subviews in
                if !subviews.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        subviews
                    }
                    .padding(.leading, 42)
                    .padding(.top, 12)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(color)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .animation(.smooth, value: isDone)
    }
}

// MARK: - Lyrics Summaries

/// Every song summed up and what its summary says; each one opens to be
/// rewritten or deleted.
private struct LyricsSummariesList: View {
    let songs: [Song]

    @ObservedObject private var summaries = LyricsSummaries.shared
    @State private var query = ""

    private var results: [(song: Song, entry: LyricsSummaries.Entry)] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return songs
            .compactMap { song in summaries.entries[song.id].map { (song, $0) } }
            .filter {
                text.isEmpty || $0.song.title.localizedStandardContains(text)
                    || $0.song.artist.localizedStandardContains(text)
                    || $0.entry.text.localizedStandardContains(text)
            }
            .sorted { $0.song.title.localizedStandardCompare($1.song.title) == .orderedAscending }
    }

    var body: some View {
        // Filtered and sorted once per pass, not once per use.
        let results = self.results
        List {
            ForEach(results, id: \.song.id) { item in
                NavigationLink {
                    LyricsSummaryEditor(song: item.song)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ArtworkImage(source: item.song.artworkSource, points: 48)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(item.song.title).lineLimit(1)
                                if item.entry.isEdited {
                                    Image(systemName: "pencil")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("Edited")
                                }
                            }
                            Text(item.song.artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(LyricsSummaries.styled(item.entry.text))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        withAnimation(.smooth) { summaries.setSummary("", for: item.song.id) }
                    }
                    .tint(.red)
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if results.isEmpty, !query.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, Artists and Subjects")
        .navigationTitle("Summaries")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LyricsSummaryEditor: View {
    let song: Song

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var deleted = false
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ArtworkImage(source: song.artworkSource, points: 56)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).font(.headline)
                        Text(song.artist).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                }
            }
            Section {
                TextField("Summary", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focused)
            } footer: {
                Text("What the assistant reads about this song. Once edited, Mistral never rewrites it.")
            }
            Section {
                Button("Delete Summary", role: .destructive) {
                    deleted = true
                    LyricsSummaries.shared.setSummary("", for: song.id)
                    dismiss()
                }
            } footer: {
                Text("Mistral writes a new one the next time songs are summed up.")
            }
        }
        .navigationTitle("Summary")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            original = LyricsSummaries.shared.summary(for: song.id) ?? ""
            text = original
        }
        .onDisappear {
            guard !deleted else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != original { LyricsSummaries.shared.setSummary(trimmed, for: song.id) }
        }
    }
}
