import Foundation

@MainActor
final class PromptExecution {
    private var pending = false
    private var generation = UUID()
    private var insertionTask: Task<Void, Never>?

    func invalidate() {
        insertionTask?.cancel()
        insertionTask = nil
        generation = UUID()
        pending = false
    }

    func activate(ad: AdResponse, handler: PromptActionHandler?, frame: Bool,
                  open: @escaping (URL) -> Bool, completion: @escaping (PromptInsertionResult, Bool) -> Void) {
        guard let action = ad.promptAction, let handler else {
            if let url = FrameSelection.clickURL(ad, action: nil) { _ = open(url) }
            return
        }
        guard !pending else { return }
        pending = true
        let current = generation
        var opened = false
        if action.openUrl != false, let url = FrameSelection.clickURL(ad, action: nil) { opened = open(url) }
        insertionTask = Task { @MainActor [weak self] in
            guard self?.generation == current, !Task.isCancelled else { return }
            let status: PromptInsertionResult
            do { status = try await handler(action) } catch { status = .failed }
            guard let self, self.generation == current, !Task.isCancelled else { return }
            self.insertionTask = nil
            self.pending = false
            if frame && status == .failed && action.openUrl == false && !opened,
               let url = FrameSelection.clickURL(ad, action: nil) { opened = open(url) }
            completion(status, opened)
        }
    }
}
