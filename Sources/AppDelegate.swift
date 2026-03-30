import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let audioRecorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let keyboardInjector = KeyboardInjector()
    private var hotkeyManager: HotkeyManager!
    private var isRecording = false
    private var isTranscribing = false
    private var isSwitchingModel = false

    // Menu item refs for dynamic updates
    private var hotkeyLabelItem: NSMenuItem!
    private var micStatusItem: NSMenuItem!
    private var axStatusItem: NSMenuItem!
    private var tinyModelItem: NSMenuItem!
    private var baseModelItem: NSMenuItem!
    private var smallModelItem: NSMenuItem!
    private var hotkeyCapture: HotkeyCapture?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        if !transcriber.loadModel() {
            showModelMissingAlert()
            return
        }

        hotkeyManager = HotkeyManager(
            onRecordStart: { [weak self] in self?.startRecording() },
            onRecordStop:  { [weak self] in self?.stopRecording() }
        )
        hotkeyManager.register()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Yell")
        }

        let menu = NSMenu()
        menu.delegate = self

        hotkeyLabelItem = NSMenuItem(title: hotkeyLabel(), action: nil, keyEquivalent: "")
        menu.addItem(hotkeyLabelItem)
        menu.addItem(NSMenuItem(title: "Set Hotkey…", action: #selector(setHotkey), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // Model submenu
        let current = UserDefaults.standard.string(forKey: Transcriber.modelKey) ?? Transcriber.defaultModel
        let modelMenu = NSMenu()

        tinyModelItem = NSMenuItem(title: modelMenuTitle(file: "ggml-tiny.en.bin"), action: #selector(selectModel(_:)), keyEquivalent: "")
        tinyModelItem.representedObject = "ggml-tiny.en.bin"
        tinyModelItem.state = "ggml-tiny.en.bin" == current ? .on : .off
        modelMenu.addItem(tinyModelItem)

        baseModelItem = NSMenuItem(title: modelMenuTitle(file: "ggml-base.en.bin"), action: #selector(selectModel(_:)), keyEquivalent: "")
        baseModelItem.representedObject = "ggml-base.en.bin"
        baseModelItem.state = "ggml-base.en.bin" == current ? .on : .off
        modelMenu.addItem(baseModelItem)

        smallModelItem = NSMenuItem(title: modelMenuTitle(file: "ggml-small.en.bin"), action: #selector(selectModel(_:)), keyEquivalent: "")
        smallModelItem.representedObject = "ggml-small.en.bin"
        smallModelItem.state = "ggml-small.en.bin" == current ? .on : .off
        modelMenu.addItem(smallModelItem)

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        menu.addItem(modelItem)
        menu.setSubmenu(modelMenu, for: modelItem)
        menu.addItem(NSMenuItem.separator())

        // Permission status
        micStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        axStatusItem  = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(micStatusItem)
        menu.addItem(axStatusItem)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        refreshPermissionItems()
        refreshModelMenu()
    }

    private func refreshPermissionItems() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micStatusItem.title  = "Microphone: Granted"
            micStatusItem.action = nil
        case .denied, .restricted:
            micStatusItem.title  = "⚠️ Microphone: Click to Enable"
            micStatusItem.action = #selector(openMicSettings)
        default: // .notDetermined
            micStatusItem.title  = "Microphone: Click to Grant"
            micStatusItem.action = #selector(requestMicPermission)
        }

        let axGranted = AXIsProcessTrusted()
        axStatusItem.title  = axGranted ? "Accessibility: Granted" : "⚠️ Accessibility: Click to Enable"
        axStatusItem.action = axGranted ? nil : #selector(openAxSettings)
    }

    @objc private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.refreshPermissionItems()
            }
        }
    }

    @objc private func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openAxSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - Hotkey

    private func hotkeyLabel() -> String {
        "Hold \(HotkeyManager.displayString()) to dictate"
    }

    @objc private func setHotkey() {
        hotkeyCapture = HotkeyCapture()
        hotkeyCapture?.onCapture = { [weak self] keyCode, mods, char in
            guard let self else { return }
            UserDefaults.standard.set(Int(keyCode),       forKey: HotkeyManager.keyCodeKey)
            UserDefaults.standard.set(Int(mods.rawValue), forKey: HotkeyManager.modifiersKey)
            UserDefaults.standard.set(char,               forKey: HotkeyManager.charKey)
            self.hotkeyLabelItem.title = self.hotkeyLabel()
        }
        hotkeyCapture?.show()
    }

    // MARK: - Model Selection

    private func baseModelLabel(for file: String) -> String {
        switch file {
        case "ggml-tiny.en.bin":
            return "Tiny (faster)"
        case "ggml-base.en.bin":
            return "Base"
        case "ggml-small.en.bin":
            return "Small (~466MB)"
        default:
            return file
        }
    }

    private func userModelDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".yell", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    private func userModelURL(for file: String) -> URL {
        userModelDirectoryURL().appendingPathComponent(file)
    }

    private func downloadedModelPath(for file: String) -> String? {
        guard Bundle.main.path(forResource: file, ofType: nil) == nil else { return nil }
        let path = userModelURL(for: file).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func modelExists(_ file: String) -> Bool {
        Bundle.main.path(forResource: file, ofType: nil) != nil || downloadedModelPath(for: file) != nil
    }

    private var currentModelFile: String {
        UserDefaults.standard.string(forKey: Transcriber.modelKey) ?? Transcriber.defaultModel
    }

    private var modelItems: [NSMenuItem] {
        [tinyModelItem, baseModelItem, smallModelItem].compactMap { $0 }
    }

    private func downloadableModelTitle(file: String, label: String) -> String {
        modelExists(file) ? label : "\(label) — Download"
    }

    private func refreshModelMenu(selectedFile: String? = nil, useCurrentSelection: Bool = true) {
        tinyModelItem.title = modelMenuTitle(file: "ggml-tiny.en.bin")
        baseModelItem.title = modelMenuTitle(file: "ggml-base.en.bin")
        smallModelItem.title = modelMenuTitle(file: "ggml-small.en.bin")

        let file = useCurrentSelection ? (selectedFile ?? currentModelFile) : selectedFile
        modelItems.forEach { item in
            item.state = (file != nil && item.representedObject as? String == file) ? .on : .off
            item.isEnabled = !isSwitchingModel
        }
    }

    private func beginModelOperation(statusTitle: String, on item: NSMenuItem) {
        isSwitchingModel = true
        modelItems.forEach { $0.isEnabled = false }
        item.title = statusTitle
    }

    private func endModelOperation(selectedFile: String? = nil, useCurrentSelection: Bool = true) {
        isSwitchingModel = false
        refreshModelMenu(selectedFile: selectedFile, useCurrentSelection: useCurrentSelection)
    }

    private func modelMenuTitle(file: String) -> String {
        downloadableModelTitle(file: file, label: baseModelLabel(for: file))
    }

    private func installDownloadedModel(from temporaryURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: userModelDirectoryURL(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private func stagedDownloadedModelURL(for file: String) -> URL {
        userModelDirectoryURL().appendingPathComponent("\(file).download")
    }

    private func persistDownloadedModelTemporarily(from temporaryURL: URL, for file: String) throws -> URL {
        let fileManager = FileManager.default
        let stagedURL = stagedDownloadedModelURL(for: file)
        try fileManager.createDirectory(at: userModelDirectoryURL(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: stagedURL.path) {
            try fileManager.removeItem(at: stagedURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: stagedURL)
        return stagedURL
    }

    private func removeDownloadedModelTemporarily(at stagedURL: URL) {
        try? FileManager.default.removeItem(at: stagedURL)
    }

    private func discardInvalidDownloadedModel(file: String) {
        guard let path = downloadedModelPath(for: file) else { return }
        try? FileManager.default.removeItem(atPath: path)
        refreshModelMenu()
    }

    private func showInvalidDownloadedModelAlert(file: String) {
        let alert = NSAlert()
        alert.messageText = "Downloaded Model Is Invalid"
        alert.informativeText = "\(file) could not be loaded and was removed from ~/.yell/models/. Download it again to use it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showModelLoadFailedAlert(file: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't Load \(file)"
        alert.informativeText = "Yell restored the previous model. Try downloading \(file) again if the problem persists."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard !isSwitchingModel else { return }
        guard let file = sender.representedObject as? String else { return }
        let previousFile = currentModelFile
        guard file != previousFile else { return }

        if !modelExists(file) {
            let alert = NSAlert()
            alert.messageText = "Download \(file)?"
            alert.informativeText = "The model will be downloaded and saved to ~/.yell/models/."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            downloadModel(file: file, menuItem: sender, previousFile: previousFile)
            return
        }

        if let path = downloadedModelPath(for: file),
           !Transcriber.canLoadModel(atPath: path) {
            discardInvalidDownloadedModel(file: file)
            showInvalidDownloadedModelAlert(file: file)
            return
        }

        switchModel(to: file, selecting: sender, previousFile: previousFile)
    }

    private func switchModel(to file: String, selecting item: NSMenuItem, previousFile: String, beginOperation: Bool = true) {
        let baseLabel = baseModelLabel(for: file)
        if beginOperation {
            beginModelOperation(statusTitle: "\(baseLabel) — Loading…", on: item)
        }

        UserDefaults.standard.set(file, forKey: Transcriber.modelKey)
        transcriber.reload { [weak self] success in
            guard let self else { return }
            guard success else {
                self.restorePreviousModel(previousFile, afterFailingToLoad: file)
                return
            }
            self.endModelOperation(selectedFile: file)
        }
    }

    private func restorePreviousModel(_ previousFile: String, afterFailingToLoad attemptedFile: String) {
        UserDefaults.standard.set(previousFile, forKey: Transcriber.modelKey)
        transcriber.reload { [weak self] restored in
            guard let self else { return }
            guard restored else {
                self.showModelMissingAlert()
                return
            }
            self.showModelLoadFailedAlert(file: attemptedFile)
            self.endModelOperation(selectedFile: previousFile)
        }
    }

    private func downloadModel(file: String, menuItem: NSMenuItem, previousFile: String) {
        let baseLabel = baseModelLabel(for: file)
        beginModelOperation(statusTitle: "\(baseLabel) — Downloading…", on: menuItem)

        guard let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)") else {
            endModelOperation(selectedFile: previousFile)
            showModelDownloadFailedAlert(file: file, details: "Invalid download URL.")
            return
        }

        URLSession.shared.downloadTask(with: url) { [weak self] tmpURL, response, error in
            guard let self else { return }
            let httpStatus = (response as? HTTPURLResponse)?.statusCode
            guard error == nil, let tmpURL, httpStatus == 200 else {
                DispatchQueue.main.async {
                    self.endModelOperation(selectedFile: previousFile)
                    let details = httpStatus.map { "Server responded with HTTP \($0)." }
                    self.showModelDownloadFailedAlert(file: file, details: details)
                }
                return
            }

            let stagedURL: URL
            do {
                stagedURL = try self.persistDownloadedModelTemporarily(from: tmpURL, for: file)
            } catch {
                DispatchQueue.main.async {
                    self.endModelOperation(selectedFile: previousFile)
                    self.showModelDownloadFailedAlert(file: file, details: error.localizedDescription)
                }
                return
            }

            guard Transcriber.canLoadModel(atPath: stagedURL.path) else {
                self.removeDownloadedModelTemporarily(at: stagedURL)
                DispatchQueue.main.async {
                    self.endModelOperation(selectedFile: previousFile)
                    self.showInvalidDownloadedModelAlert(file: file)
                }
                return
            }

            do {
                try self.installDownloadedModel(from: stagedURL, to: self.userModelURL(for: file))
            } catch {
                self.removeDownloadedModelTemporarily(at: stagedURL)
                DispatchQueue.main.async {
                    self.endModelOperation(selectedFile: previousFile)
                    self.showModelDownloadFailedAlert(file: file, details: error.localizedDescription)
                }
                return
            }

            DispatchQueue.main.async {
                self.switchModel(to: file, selecting: menuItem, previousFile: previousFile, beginOperation: false)
            }
        }.resume()
    }

    // MARK: - Icon

    func updateIcon(recording: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let button = self?.statusItem.button else { return }
            button.image = NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: "Yell")
            button.contentTintColor = recording ? .systemRed : nil
        }
    }

    // MARK: - Recording Flow

    private func startRecording() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.startRecording()
            }
            return
        }
        guard !isRecording, !isTranscribing, !isSwitchingModel else { return }
        isRecording = true
        updateIcon(recording: true)
        audioRecorder.startRecording()
    }

    private func stopRecording() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.stopRecording()
            }
            return
        }
        guard isRecording else { return }
        isRecording = false
        updateIcon(recording: false)

        let samples = audioRecorder.stopRecording()
        guard !samples.isEmpty else { return }

        isTranscribing = true
        transcriber.transcribe(samples: samples) { [weak self] text in
            guard let self else { return }
            self.isTranscribing = false
            guard !text.isEmpty else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                self.keyboardInjector.type(text)
            }
        }
    }

    // MARK: - Alerts

    private func showModelMissingAlert() {
        let alert = NSAlert()
        alert.messageText = "Whisper Model Not Found"
        alert.informativeText = "Run ./download-model.sh to fetch the models."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func showModelSwitchFailedAlert(file: String, restoredPreviousModel: Bool) {
        let alert = NSAlert()
        alert.messageText = "Could not switch to \(file)"
        alert.informativeText = restoredPreviousModel
            ? "Yell kept using the previous model."
            : "Yell could not restore the previous model. Restart the app or re-download the model."
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showModelDownloadFailedAlert(file: String, details: String? = nil) {
        let alert = NSAlert()
        alert.messageText = "Download failed for \(file)"
        alert.informativeText = details ?? "Check your network connection and try again."
        alert.alertStyle = .warning
        alert.runModal()
    }
}
