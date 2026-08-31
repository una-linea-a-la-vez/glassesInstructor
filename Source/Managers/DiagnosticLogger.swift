import Foundation
import Combine

/// Gestor de logs en memoria para inspección en tiempo real en la UI del iPhone
@MainActor
class DiagnosticLogger: ObservableObject {
    static let shared = DiagnosticLogger()
    
    @Published var logs: [LogEntry] = []
    @Published var selectedLevelFilter: LogLevel? = nil
    
    private let maxLogCount = 200
    
    private init() {
        log(.info, tag: "System", message: "Motor de diagnóstico inicializado.")
    }
    
    nonisolated func log(_ level: LogLevel, tag: String, message: String) {
        #if DEBUG
        print("[\(level.rawValue)] [\(tag)] \(message)")
        #endif
        Task { @MainActor in
            let entry = LogEntry(timestamp: Date(), level: level, tag: tag, message: message)
            self.logs.insert(entry, at: 0)
            
            if self.logs.count > self.maxLogCount {
                self.logs.removeLast()
            }
        }
    }
    
    func clearLogs() {
        logs.removeAll()
        log(.info, tag: "System", message: "Consola de logs reiniciada.")
    }
    
    var filteredLogs: [LogEntry] {
        if let filter = selectedLevelFilter {
            return logs.filter { $0.level == filter }
        }
        return logs
    }
    
    var fullExportText: String {
        logs.reversed().map { $0.fullFormattedString }.joined(separator: "\n")
    }
}
