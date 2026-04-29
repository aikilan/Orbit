import Combine
import Foundation

enum ProviderBridgeDebugRequestStatus: String, Equatable, Sendable {
    case running
    case completed
    case failed
}

struct ProviderBridgeDebugRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date? = nil
    var bridgeBaseURL: String
    var upstreamBaseURL: String
    var path: String
    var model: String
    var stream: Bool
    var hasMedia: Bool
    var multimodalModel: String?
    var status: ProviderBridgeDebugRequestStatus
    var httpStatus: Int? = nil
    var errorMessage: String? = nil

    var durationText: String {
        let end = endedAt ?? Date()
        return String(format: "%.1fs", end.timeIntervalSince(startedAt))
    }
}

struct ProviderBridgeDebugEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let requestID: UUID?
    let timestamp: Date
    let title: String
    let detail: String
    let payloadPreview: String?
}

@MainActor
final class ProviderBridgeDebugStore: ObservableObject, @unchecked Sendable {
    nonisolated static let defaultRequestLimit = 20
    nonisolated static let defaultEventLimit = 1_000
    nonisolated static let payloadPreviewLimit = 64 * 1_024

    @Published private(set) var requests: [ProviderBridgeDebugRequest] = []
    @Published private(set) var events: [ProviderBridgeDebugEvent] = []

    private let requestLimit: Int
    private let eventLimit: Int

    init(
        requestLimit: Int = ProviderBridgeDebugStore.defaultRequestLimit,
        eventLimit: Int = ProviderBridgeDebugStore.defaultEventLimit
    ) {
        self.requestLimit = requestLimit
        self.eventLimit = eventLimit
    }

    var activeRequestCount: Int {
        requests.filter { $0.status == .running }.count
    }

    var latestBridgeBaseURL: String? {
        requests.last?.bridgeBaseURL
    }

    var latestUpstreamBaseURL: String? {
        requests.last?.upstreamBaseURL
    }

    func recordRequestStarted(
        id: UUID,
        bridgeBaseURL: String,
        upstreamBaseURL: String,
        path: String,
        model: String,
        stream: Bool,
        hasMedia: Bool,
        multimodalModel: String?,
        payloadPreview: String?
    ) {
        requests.append(
            ProviderBridgeDebugRequest(
                id: id,
                startedAt: Date(),
                bridgeBaseURL: bridgeBaseURL,
                upstreamBaseURL: upstreamBaseURL,
                path: path,
                model: model,
                stream: stream,
                hasMedia: hasMedia,
                multimodalModel: multimodalModel,
                status: .running
            )
        )
        appendEvent(
            requestID: id,
            title: L10n.tr("Bridge 请求"),
            detail: "\(path) \(model)",
            payloadPreview: payloadPreview
        )
        trimRequests()
    }

    func recordRequestFinished(
        id: UUID,
        status: ProviderBridgeDebugRequestStatus,
        httpStatus: Int?,
        errorMessage: String?
    ) {
        updateRequest(id: id) { request in
            request.status = status
            request.httpStatus = httpStatus
            request.errorMessage = errorMessage
            request.endedAt = Date()
        }
        appendEvent(
            requestID: id,
            title: status == .completed ? L10n.tr("Bridge 完成") : L10n.tr("Bridge 失败"),
            detail: errorMessage ?? (httpStatus.map { "HTTP \($0)" } ?? status.rawValue),
            payloadPreview: nil
        )
    }

    func appendEvent(
        requestID: UUID?,
        title: String,
        detail: String,
        payloadPreview: String?
    ) {
        events.append(
            ProviderBridgeDebugEvent(
                id: UUID(),
                requestID: requestID,
                timestamp: Date(),
                title: title,
                detail: detail,
                payloadPreview: truncated(payloadPreview)
            )
        )
        trimEvents()
    }

    func clear() {
        requests.removeAll()
        events.removeAll()
    }

    private func updateRequest(id: UUID, mutate: (inout ProviderBridgeDebugRequest) -> Void) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        mutate(&requests[index])
    }

    private func trimRequests() {
        if requests.count > requestLimit {
            requests.removeFirst(requests.count - requestLimit)
        }
    }

    private func trimEvents() {
        if events.count > eventLimit {
            events.removeFirst(events.count - eventLimit)
        }
    }

    private func truncated(_ value: String?) -> String? {
        guard let value else { return nil }
        if value.count <= Self.payloadPreviewLimit {
            return value
        }
        return String(value.prefix(Self.payloadPreviewLimit)) + "\n... truncated ..."
    }
}
