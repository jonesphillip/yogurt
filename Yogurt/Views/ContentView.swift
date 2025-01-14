import AVFoundation
import OSLog
import SwiftUI

struct ContentView: View {

  @State private var recordingPermission = RecordingPermission()
  @State private var audioManager = AudioSourceManager()
  @State var transcriber: ProcessTapRecorder? = nil
  @State private var micRecorder = MicrophoneRecorder()

  @StateObject private var noteManager = NoteManager.shared
  @StateObject private var cloudflareService = CloudflareService.shared
  private let fileManager = NoteFileManager.shared

  @State private var selectedNote: Note?
  @State private var notes: [Note] = []

  @State var typedNotes = ""
  @State var transcript = ""
  @State var isRecording = false
  @State private var lastSavedContent: String = ""

  @State private var recordingTargetNote: Note?
  @State var isEnhancing = false

  @State private var textViewRef = TextViewReference()

  @State private var enhancedLines: [String] = []
  @State private var originalLines: [String] = []
  @State private var currentLineBuffer: String = ""
  @State private var scanningIndex: Int = 0
  @State private var isDone: Bool = false
  @State private var lastCompletedIndex: Int = -1

  @State private var textHeights: [Int: CGFloat] = [:]
  @State private var currentLineHeight: CGFloat = 0
  @State private var currentSidebarWidth: CGFloat = 250

  @State private var progressValue: CGFloat = 0.0
  @State private var showCheckmark = false
  @State private var isMorphingToControls = false
  @State private var morphProgress: CGFloat = 0

  let logger = Logger(subsystem: kAppSubsystem, category: "ContentView")
  private let browserFinder = DefaultBrowserFinder()
  private let autoSaveTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
  @State private var lastSaveTimestamp: Date = Date()
  @State private var hasPendingChanges: Bool = false
  private let minTimeBetweenSaves: TimeInterval = 1.0

  let fontSize: CGFloat = 16
  let horizontalPadding: CGFloat = 12
  let verticalPadding: CGFloat = 0.2

  var body: some View {
    HSplitView {
      SidebarView(selectedNote: $selectedNote)
        .frame(minWidth: 250, idealWidth: 250, maxWidth: 450)
        .layoutPriority(1)
        .background(
          SidebarWidthReader { width in
            currentSidebarWidth = width
          }
        )

      GeometryReader { mainGeometry in
        ZStack {
          if let note = selectedNote {
            mainContentView(geometry: mainGeometry)
            controlsOverlay
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
      }
      .layoutPriority(2)
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
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
    }
    .onReceive(noteManager.$notes) { updatedNotes in
      notes = updatedNotes.map { note in
        var noteCopy = note
        // Preserve recording/enhancing states from existing notes
        if let existingNote = notes.first(where: { $0.id == note.id }) {
          noteCopy.isRecording = existingNote.isRecording
          noteCopy.isEnhancing = existingNote.isEnhancing
        }
        return noteCopy
      }
    }
    .onChange(of: selectedNote) { oldNote, newNote in
      if let previousNote = oldNote {
        saveNoteContent(previousNote, content: typedNotes)
      }
      loadSelectedNote()
      DispatchQueue.main.async {
        textViewRef.textView?.forceStyleText()
      }
    }
    .onAppear {
      audioManager.loadAvailableSources()

      if selectedNote == nil {
        let notes = NoteManager.shared.getAllNotes()
        selectedNote = notes.first
      }
    }
    .onReceive(autoSaveTimer) { _ in
      saveCurrentNote()
      checkPendingChanges()
    }
  }

  // MARK: - Main Content Views

  private func mainContentView(geometry: GeometryProxy) -> some View {
    Group {
      if !isEnhancing {
        editorView
      } else {
        enhancedContentView(width: geometry.size.width)
      }
    }
  }

  private var editorView: some View {
    MarkdownEditor(text: $typedNotes, noteId: selectedNote?.id ?? "", textViewRef: $textViewRef)
      .padding(.top, 32)
      .padding(.leading, 8)
      .padding(.bottom, 30)
      .background(Color(NSColor.textBackgroundColor))
      .edgesIgnoringSafeArea(.all)
  }

  private func enhancedContentView(width: CGFloat) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(0..<max(originalLines.count, enhancedLines.count), id: \.self) { idx in
          lineView(for: idx, maxWidth: width)
        }
        Spacer(minLength: 30)
      }
    }
    .padding(.top, 62)
    .padding(.leading, 12)
    .padding(.trailing, 12)
    .background(Color(NSColor.textBackgroundColor))
    .edgesIgnoringSafeArea(.all)
    .overlay(scannerBarOverlay)
  }

  private func lineView(for idx: Int, maxWidth: CGFloat) -> some View {
    Group {
      if idx <= lastCompletedIndex && idx < enhancedLines.count {
        completedLineView(text: enhancedLines[idx], index: idx, maxWidth: maxWidth)
      } else if idx < originalLines.count {
        pendingLineView(text: originalLines[idx], index: idx, maxWidth: maxWidth)
      }
    }
  }

  private func completedLineView(text: String, index: Int, maxWidth: CGFloat) -> some View {
    TextMeasurementView(
      text: text,
      fontSize: fontSize,
      maxWidth: maxWidth - horizontalPadding * 2,
      onHeightChange: { height in
        textHeights[index] = height
      }
    )
    .padding(.leading, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .transition(.opacity)
  }

  private func pendingLineView(text: String, index: Int, maxWidth: CGFloat) -> some View {
    TextMeasurementView(
      text: text,
      fontSize: fontSize,
      maxWidth: maxWidth - horizontalPadding * 2,
      onHeightChange: { height in
        if index == scanningIndex {
          currentLineHeight = height
        }
        textHeights[index] = height
      }
    )
    .padding(.leading, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .foregroundColor(.gray)
    .opacity(index == scanningIndex ? 0 : 1)
  }

  private var controlsOverlay: some View {
    VStack {
      Spacer()
      HStack {
        Spacer()
        recordingControls
        Spacer()
      }
    }
  }

  private var recordingControls: some View {
    HStack(spacing: 0) {
      recordButton
      stopButton
      if !isRecording {
        audioSourceControls
      } else {
        Spacer().frame(width: 9, height: 0)
      }
    }
    .background(Color.gray.opacity(0.6))
    .cornerRadius(29)
    .padding(.bottom, 16)
    .disabled(!cloudflareService.isConfigured)
    .opacity(cloudflareService.isConfigured ? 1.0 : 0.5)
  }

  private var recordButton: some View {
    Button(action: {
      Task {
        await startRecording()
      }
    }) {
      if isRecording {
        AudioWaveformIndicator(isSelected: true)
          .frame(width: 29, height: 19)
      } else {
        Image(systemName: "circle.fill")
          .font(.system(size: 14, weight: .bold))
          .foregroundColor(.white)
      }
    }
    .buttonStyle(.plain)
    .padding(.leading, 14)
    .padding(.trailing, 7)
    .padding(.vertical, 10)
    .disabled(isRecording)
  }

  private var stopButton: some View {
    Button(action: { stopRecording() }) {
      Image(systemName: "square.fill")
        .font(.system(size: 19, weight: .bold))
        .foregroundColor(.white)
    }
    .buttonStyle(.plain)
    .padding(.leading, 7)
    .padding(.trailing, 10)
    .padding(.vertical, 10)
    .disabled(!isRecording)
  }

  private var audioSourceControls: some View {
    HStack {
      Divider()
        .frame(width: 1, height: 19)
        .background(Color.white.opacity(0.8))

      AudioSourceSelectorView(
        audioManager: audioManager,
        onSelect: { source in
          audioManager.setSelection(source: source)
        }
      )
      .frame(width: 28, height: 19)
      .padding(.leading, 8)
      .padding(.trailing, 14)
      .padding(.vertical, 10)
    }
  }

  private func loadSelectedNote() {
    guard let note = selectedNote else {
      typedNotes = ""
      lastSavedContent = ""
      return
    }

    do {
      let (_, content) = try NoteManager.shared.getNote(withId: note.id)
      typedNotes = content
      lastSavedContent = content
    } catch {
      logger.error("Failed to load note: \(error.localizedDescription)")
    }
  }

  private func createNewNote() {
    let note = NoteManager.shared.createNote()
    notes = NoteManager.shared.getAllNotes()
    selectedNote = note
  }

  private func saveCurrentNote() {
    // Skip if no changes or no selected note
    guard !typedNotes.isEmpty,
      typedNotes != lastSavedContent,
      let note = selectedNote
    else { return }

    let currentTime = Date()
    let timeSinceLastSave = currentTime.timeIntervalSince(lastSaveTimestamp)

    if timeSinceLastSave < minTimeBetweenSaves {
      hasPendingChanges = true
      return
    }

    do {
      let currentStates = noteManager.notes.first(where: { $0.id == note.id })
      var noteToUpdate = note
      if let states = currentStates {
        noteToUpdate.isRecording = states.isRecording
        noteToUpdate.isEnhancing = states.isEnhancing
      }

      logger.debug(
        "Saving note \(noteToUpdate.id) - recording: \(noteToUpdate.isRecording), enhancing: \(noteToUpdate.isEnhancing)"
      )

      // Save the current content
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

  // Add this function to check pending changes
  private func checkPendingChanges() {
    if hasPendingChanges {
      let timeSinceLastSave = Date().timeIntervalSince(lastSaveTimestamp)
      if timeSinceLastSave >= minTimeBetweenSaves {
        saveCurrentNote()
      }
    }
  }

  private func saveNoteContent(_ note: Note, content: String) {
    guard !content.isEmpty else { return }

    do {
      let currentStates = noteManager.notes.first(where: { $0.id == note.id })
      var noteToUpdate = note
      if let states = currentStates {
        noteToUpdate.isRecording = states.isRecording
        noteToUpdate.isEnhancing = states.isEnhancing
      }

      logger.debug(
        "Saving note \(noteToUpdate.id) - recording: \(noteToUpdate.isRecording), enhancing: \(noteToUpdate.isEnhancing)"
      )

      try NoteManager.shared.updateNote(noteToUpdate, withContent: content)

      if note.id == selectedNote?.id {
        lastSavedContent = content
      }

      // Refresh the notes list
      notes = NoteManager.shared.getAllNotes()

      logger.debug("Saved note: \(note.id)")
    } catch {
      logger.error("Save failed: \(error.localizedDescription)")
    }
  }

  private func deleteNote(_ note: Note) {
    do {
      try NoteManager.shared.deleteNote(withId: note.id)
      notes = NoteManager.shared.getAllNotes()
      selectedNote = notes.first
    } catch {
      logger.error("Failed to delete note: \(error.localizedDescription)")
    }
  }

  private var scannerBarOverlay: some View {
    GeometryReader { geo in
      let yOffset = calculateScannerYOffset()

      // Final position calculation (where recording controls are)
      let finalYOffset = geo.size.height - 60

      // Interpolate between scanner position and final position
      let currentYOffset =
        isMorphingToControls ? mix(yOffset, finalYOffset, progress: morphProgress) : yOffset

      // Interpolate width from full width to controls width
      let startWidth = geo.size.width - 16
      let endWidth: CGFloat = 120
      let currentWidth =
        isMorphingToControls ? mix(startWidth, endWidth, progress: morphProgress) : startWidth

      // Interpolate height
      let startHeight = max(currentLineHeight + 2, 30)
      let endHeight: CGFloat = 38
      let currentHeight =
        isMorphingToControls ? mix(startHeight, endHeight, progress: morphProgress) : startHeight

      ZStack(alignment: .topLeading) {
        // Main scanner/morphing bar
        HStack(spacing: 12) {
          if !isMorphingToControls {
            ProgressToCheckmark(
              progress: progressValue,
              showCheckmark: showCheckmark
            )
            .frame(width: 20, height: 20)
            .padding(.leading, 16)

            Spacer()

            Text(isDone ? "Done! ✨" : "✨ Improving notes")
              .foregroundColor(.white)
              .font(.system(size: 14, weight: .semibold))
              .padding(.trailing, 16)
          }
        }
        .opacity(isMorphingToControls ? Double(1 - min(1, morphProgress * 2.5)) : 1)
        .frame(
          width: currentWidth,
          height: currentHeight
        )
        .background(
          ZStack {
            // Orange gradient fading out
            RoundedRectangle(cornerRadius: 29, style: .continuous)
              .fill(
                LinearGradient(
                  gradient: Gradient(colors: [
                    Color.orange.opacity(0.6),
                    Color.orange.opacity(0.85),
                  ]),
                  startPoint: .leading,
                  endPoint: .trailing
                )
              )
              .opacity(1 - morphProgress)

            // Gray background fading in
            RoundedRectangle(cornerRadius: 29, style: .continuous)
              .fill(Color.gray.opacity(0.6))
              .opacity(morphProgress)
          }
        )
        .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 3)
        .offset(
          x: isMorphingToControls
            ? mix(8, (geo.size.width - currentWidth) / 2, progress: morphProgress) : 8,
          y: currentYOffset)

        // Fade in recording controls
        if isMorphingToControls {
          HStack(spacing: 12) {
            Button(action: {}) {
              Image(systemName: "circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
            .padding(.trailing, 7)

            Button(action: {}) {
              Image(systemName: "square.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 7)
          }
          .opacity(Double(morphProgress))
          .offset(
            x: mix(8, (geo.size.width - endWidth) / 2 + 10, progress: morphProgress),
            y: currentYOffset + (currentHeight - endHeight) / 2
          )
        }
      }
      .animation(.easeInOut(duration: 0.3), value: scanningIndex)
      .animation(.easeInOut(duration: 0.3), value: currentLineHeight)
      .animation(.easeInOut(duration: 0.6), value: morphProgress)
    }
  }

  // Helper function to interpolate between values
  private func mix(_ from: CGFloat, _ to: CGFloat, progress: CGFloat) -> CGFloat {
    from * (1 - progress) + to * progress
  }

  private func calculateScannerYOffset() -> CGFloat {
    var offset: CGFloat = -1

    for idx in 0..<scanningIndex {
      offset += textHeights[idx] ?? 0
      offset += verticalPadding * 2
    }

    return offset
  }

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

  private func startRecording() async {
    guard let targetNote = selectedNote else {
      logger.error("No note selected for recording")
      return
    }

    let lines = typedNotes.components(separatedBy: .newlines)
    let currentTitle = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    var updatedTargetNote = targetNote
    updatedTargetNote.title = currentTitle
    recordingTargetNote = updatedTargetNote

    logger.debug("Recording target note ID: \(recordingTargetNote?.id ?? "nil")")

    do {
      guard await checkRecordingPermissions() else {
        logger.error("Recording permissions denied")
        return
      }

      DispatchQueue.main.async {
        self.noteManager.updateNoteStates(recordingId: targetNote.id)
      }

      if let processSource = audioManager.selections.selectedProcess {
        if processSource.id == "system-audio" {
          // Handle system-wide audio recording
          logger.info("Creating transcriber for all system audio")
          let systemProcess = AudioProcess.systemWideAudio()
          let newTranscriber = ProcessTapRecorder(process: systemProcess) { chunkData in
            sendChunkToTranscribeEndpoint(chunkData)
          }

          try newTranscriber.start()
          self.transcriber = newTranscriber
        } else {
          // Handle specific process recording
          logger.info("Creating transcriber for process: \(processSource.name)")
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
        // Default browser case
        let process = try browserFinder.findDefaultBrowserProcess()
        let newTranscriber = ProcessTapRecorder(process: process) { chunkData in
          sendChunkToTranscribeEndpoint(chunkData)
        }
        try newTranscriber.start()
        self.transcriber = newTranscriber
      }

      // Configure selected input device if any
      if let inputSource = audioManager.selections.selectedInput {
        let err = setDefaultInputDevice(inputSource.objectID)
        if err != noErr {
          logger.error("Failed to set input device: \(err)")
        }
      }

      // Start microphone recording
      try micRecorder.start { chunkData in
        sendChunkToTranscribeEndpoint(chunkData)
      }

      self.isRecording = true
      logger.info("Recording started for note: \(recordingTargetNote?.id ?? "none")")
    } catch {
      logger.error("Failed to start recording: \(error.localizedDescription)")
      DispatchQueue.main.async {
        self.noteManager.clearStates()
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

  private func stopRecording() {
    // Save pre-enhancement version before stopping recording
    if let targetNote = recordingTargetNote {
      do {
        try fileManager.saveVersionedCopy(forId: targetNote.id, title: targetNote.title)
      } catch {
        logger.error("Failed to save pre-enhancement version: \(error.localizedDescription)")
      }
    }
    transcriber?.stop()
    transcriber = nil

    micRecorder.stop()
    isRecording = false
    logger.info("Recording stopped")

    DispatchQueue.main.async {
      self.noteManager.clearStates()
    }

    if let targetNote = recordingTargetNote {
      streamEnhanceNotes(forNote: targetNote)
    }
  }

  private func sendChunkToTranscribeEndpoint(_ chunk: Data) {
    guard let baseURL = CloudflareService.shared.getWorkerURL(),
      let url = URL(string: "transcribe", relativeTo: baseURL)
    else {
      logger.error("Cloudflare Worker URL not configured")
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue("\(chunk.count)", forHTTPHeaderField: "Content-Length")
    request.httpBody = chunk

    CloudflareService.shared.prepareRequest(&request)

    URLSession.shared.dataTask(with: request) { [self] data, response, error in
      if let error = error {
        self.logger.error("Transcription network error: \(error.localizedDescription)")
        return
      }

      guard let data = data else {
        self.logger.error("Transcription received no data")
        return
      }

      do {
        // Try parsing as JSON
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
          if let text = json["text"] as? String {
            DispatchQueue.main.async {
              self.transcript += text + " "
              self.logger.debug("Updated transcript: \(self.transcript)")
            }
          } else {
            self.logger.error("Transcription response missing 'text' field")
          }
        } else {
          self.logger.error("Transcription response not in expected format")
        }
      } catch {
        // Try parsing as plain text if JSON fails
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
          in: .whitespacesAndNewlines),
          !text.isEmpty
        {
          DispatchQueue.main.async {
            self.transcript += text + " "
            self.logger.debug("Updated transcript (plain text): \(self.transcript)")
          }
        } else {
          self.logger.error("Transcription parse error: \(error.localizedDescription)")
        }
      }
    }.resume()
  }

  private func streamEnhanceNotes(forNote note: Note) {
    do {
      DispatchQueue.main.async {
        self.noteManager.updateEnhancingState(noteId: note.id)
      }
      notes = notes.map { n in
        var noteCopy = n
        noteCopy.isRecording = false
        noteCopy.isEnhancing = n.id == note.id
        return noteCopy
      }

      let (_, content) = try NoteManager.shared.getNote(withId: note.id)
      guard let baseURL = CloudflareService.shared.getWorkerURL(),
        let url = URL(string: "enhance", relativeTo: baseURL)
      else {
        logger.error("Cloudflare Worker URL not configured")
        return
      }

      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

      let payload: [String: Any] = [
        "notes": content,
        "transcript": transcript,
      ]
      request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")

      CloudflareService.shared.prepareRequest(&request)

      // Reset state regardless of which note we're viewing
      self.enhancedLines = []
      self.currentLineBuffer = ""

      // Only show UI if we're looking at the target note
      if selectedNote?.id == note.id {
        DispatchQueue.main.async {
          self.originalLines = content.components(separatedBy: "\n")
          self.scanningIndex = 0
          self.isDone = false
          self.isEnhancing = true
        }
      }

      let task = URLSession.shared.dataTask(with: request) { _, _, _ in }
      parseSSEStream(task: task)
      task.resume()
    } catch {
      logger.error("Failed to enhance note: \(error.localizedDescription)")
    }
  }

  private func parseSSEStream(task: URLSessionDataTask) {
    let sessionConfig = URLSessionConfiguration.default
    let session = URLSession(
      configuration: sessionConfig,
      delegate: SSEStreamDelegate(contentView: self),
      delegateQueue: nil)

    task.cancel()

    if let req = task.originalRequest {
      let newTask = session.dataTask(with: req)
      newTask.resume()
    }
  }

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

  func finishEnhancement() {
    DispatchQueue.main.async {
      self.noteManager.clearStates()

      if !self.currentLineBuffer.isEmpty {
        self.enhancedLines.append(self.currentLineBuffer)
        self.currentLineBuffer = ""
      }

      // Animate progress to completion first
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

            // Reset other states without animation
            self.showCheckmark = false
            self.isMorphingToControls = false
            self.morphProgress = 0
            self.textViewRef.textView?.forceStyleText()
          }
        }

      }

      let enhancedContent = self.enhancedLines.joined(separator: "\n")

      do {
        guard let targetNote = self.recordingTargetNote else {
          self.logger.error("recordingTargetNote is nil, cannot update.")
          return
        }

        try NoteManager.shared.updateNote(targetNote, withContent: enhancedContent)

        if self.selectedNote?.id == targetNote.id {
          self.typedNotes = enhancedContent

          // Return to normal view after showing completion
          DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.5)) {
              self.isEnhancing = false
              self.showCheckmark = false
            }
            self.textViewRef.textView?.forceStyleText()
          }
        }
      } catch {
        self.logger.error("Failed to save enhanced note: \(error.localizedDescription)")
      }

      // Clean up state
      self.recordingTargetNote = nil
      self.transcript = ""
    }
  }
}

struct ProgressToCheckmark: View {
  let progress: CGFloat
  let showCheckmark: Bool

  @State private var trimEnd: CGFloat = 0

  var body: some View {
    ZStack {
      if !showCheckmark {
        Circle()
          .stroke(
            Color.white.opacity(0.3),
            lineWidth: 2
          )

        Circle()
          .trim(from: 0, to: progress)
          .stroke(
            Color.white,
            style: StrokeStyle(
              lineWidth: 2,
              lineCap: .round
            )
          )
          .rotationEffect(.degrees(-90))
      } else {
        CheckmarkShape()
          .trim(from: 0, to: trimEnd)
          .stroke(
            Color.white,
            style: StrokeStyle(
              lineWidth: 2,
              lineCap: .round,
              lineJoin: .round
            )
          )
          .frame(width: 12, height: 12)
          .onAppear {
            withAnimation(.easeOut(duration: 0.3).delay(0.1)) {
              trimEnd = 1
            }
          }
      }
    }
  }
}

struct CheckmarkShape: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()

    // Calculate checkmark points
    let midX = rect.midX
    let midY = rect.midY

    // Start point of the checkmark (left)
    path.move(to: CGPoint(x: midX - 4, y: midY))

    // Bottom point of the checkmark
    path.addLine(to: CGPoint(x: midX - 1, y: midY + 3))

    // End point of the checkmark (right)
    path.addLine(to: CGPoint(x: midX + 4, y: midY - 3))

    return path
  }
}

class SSEStreamDelegate: NSObject, URLSessionDataDelegate {
  var contentView: ContentView
  private var partialBuffer = Data()

  init(contentView: ContentView) {
    self.contentView = contentView
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    partialBuffer.append(data)

    while let newlineRange = partialBuffer.range(of: Data([0x0A])) {
      let lineData = partialBuffer.subdata(in: 0..<newlineRange.lowerBound)
      partialBuffer.removeSubrange(0..<(newlineRange.upperBound))

      guard !lineData.isEmpty else { continue }

      if let lineStr = String(data: lineData, encoding: .utf8) {
        // Remove "data: " prefix if present
        let cleaned = lineStr.replacingOccurrences(of: "data: ", with: "")
          .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { continue }

        if cleaned == "[DONE]" {
          contentView.finishEnhancement()
          continue
        }

        do {
          if let jsonData = cleaned.data(using: .utf8),
            let dict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
          {
            if let partialText = dict["response"] as? String {
              contentView.appendEnhancedText(partialText)
            } else {
              contentView.logger.warning("SSE response missing 'response' field: \(cleaned)")
            }
          } else {
            // If not JSON, try using the cleaned text directly
            if !cleaned.starts(with: "{") && !cleaned.starts(with: "[") {
              contentView.appendEnhancedText(cleaned)
            } else {
              contentView.logger.warning("SSE response not in expected format: \(cleaned)")
            }
          }
        } catch {
          contentView.logger.warning(
            "SSE parse error: \(error.localizedDescription), raw line: \(cleaned)")
        }
      }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error = error {
      contentView.logger.error("SSE completed with error: \(error.localizedDescription)")
    } else {
      contentView.logger.info("SSE completed successfully")
    }
    contentView.finishEnhancement()
  }
}

// Helper view to measure text height
struct TextMeasurementView: View {
  let text: String
  let fontSize: CGFloat
  let maxWidth: CGFloat
  let onHeightChange: (CGFloat) -> Void

  var body: some View {
    Text(text)
      .font(.system(size: fontSize, weight: .regular, design: .rounded))
      .frame(maxWidth: maxWidth, alignment: .leading)
      .background(
        GeometryReader { geometry in
          Color.clear.onAppear {
            onHeightChange(geometry.size.height)
          }
        }
      )
  }
}

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
      assertionFailure("Failed to get System Settings app URL")
      return
    }

    openApplication(at: url, configuration: .init())
  }
}
