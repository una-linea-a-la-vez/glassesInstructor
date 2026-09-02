import Foundation

/// Analiza una URL en cascada, emitiendo un resultado parcial en cuanto cada capa
/// termina. El HUD nunca espera al análisis completo: pinta el dominio a los 0 ms,
/// el semáforo de seguridad en cuanto vuelven los headers, y así.
///
/// Las capas 1 y 2 comparten **una sola** petición de red: los headers y el HTML
/// llegan en la misma respuesta, así que separarlas no cuesta un round-trip extra.
actor LinkAnalyzer {
    static let shared = LinkAnalyzer()

    /// Headers que el dueño del sitio controla. HSTS queda fuera del score porque
    /// Vercel/Netlify lo inyectan solos: premiarlo infla la nota sin mérito.
    private static let ownerControlledHeaders = [
        "content-security-policy",
        "x-frame-options",
        "x-content-type-options",
        "referrer-policy",
        "permissions-policy"
    ]

    private var cache: [URL: LinkAnalysis] = [:]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Precalienta URLs conocidas (los QR de una demo) para que el escaneo
    /// devuelva desde memoria en vez de pagar la red.
    func warm(_ urls: [URL]) async {
        for url in urls where cache[url] == nil {
            for await _ in analyze(url) { }
        }
    }

    func cached(_ url: URL) -> LinkAnalysis? { cache[url] }

    private func store(_ analysis: LinkAnalysis) {
        cache[analysis.url] = analysis
    }

    /// Emite el análisis capa por capa. El consumidor pinta cada valor que llega.
    nonisolated func analyze(_ url: URL) -> AsyncStream<LinkAnalysis> {
        AsyncStream { continuation in
            Task {
                // Caché: si ya lo analizamos, sale completo sin tocar la red.
                if let hit = await self.cached(url) {
                    continuation.yield(hit)
                    continuation.finish()
                    return
                }

                var analysis = LinkAnalysis(url: url)

                // ── Capa 0 · 0 ms. La URL viene del propio QR, no hay red.
                continuation.yield(analysis)

                // ── Capa 1 · una petición: headers + cuerpo
                let started = Date()
                guard let (data, response) = try? await Self.fetch(url),
                      let http = response as? HTTPURLResponse else {
                    continuation.finish()
                    return
                }
                analysis.ttfbMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
                analysis.httpStatus = http.statusCode
                Self.applySecurityLayer(&analysis, http: http)
                analysis.layer = .security
                continuation.yield(analysis)

                // ── Capa 2 · sobre el HTML que ya tenemos en memoria
                let html = String(data: data, encoding: .utf8) ?? ""
                analysis.transferredBytes = data.count
                Self.applyIdentityLayer(&analysis, html: html)
                analysis.layer = .identity
                continuation.yield(analysis)

                // ── Capa 3 · artesanía. Lo único que vuelve a tocar la red.
                await Self.applyCraftLayer(&analysis, html: html)
                analysis.layer = .craft
                continuation.yield(analysis)

                await self.store(analysis)
                continuation.finish()
            }
        }
    }

    private static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue("br, gzip", forHTTPHeaderField: "Accept-Encoding")
        return try await session.data(for: request)
    }

    // MARK: - Capa 1 · Seguridad

    private static func applySecurityLayer(_ analysis: inout LinkAnalysis, http: HTTPURLResponse) {
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key.lowercased()] = value
            }
        }

        for header in ownerControlledHeaders {
            if headers[header] != nil {
                analysis.presentSecurityHeaders.append(header)
            } else {
                analysis.missingSecurityHeaders.append(header)
            }
        }

        analysis.server = headers["server"]
        analysis.framework = detectFramework(headers: headers)
    }

    private static func detectFramework(headers: [String: String]) -> String? {
        if headers.keys.contains(where: { $0.hasPrefix("x-nextjs") }) {
            let isRSC = headers["vary"]?.contains("rsc") == true
            return "Next.js (\(isRSC ? "App Router / RSC" : "Pages Router"))"
        }
        if headers["x-powered-by"]?.lowercased().contains("express") == true { return "Express" }
        if let generator = headers["x-generator"] { return generator }
        return headers["server"]
    }

    // MARK: - Capa 2 · Identidad

    private static func applyIdentityLayer(_ analysis: inout LinkAnalysis, html: String) {
        analysis.title = firstMatch(in: html, pattern: "<title[^>]*>([^<]+)</title>")

        // Muchos proyectos enlazan su repositorio en el pie. Encontrarlo aqui abre
        // la puerta a mirar el proceso, no solo el resultado desplegado.
        if let repo = firstMatch(in: html, pattern: "https://github\\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)") {
            analysis.repositoryURL = URL(string: "https://github.com/\(repo)")
        }
        analysis.metaDescription = firstMatch(
            in: html, pattern: "name=\"description\"[^>]*content=\"([^\"]+)\""
        )
        analysis.language = firstMatch(in: html, pattern: "<html[^>]*lang=\"([a-zA-Z-]+)\"")
        analysis.hasOpenGraph = html.contains("property=\"og:")

        analysis.headingCount = count(of: "<h2", in: html) + count(of: "<h3", in: html)
        analysis.landmarkCount = ["<main", "<nav", "<section", "<footer", "<header"]
            .reduce(0) { $0 + count(of: $1, in: html) }
        analysis.interactiveCount = count(of: "<button", in: html) + count(of: "<form", in: html)
        analysis.ariaLabelCount = count(of: "aria-label", in: html)
    }

    // MARK: - Capa 3 · Artesanía

    private static func applyCraftLayer(_ analysis: inout LinkAnalysis, html: String) async {
        var signals: [AnalysisSignal] = []

        // Idioma declarado: sin esto los lectores de pantalla usan fonética equivocada.
        if let lang = analysis.language {
            signals.append(AnalysisSignal(title: "Idioma declarado",
                                          detail: "<html lang=\"\(lang)\">", weight: 5))
        } else {
            signals.append(AnalysisSignal(title: "Sin atributo lang",
                                          detail: "Los lectores de pantalla no saben en qué idioma leer",
                                          weight: -8))
        }

        // Open Graph: sin esto el link compartido sale sin preview.
        if analysis.hasOpenGraph {
            signals.append(AnalysisSignal(title: "Open Graph presente",
                                          detail: "El link genera preview al compartirse", weight: 6))
        } else {
            signals.append(AnalysisSignal(title: "Sin Open Graph",
                                          detail: "Compartir el link no genera preview en redes ni WhatsApp",
                                          weight: -8))
        }

        if analysis.ariaLabelCount > 0 {
            signals.append(AnalysisSignal(title: "Etiquetas ARIA",
                                          detail: "\(analysis.ariaLabelCount) aria-label en el documento",
                                          weight: 8))
        } else if analysis.interactiveCount > 0 {
            signals.append(AnalysisSignal(title: "Interacción sin ARIA",
                                          detail: "Hay controles pero ningún aria-label", weight: -12))
        }

        if analysis.headingCount == 0 {
            signals.append(AnalysisSignal(
                title: "Sin jerarquía de encabezados",
                detail: "No hay <h2>/<h3>: la estructura no es navegable por lector de pantalla",
                weight: -5))
        }

        // console.log en el HTML servido: delator clásico de código sin pulir.
        let logs = count(of: "console.log", in: html)
        if logs > 0 {
            signals.append(AnalysisSignal(title: "console.log en producción",
                                          detail: "\(logs) ocurrencia(s) en el HTML servido", weight: -10))
        }

        // Tipografía fluida y design tokens: decisiones que el código generado sin
        // criterio no suele tomar (se queda en text-3xl y ya).
        if html.contains("clamp(") {
            signals.append(AnalysisSignal(title: "Tipografía fluida",
                                          detail: "Usa clamp() para escalar texto con el viewport",
                                          weight: 8))
        }
        if html.contains("text-balance") || html.contains("text-pretty") {
            signals.append(AnalysisSignal(title: "Balanceo tipográfico",
                                          detail: "text-balance/pretty: control fino de saltos de línea",
                                          weight: 6))
        }

        // dangerouslySetInnerHTML: casi siempre es el error boundary de Next.js,
        // así que se marca como riesgo de falso positivo y no penaliza por sí solo.
        if html.contains("dangerouslySetInnerHTML") {
            let isNextErrorBoundary = html.contains("next-error-h1")
            signals.append(AnalysisSignal(
                title: "dangerouslySetInnerHTML",
                detail: isNextErrorBoundary
                    ? "Proviene del error boundary de Next.js, no de código propio"
                    : "Inyección de HTML sin sanitizar aparente: revisar el origen del dato",
                weight: isNextErrorBoundary ? 0 : -15,
                isFalsePositiveRisk: isNextErrorBoundary))
        }

        // Source maps expuestos: publican el código fuente original.
        if let mapURL = firstScriptMapURL(in: html, base: analysis.url) {
            let exposed = await probeIsPublic(mapURL)
            analysis.sourceMapsExposed = exposed
            signals.append(exposed
                ? AnalysisSignal(title: "Source maps expuestos",
                                 detail: "\(mapURL.lastPathComponent) responde 200: el código original es público",
                                 weight: -20)
                : AnalysisSignal(title: "Source maps protegidos",
                                 detail: "Los .map no son accesibles públicamente", weight: 10))
        }

        // prefers-reduced-motion: señal fuerte de accesibilidad deliberada.
        if let cssURL = firstStylesheetURL(in: html, base: analysis.url),
           let css = try? await fetchText(cssURL) {
            let respects = css.contains("prefers-reduced-motion")
            analysis.respectsReducedMotion = respects
            signals.append(respects
                ? AnalysisSignal(title: "Respeta prefers-reduced-motion",
                                 detail: "Desactiva animaciones para quien lo pide por accesibilidad",
                                 weight: 12)
                : AnalysisSignal(title: "Ignora prefers-reduced-motion",
                                 detail: "Las animaciones corren aunque el usuario pida reducirlas",
                                 weight: -6))
        }

        analysis.signals = signals
    }

    private static func probeIsPublic(_ url: URL) async -> Bool {
        guard let (_, response) = try? await fetch(url),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    private static func fetchText(_ url: URL) async throws -> String {
        let (data, _) = try await fetch(url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Utilidades de parsing

    private static func firstScriptMapURL(in html: String, base: URL) -> URL? {
        guard let path = firstMatch(in: html, pattern: "src=\"(/[^\"]+\\.js)\"") else { return nil }
        return URL(string: path + ".map", relativeTo: base)?.absoluteURL
    }

    private static func firstStylesheetURL(in html: String, base: URL) -> URL? {
        guard let path = firstMatch(in: html, pattern: "href=\"(/[^\"]+\\.css)\"") else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func count(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }
}
