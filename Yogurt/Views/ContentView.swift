import AVFoundation
import OSLog
import SwiftUI

class ViewState: ObservableObject {
  @Published var errorState = ErrorState()
}

enum EnhancementStep: Int, CaseIterable {
  case idle = 0
  case transcribingNotes = 1
  case findingEmphasis = 2
  case extractingActions = 3
  case enhancing = 4

  var displayName: String {
    switch self {
    case .idle: return "Idle"
    case .transcribingNotes: return "1. Create Transcript Notes"
    case .findingEmphasis: return "2. Find Points of Emphasis"
    case .extractingActions: return "3. Extract Actions"
    case .enhancing: return "4. Generate Enhanced Notes"
    }
  }

  var shortName: String {
    switch self {
    case .idle: return "Idle"
    case .transcribingNotes: return "Trans"
    case .findingEmphasis: return "Emph"
    case .extractingActions: return "Act"
    case .enhancing: return "Gen"
    }
  }
}

struct EnhancementProgress {
  var transcriptionNotes: String = ""
  var pointsOfEmphasis: String = ""
  var actionItems: String = ""
}

struct ContentView: View {

  // MARK: - Audio & Recording
  @State private var recordingPermission = RecordingPermission()
  @State private var audioManager = AudioSourceManager()
  @State var transcriber: ProcessTapRecorder? = nil
  @State private var micRecorder = MicrophoneRecorder()

  // MARK: - Model & Services
  @StateObject private var noteManager = NoteManager.shared
  @StateObject private var cloudflareService = CloudflareService.shared
  @StateObject private var viewState = ViewState()
  private let fileManager = NoteFileManager.shared

  // MARK: - Note Selection
  @State private var selectedNote: Note?
  @State private var notes: [Note] = []

  // MARK: - Text Editor
  @State var typedNotes = ""
  @State var transcript = ""
  @State var isRecording = false
  @State private var lastSavedContent: String = ""
  @State private var textViewRef = TextViewReference()

  // Currently active note for recording
  @State private var recordingTargetNote: Note?
  // Currently enhancing note (may be different from selected note)
  @State private var enhancementTargetNote: Note?

  // MARK: - Enhancement
  @State var isEnhancing = false
  @State private var enhancedLines: [String] = []
  @State private var originalLines: [String] = []
  @State private var currentLineBuffer: String = ""
  @State private var scanningIndex: Int = 0
  @State private var isDone: Bool = false
  @State private var lastCompletedIndex: Int = -1
  @State private var textHeights: [Int: CGFloat] = [:]
  @State private var currentLineHeight: CGFloat = 0
  @State private var progressValue: CGFloat = 0.0
  @State private var showCheckmark = false
  @State private var isMorphingToControls = false
  @State private var morphProgress: CGFloat = 0
  @State private var enhancementStep: EnhancementStep = .idle

  // MARK: - Versions
  @State private var viewingVersionContent: String?
  @State private var selectedVersion: NoteVersion?
  @State private var versionsForCurrentNote: [NoteVersion] = []

  private var combinedAmplitude: Float {
    // Combine mic + system amplitude
    let boostedMic = micRecorder.amplitude * 1.65
    return max(boostedMic, transcriber?.amplitude ?? 0)
  }

  // MARK: - Other
  let debugManager = DebugManager.shared
  let logger = Logger(subsystem: kAppSubsystem, category: "ContentView")
  private let browserFinder = DefaultBrowserFinder()

  // Timer for auto-saving typed notes
  private let autoSaveTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
  @State private var lastSaveTimestamp: Date = Date()
  @State private var hasPendingChanges: Bool = false
  private let minTimeBetweenSaves: TimeInterval = 1.0

  // Layout styling
  @State private var currentSidebarWidth: CGFloat = 250
  let fontSize: CGFloat = 16
  let horizontalPadding: CGFloat = 12
  let verticalPadding: CGFloat = 0.2

  private var isViewingPastVersion: Bool {
    viewingVersionContent != nil || selectedVersion != nil
  }

  private var shouldDisableVersionSelector: Bool {
    isRecording || enhancementTargetNote != nil
  }

  // Disable recording controls if ANY note is being enhanced or if another note is active
  private var shouldDisableRecordingControlsForSelectedNote: Bool {
    // If ANY note is being enhanced, disable all recording controls
    if enhancementTargetNote != nil {
      return true
    }

    guard let sel = selectedNote else { return true }
    if let activeNote = noteManager.notes.first(where: { $0.isRecording || $0.hasPendingTranscript }
    ) {
      return activeNote.id != sel.id
    }
    return false
  }

  // MARK: - Body
  var body: some View {
    HSplitView {
      // Sidebar
      SidebarView(selectedNote: $selectedNote, combinedAmplitude: combinedAmplitude)
        .frame(minWidth: 250, idealWidth: 250, maxWidth: 450)
        .layoutPriority(1)
        .background(
          SidebarWidthReader { width in
            currentSidebarWidth = width
          }
        )

      // Main content
      GeometryReader { mainGeometry in
        ZStack {
          if let note = selectedNote {
            mainContentView(geometry: mainGeometry)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
      }
      .layoutPriority(2)
    }
    // Toolbar items
    .toolbar {
      // Left side: new note / delete note
      ToolbarItemGroup(placement: .primaryAction) {
        HStack(spacing: 16) {
          Spacer()
            .frame(width: currentSidebarWidth - 200)

          Button(action: createNewNote) {
            Image(systemName: "square.and.pencil")
              .font(.system(size: 12))
              .foregroundColor(.secondary)
          }
          .help("New Note")

          if selectedNote != nil {
            Button(action: {
              if let note = selectedNote {
                deleteNote(note)
              }
            }) {
              Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }
            .help("Delete Note")
          }
        }
      }

      // Right side: version selector
      ToolbarItemGroup(placement: .automatic) {
        Spacer()
        if let note = selectedNote {
          VersionSelectorView(
            versions: versionsForCurrentNote,
            onVersionSelect: { version in
              switchToVersion(version)
            },
            onApplyVersion: { version in
              applyVersion(version)
            },
            noteId: note.id
          )
          .disabled(shouldDisableVersionSelector)
        }
      }
    }
    // Keep local `notes` in sync with the manager
    .onReceive(noteManager.$notes) { updatedNotes in
      notes = updatedNotes
    }
    .onChange(of: selectedNote) { oldNote, newNote in
      if let prev = oldNote {
        saveNoteContent(prev, content: typedNotes)
      }
      loadSelectedNote()

      viewingVersionContent = nil
      selectedVersion = nil
      updateVersionsForCurrentNote()

      DispatchQueue.main.async {
        textViewRef.textView?.forceStyleText()
      }
    }
    .onAppear {
      audioManager.loadAvailableSources()
      if selectedNote == nil {
        let all = noteManager.getAllNotes()
        selectedNote = all.first
      }
    }
    .onReceive(autoSaveTimer) { _ in
      saveCurrentNote()
      checkPendingChanges()
    }
  }

  // MARK: - Main Content
  private func mainContentView(geometry: GeometryProxy) -> some View {
    ZStack {
      if let note = selectedNote {
        VStack(spacing: 0) {
          if !isEnhancing || note.id != enhancementTargetNote?.id {
            if let versionContent = viewingVersionContent {
              // Past version read-only
              ScrollView {
                Text(versionContent)
                  .font(.system(size: 16))
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding()
              }
            } else {
              // Editable text
              editorView
            }
          } else {
            // Enhancement UI - only show if this note is the target of enhancement
            EnhancementScannerView(
              width: geometry.size.width,
              originalLines: $originalLines,
              enhancedLines: $enhancedLines,
              currentLineBuffer: $currentLineBuffer,
              scanningIndex: $scanningIndex,
              isDone: $isDone,
              lastCompletedIndex: $lastCompletedIndex,
              textHeights: $textHeights,
              currentLineHeight: $currentLineHeight,
              progressValue: $progressValue,
              showCheckmark: $showCheckmark,
              isMorphingToControls: $isMorphingToControls,
              morphProgress: $morphProgress,
              enhancementStep: enhancementStep,
              fontSize: fontSize,
              horizontalPadding: horizontalPadding,
              verticalPadding: verticalPadding,
              isEnhancing: $isEnhancing
            )
          }
        }

        // Floating bottom controls
        VStack {
          Spacer()
          HStack {
            Spacer()
            VStack(spacing: 12) {
              if viewState.errorState.isVisible {
                ErrorBanner(
                  message: viewState.errorState.message,
                  retryCount: viewState.errorState.retryCount,
                  maxRetries: viewState.errorState.maxRetries,
                  isVisible: Binding(
                    get: { viewState.errorState.isVisible },
                    set: { viewState.errorState.isVisible = $0 }
                  )
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
              }

              unifiedControls
            }
            Spacer()
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(NSColor.textBackgroundColor))
  }

  private var editorView: some View {
    MarkdownEditor(text: $typedNotes, noteId: selectedNote?.id ?? "", textViewRef: $textViewRef)
      .padding(.top, 32)
      .padding(.leading, 8)
      .padding(.bottom, 30)
      .background(Color(NSColor.textBackgroundColor))
      .edgesIgnoringSafeArea(.all)
  }

  // MARK: - Unified Controls (Recording + Enhance + Discard)
  private var unifiedControls: some View {
    // (Record/Stop + Audio Selector) and the optional Enhance/Discard group.
    HStack(spacing: 12) {
      // --- Left block: Recording controls ---
      HStack(spacing: 8) {
        recordStopGroup
        audioSourceDivider
      }
      .frame(height: 44)
      .padding(.horizontal, 10)
      .background(Color.gray.opacity(0.6))
      .cornerRadius(22)

      // --- Right block (Enhance & Discard) ---
      if let note = selectedNote,
        note.hasPendingTranscript && !isRecording && recordingTargetNote != nil
      {
        HStack(spacing: 8) {
          // Enhance
          Button {
            if let note = recordingTargetNote {
              streamEnhanceNotes(forNote: note)
            }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "wand.and.stars")
                .font(.system(size: 14, weight: .semibold))
              Text("Enhance")
                .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .frame(height: 36)
            .padding(.horizontal, 12)
            .background(
              LinearGradient(
                gradient: Gradient(colors: [
                  Color.orange.opacity(0.7),
                  Color.orange.opacity(0.9),
                ]),
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .cornerRadius(16)
          }
          .buttonStyle(.plain)

          // Discard
          Button {
            discardTranscript()
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "trash")
                .font(.system(size: 14, weight: .medium))
              Text("Discard")
                .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.red.opacity(0.8))
            .frame(height: 36)
            .padding(.horizontal, 12)
            .background(Color.red.opacity(0.1))
            .cornerRadius(16)
          }
          .buttonStyle(.plain)
          .help("Discard current recording transcript")
        }
        .transition(
          .asymmetric(
            insertion: .move(edge: .trailing)
              .combined(with: .scale(scale: 0.95))
              .combined(with: .opacity),
            removal: .move(edge: .trailing)
              .combined(with: .scale(scale: 0.95))
              .combined(with: .opacity)
          )
        )
      }
    }
    .animation(
      .easeInOut(duration: 0.3),
      value: selectedNote?.hasPendingTranscript == true
        && !isRecording
        && recordingTargetNote != nil
    )
    .padding(.bottom, 24)
    .disabled(
      !cloudflareService.isConfigured
        || isViewingPastVersion
        || shouldDisableRecordingControlsForSelectedNote
    )
  }

  private var recordStopGroup: some View {
    HStack(spacing: 0) {
      recordButton
      stopButton
    }
  }

  private var audioSourceDivider: some View {
    Group {
      if !isRecording {
        // Only show audio selection if not recording
        Divider()
          .frame(width: 1, height: 25)
          .background(Color.white.opacity(0.8))

        AudioSourceSelectorView(audioManager: audioManager) { source in
          audioManager.setSelection(source: source)
        }
        .frame(width: 28, height: 22)
        .padding(.leading, 4)
        .padding(.trailing, 9)
      }
    }
  }

  private var recordButton: some View {
    Button {
      Task { await startRecording() }
    } label: {
      if isRecording {
        AudioWaveformIndicator(amplitude: combinedAmplitude, isSelected: true)
          .frame(width: 28, height: 18)
      } else {
        Image(systemName: "circle.fill")
          .font(.system(size: 14, weight: .bold))
          .foregroundColor(.white)
      }
    }
    .buttonStyle(.plain)
    .padding(.leading, 10)
    .padding(.trailing, 7)
    .padding(.vertical, 12)
    .disabled(isRecording)
  }

  private var stopButton: some View {
    Button {
      stopRecording()
    } label: {
      Image(systemName: "square.fill")
        .font(.system(size: 18, weight: .bold))
        .foregroundColor(.white)
    }
    .buttonStyle(.plain)
    .padding(.leading, 7)
    .padding(.trailing, isRecording ? 10 : 4)
    .padding(.vertical, 12)
    .disabled(!isRecording)
  }

  private func discardTranscript() {
    guard let note = recordingTargetNote else { return }
    transcript = ""
    noteManager.clearPendingTranscript(noteId: note.id)
    noteManager.refreshNotes()
    if let updated = noteManager.notes.first(where: { $0.id == note.id }) {
      selectedNote = updated
    }
    logger.info("User discarded transcript for note \(note.id).")
  }

  // MARK: - Lifecycle Helpers
  private func loadSelectedNote() {
    guard let note = selectedNote else {
      typedNotes = ""
      lastSavedContent = ""
      return
    }
    do {
      let (_, content) = try noteManager.getNote(withId: note.id)
      typedNotes = content
      lastSavedContent = content
    } catch {
      logger.error("Failed to load note: \(error.localizedDescription)")
    }
  }

  private func createNewNote() {
    let note = noteManager.createNote()
    notes = noteManager.getAllNotes()
    selectedNote = note
  }

  private func deleteNote(_ note: Note) {
    do {
      try noteManager.deleteNote(withId: note.id)
      notes = noteManager.getAllNotes()
      selectedNote = notes.first
    } catch {
      logger.error("Failed to delete note: \(error.localizedDescription)")
    }
  }

  // MARK: - Auto-Save
  private func saveCurrentNote() {
    guard typedNotes != lastSavedContent,
      let note = selectedNote
    else { return }

    let currentTime = Date()
    let timeSinceLastSave = currentTime.timeIntervalSince(lastSaveTimestamp)
    if timeSinceLastSave < minTimeBetweenSaves {
      hasPendingChanges = true
      return
    }

    do {
      var noteToUpdate = note
      if let fresh = noteManager.notes.first(where: { $0.id == note.id }) {
        noteToUpdate.isRecording = fresh.isRecording
        noteToUpdate.isEnhancing = fresh.isEnhancing
        noteToUpdate.hasPendingTranscript = fresh.hasPendingTranscript
      }

      try noteManager.updateNote(noteToUpdate, withContent: typedNotes)
      lastSavedContent = typedNotes
      lastSaveTimestamp = currentTime
      hasPendingChanges = false

      logger.debug("Auto-saved note: \(note.id)")
    } catch {
      logger.error("Auto-save failed: \(error.localizedDescription)")
      hasPendingChanges = true
    }
  }

  private func checkPendingChanges() {
    if hasPendingChanges {
      let timeSinceLastSave = Date().timeIntervalSince(lastSaveTimestamp)
      if timeSinceLastSave >= minTimeBetweenSaves {
        saveCurrentNote()
      }
    }
  }

  private func saveNoteContent(_ note: Note, content: String) {
    guard (try? noteManager.getNote(withId: note.id)) != nil else {
      logger.debug("Note \(note.id) no longer exists; skipping save.")
      return
    }
    do {
      var updatedNote = note
      if let fresh = noteManager.notes.first(where: { $0.id == note.id }) {
        updatedNote.isRecording = fresh.isRecording
        updatedNote.isEnhancing = fresh.isEnhancing
        updatedNote.hasPendingTranscript = fresh.hasPendingTranscript
      }
      try noteManager.updateNote(updatedNote, withContent: content)

      if note.id == selectedNote?.id {
        lastSavedContent = content
      }
      notes = noteManager.getAllNotes()
    } catch {
      logger.error("Save failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Versions
  private func updateVersionsForCurrentNote() {
    if let noteId = selectedNote?.id,
      let allVersions = try? fileManager.getVersions(forId: noteId)
    {
      versionsForCurrentNote = allVersions
    } else {
      versionsForCurrentNote = []
    }
  }

  private func switchToVersion(_ version: NoteVersion?) {
    guard let note = selectedNote else { return }
    if let version = version {
      do {
        let versionContent = try noteManager.getVersionContent(version, forNote: note)
        viewingVersionContent = versionContent
        selectedVersion = version
      } catch {
        logger.error("Failed to switch version: \(error.localizedDescription)")
      }
    } else {
      viewingVersionContent = nil
      selectedVersion = nil
    }
  }

  private func applyVersion(_ version: NoteVersion) {
    guard let note = selectedNote else { return }
    do {
      if let mostRecent = versionsForCurrentNote.max(by: { $0.timestamp < $1.timestamp }),
        let mostRecentContent = try? noteManager.getVersionContent(mostRecent, forNote: note),
        typedNotes != mostRecentContent
      {
        _ = try noteManager.createVersion(
          forNote: note,
          content: typedNotes
        )
      }

      let versionContent = try noteManager.getVersionContent(version, forNote: note)
      typedNotes = versionContent
      viewingVersionContent = nil
      selectedVersion = nil

      try noteManager.updateNote(note, withContent: versionContent)
      noteManager.refreshNotes()
      updateVersionsForCurrentNote()
    } catch {
      logger.error("Failed to apply version: \(error.localizedDescription)")
    }
  }

  // MARK: - Recording Flow
  func startRecording() async {
    guard let sel = selectedNote else { return }

    // If note doesn't have a partial transcript, reset transcript:
    if !sel.hasPendingTranscript {
      transcript = ""
    }

    // Update the note's title, record state, etc.
    var updatedNote = sel
    let lines = typedNotes.components(separatedBy: .newlines)
    updatedNote.title = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled"
    recordingTargetNote = updatedNote

    // Check permissions
    guard await checkRecordingPermissions() else {
      logger.error("Recording permissions denied.")
      return
    }

    // Mark note as recording
    DispatchQueue.main.async {
      self.noteManager.updateNoteStates(recordingId: updatedNote.id)
    }

    do {
      // Start the "process" tap if user selected a process
      if let processSource = audioManager.selections.selectedProcess {
        if processSource.id == "system-audio" {
          let systemProcess = AudioProcess.systemWideAudio()
          let newTranscriber = ProcessTapRecorder(process: systemProcess) { chunkData in
            sendChunkToTranscribeEndpoint(chunkData)
          }
          try newTranscriber.start()
          self.transcriber = newTranscriber
        } else {
          let newTranscriber = ProcessTapRecorder(
            process: AudioProcess.specificProcess(
              pid: Int32(processSource.id) ?? -1,
              name: processSource.name,
              bundleURL: processSource.bundleURL,
              objectID: processSource.objectID
            )
          ) { chunkData in
            sendChunkToTranscribeEndpoint(chunkData)
          }
          try newTranscriber.start()
          self.transcriber = newTranscriber
        }
      } else {
        // No specific process => default browser
        let process = try browserFinder.findDefaultBrowserProcess()
        let newTranscriber = ProcessTapRecorder(process: process) { chunkData in
          sendChunkToTranscribeEndpoint(chunkData)
        }
        try newTranscriber.start()
        self.transcriber = newTranscriber
      }

      // If a real mic device was chosen, set it as default
      if let inputSource = audioManager.selections.selectedInput,
        inputSource.objectID.isValid
      {
        let err = setDefaultInputDevice(inputSource.objectID)
        if err != noErr {
          logger.error("Failed to set input device: \(err)")
        }
      }

      // -----------------------------------------------------------------
      // Start the MicrophoneRecorder
      try micRecorder.start { chunkData in
        sendChunkToTranscribeEndpoint(chunkData)
      }

      self.isRecording = true
      logger.info("Microphone recording started")
      logger.info("Recording started for note: \(updatedNote.id)")

    } catch {
      logger.error("Failed to start recording: \(error.localizedDescription)")
      DispatchQueue.main.async {
        self.noteManager.clearStates()
      }
    }
  }

  private func stopRecording() {
    DispatchQueue.global(qos: .userInitiated).async {
      self.transcriber?.stop()
      self.transcriber = nil
      self.micRecorder.stop()

      DispatchQueue.main.async {
        self.isRecording = false
        self.noteManager.clearStates()
        if let note = self.recordingTargetNote {
          self.noteManager.markPendingTranscript(noteId: note.id)
          self.noteManager.refreshNotes()
          if let updated = self.noteManager.notes.first(where: { $0.id == note.id }) {
            self.selectedNote = updated
          }
          self.logger.info("Recording stopped. Marked note as pending transcript.")
        }
      }
    }
  }

  private func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> OSStatus {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var mutableDeviceID = deviceID
    return AudioObjectSetPropertyData(
      AudioObjectID.system,
      &address,
      0,
      nil,
      UInt32(MemoryLayout<AudioDeviceID>.size),
      &mutableDeviceID
    )
  }

  private func sendChunkToTranscribeEndpoint(_ chunk: Data) {
    guard let baseURL = CloudflareService.shared.getWorkerURL(),
      let url = URL(string: "transcribe", relativeTo: baseURL)
    else {
      logger.error("No Cloudflare Worker URL, cannot transcribe.")
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue("\(chunk.count)", forHTTPHeaderField: "Content-Length")
    request.httpBody = chunk
    CloudflareService.shared.prepareRequest(&request)

    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error = error {
        self.logger.error("Transcription network error: \(error.localizedDescription)")
        return
      }
      guard let httpResponse = response as? HTTPURLResponse else {
        self.logger.error("Invalid response from transcription.")
        return
      }
      guard (200...299).contains(httpResponse.statusCode) else {
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
          DispatchQueue.main.async {
            self.viewState.errorState.show(
              message: "Transcription authentication error. Check config."
            )
          }
        }
        self.logger.error("Transcription error: HTTP \(httpResponse.statusCode)")
        return
      }
      guard let data = data else {
        self.logger.error("Transcription response was empty.")
        return
      }

      do {
        // Try JSON
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = json["text"] as? String
        {
          DispatchQueue.main.async {
            self.transcript += text + " "
            self.logger.info("Transcript so far: \(self.transcript)")  // debug logging
          }
        } else if let plain = String(data: data, encoding: .utf8),
          !plain.isEmpty
        {
          DispatchQueue.main.async {
            self.transcript += plain + " "
            self.logger.info("Transcript so far: \(self.transcript)")  // debug logging
          }
        }
      } catch {
        self.logger.error("Failed to parse transcript JSON: \(error.localizedDescription)")
      }
    }.resume()
  }

  // MARK: - Enhancement Flow
  private func streamEnhanceNotes(forNote note: Note) {
    // Reset for UI
    self.enhancedLines = []
    self.currentLineBuffer = ""

    // Store the note being enhanced
    self.enhancementTargetNote = note

    // Only update UI elements if this is the selected note
    if selectedNote?.id == note.id {
      DispatchQueue.main.async {
        let content = (try? self.noteManager.getNote(withId: note.id).1) ?? ""
        self.originalLines = content.components(separatedBy: "\n")
        self.scanningIndex = 0
        self.isDone = false
        self.isEnhancing = true
      }
    }

    noteManager.updateEnhancingState(noteId: note.id)

    // Set up the pipeline manager's delegate
    let pipelineManager = LLMPipelineManager.shared
    pipelineManager.delegate = self

    // Start the enhancement process
    pipelineManager.enhanceNote(note, transcript: transcript)
  }

  // MARK: - SSE Content
  func appendEnhancedText(_ partialText: String) {
    DispatchQueue.main.async {
      let lines = partialText.components(separatedBy: "\n")
      for (i, piece) in lines.enumerated() {
        self.currentLineBuffer += piece
        if i < lines.count - 1 {
          self.enhancedLines.append(self.currentLineBuffer)
          self.currentLineBuffer = ""

          withAnimation(.easeInOut(duration: 0.3)) {
            self.scanningIndex = self.enhancedLines.count
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeInOut(duration: 0.2)) {
              self.lastCompletedIndex = self.enhancedLines.count - 1
            }
          }
        }
      }
    }
  }

  // MARK: - Permissions
  private func checkRecordingPermissions() async -> Bool {
    logger.info("Checking recording permissions...")

    if recordingPermission.areAllPermissionsGranted {
      return true
    }

    let granted = await recordingPermission.requestAllPermissions()
    if !granted {
      if recordingPermission.microphoneStatus == .denied
        || recordingPermission.systemAudioStatus == .denied
      {
        NSWorkspace.shared.openSystemSettings()
      }
    }
    return granted
  }
}

extension ContentView: LLMPipelineDelegate {
  func pipelineDidStart() {
    enhancementStep = .transcribingNotes
  }

  func pipelineDidUpdateStep(_ step: EnhancementStep) {
    enhancementStep = step
  }

  func pipelineDidReceiveContent(content: String) {
    appendEnhancedText(content)
  }

  func pipelineDidComplete() {
    // Complete the enhancement with UI animations
    let enhancedLines = self.enhancedLines
    var finalContent = enhancedLines.joined(separator: "\n")

    if !currentLineBuffer.isEmpty {
      let lastLine = enhancedLines.last ?? ""
      if lastLine != currentLineBuffer {
        finalContent = finalContent + (finalContent.isEmpty ? "" : "\n") + currentLineBuffer
      }
    }

    // Ensure we have a targetNote to work with
    guard let targetNote = self.enhancementTargetNote else {
      return
    }

    noteManager.clearPendingTranscript(noteId: targetNote.id)
    noteManager.clearStates()
    noteManager.refreshNotes()
    self.recordingTargetNote = nil

    // Process the enhanced content
    processEnhancedContent(finalContent, forNote: targetNote)

    // Handle UI animations
    if selectedNote?.id == targetNote.id {
      animateEnhancementCompletion()
    } else {
      // If not looking at the enhanced note, just clean up
      DispatchQueue.main.async {
        noteManager.updateEnhancingState(noteId: nil)
        self.enhancementTargetNote = nil
      }
    }
  }

  func pipelineDidFail(error: Error) {
    DispatchQueue.main.async {
      if case let AIClientError.serverError(statusCode, retryCount) = error {
        viewState.errorState.show(
          message: "Server error (Status \(statusCode)). Retrying...",
          retryCount: retryCount + 1,
          maxRetries: 3
        )
      } else if case let AIClientError.maxRetriesExceeded(statusCode) = error {
        viewState.errorState.show(
          message: "Server error (Status \(statusCode)). Enhancement failed."
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
          withAnimation {
            viewState.errorState.clear()
          }
        }
        self.isEnhancing = false
        self.enhancementTargetNote = nil
      } else {
        viewState.errorState.show(
          message: "Enhancement failed: \(error.localizedDescription)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
          withAnimation {
            viewState.errorState.clear()
          }
        }
        self.isEnhancing = false
        self.enhancementTargetNote = nil
      }

      // Clear and reset any enhancement state
      self.enhancedLines = []
      self.currentLineBuffer = ""
    }
  }

  private func processEnhancedContent(_ enhancedContent: String, forNote note: Note) {
    // Get the original content for the target note
    let originalContent: String
    do {
      let (_, content) = try noteManager.getNote(withId: note.id)
      originalContent = content
    } catch {
      logger.error(
        "Failed to get original content for note \(note.id): \(error.localizedDescription)")
      originalContent = ""
    }

    // Save a version and update the note with enhanced content
    LLMPipelineManager.shared.finishEnhancement(
      enhancedContent: enhancedContent,
      forNote: note,
      originalContent: originalContent
    )

    // If the enhanced note is the currently selected note, update the UI
    if selectedNote?.id == note.id {
      self.typedNotes = enhancedContent
      self.viewingVersionContent = nil
      self.selectedVersion = nil
      updateVersionsForCurrentNote()
    }
  }

  private func animateEnhancementCompletion() {
    debugManager.completeStep(.enhancing)

    // Animate progress -> checkmark
    withAnimation(.easeOut(duration: 0.3)) {
      self.progressValue = 1.0
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      withAnimation(.easeInOut(duration: 0.3)) {
        self.showCheckmark = true
        self.isDone = true
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        self.isMorphingToControls = true
        withAnimation(.easeInOut(duration: 0.8)) {
          self.morphProgress = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
          withAnimation(.easeOut(duration: 0.2)) {
            self.isEnhancing = false
          }
          self.showCheckmark = false
          self.isMorphingToControls = false
          self.morphProgress = 0
          self.textViewRef.textView?.forceStyleText()

          self.updateVersionsForCurrentNote()

          // Final cleanup
          self.transcript = ""
          self.enhancementTargetNote = nil

          // Make sure note is no longer marked as enhancing
          self.noteManager.updateEnhancingState(noteId: nil)
        }
      }
    }
  }
}

// MARK: - Helper Views

// Reads the sidebar's width so we can position toolbar items dynamically.
struct SidebarWidthReader: NSViewRepresentable {
  let onWidthChange: (CGFloat) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification,
      object: view,
      queue: .main
    ) { _ in
      onWidthChange(view.frame.width)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

extension NSWorkspace {
  func openSystemSettings() {
    guard let url = urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
      assertionFailure("Could not get System Settings app URL")
      return
    }
    openApplication(at: url, configuration: .init())
  }
}
