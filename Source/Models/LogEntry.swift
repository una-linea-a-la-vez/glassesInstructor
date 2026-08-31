import Foundation
import SwiftUI

/// Niveles de severidad para logs de diagnóstico
enum LogLevel: String, CaseIterable, Identifiable {
    case info = "INFO"
    case success = "SUCCESS"
    case warning = "WARN"
    case error = "ERROR"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// Estructura de un evento registrado en la consola de depuración
struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let tag: String
    let message: String
    
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
    
    var fullFormattedString: String {
        "[\(formattedTime)] [\(level.rawValue)] [\(tag)] \(message)"
    }
}
