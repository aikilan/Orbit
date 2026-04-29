import AppKit
import SwiftUI

@MainActor
struct ProviderBridgeDebugView: View {
    @ObservedObject var store: ProviderBridgeDebugStore
    @State private var selectedRequestID: UUID?

    private var selectedRequest: ProviderBridgeDebugRequest? {
        guard let selectedRequestID else { return store.requests.last }
        return store.requests.first { $0.id == selectedRequestID }
    }

    private var visibleEvents: [ProviderBridgeDebugEvent] {
        guard let requestID = selectedRequest?.id else { return store.events }
        return store.events.filter { $0.requestID == requestID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                requestList
                    .frame(width: 320)
                Divider()
                eventTimeline
            }
        }
        .background(OrbitPalette.background)
        .tint(OrbitPalette.accent)
        .onAppear {
            selectedRequestID = store.requests.last?.id
        }
        .onChange(of: store.requests) { _, requests in
            guard !requests.contains(where: { $0.id == selectedRequestID }) else { return }
            selectedRequestID = requests.last?.id
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.tr("Bridge 调试"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.tr("复制事件")) {
                    copyToPasteboard(eventsText(visibleEvents))
                }
                .disabled(visibleEvents.isEmpty)
                Button(L10n.tr("清空"), role: .destructive) {
                    store.clear()
                    selectedRequestID = nil
                }
            }

            HStack(alignment: .top, spacing: 12) {
                summaryItem(L10n.tr("Bridge"), value: store.latestBridgeBaseURL ?? L10n.tr("无"))
                summaryItem(L10n.tr("上游"), value: store.latestUpstreamBaseURL ?? L10n.tr("无"))
                summaryItem(L10n.tr("活跃请求"), value: "\(store.activeRequestCount)")
            }
        }
        .padding(18)
    }

    private var requestList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("请求"))
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 14)

            if store.requests.isEmpty {
                ContentUnavailableView(
                    L10n.tr("暂无 Bridge 请求"),
                    systemImage: "network.slash",
                    description: Text(L10n.tr("发起 OpenAI-compatible Provider bridge 调用后会出现在这里。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.requests.reversed()) { request in
                            Button {
                                selectedRequestID = request.id
                            } label: {
                                requestRow(request)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
                }
            }
        }
        .background(OrbitPalette.sidebar)
    }

    private var eventTimeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.tr("事件"))
                    .font(.headline)
                Spacer()
                if let selectedRequest {
                    Text(selectedRequest.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            if let selectedRequest {
                requestDetail(selectedRequest)
                    .padding(.horizontal, 18)
            }

            if visibleEvents.isEmpty {
                ContentUnavailableView(
                    L10n.tr("暂无 Bridge 事件"),
                    systemImage: "list.bullet.rectangle",
                    description: Text(L10n.tr("Provider bridge 请求改写和上游调用过程会实时追加到时间线。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleEvents.reversed()) { event in
                            eventRow(event)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func requestRow(_ request: ProviderBridgeDebugRequest) -> some View {
        let isSelected = selectedRequest?.id == request.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(request.path)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                statusBadge(request.status)
            }

            Text(request.startedAt.formatted(date: .omitted, time: .standard))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(request.model)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let multimodalModel = request.multimodalModel {
                Text(L10n.tr("多模态：%@", multimodalModel))
                    .font(.caption)
                    .foregroundStyle(request.hasMedia ? OrbitPalette.accent : .secondary)
                    .lineLimit(1)
            }

            if let errorMessage = request.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? OrbitPalette.selectionFill : OrbitPalette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? OrbitPalette.accent.opacity(0.28) : OrbitPalette.divider)
        )
    }

    private func requestDetail(_ request: ProviderBridgeDebugRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                detailItem(L10n.tr("状态"), statusText(request.status))
                detailItem(L10n.tr("耗时"), request.durationText)
                detailItem(L10n.tr("HTTP 状态"), request.httpStatus.map(String.init) ?? L10n.tr("无"))
                detailItem(L10n.tr("流式"), request.stream ? L10n.tr("是") : L10n.tr("否"))
            }

            HStack(spacing: 16) {
                detailItem(L10n.tr("媒体附件"), request.hasMedia ? L10n.tr("已检测") : L10n.tr("未检测"))
                detailItem(L10n.tr("关联多模态模型"), request.multimodalModel ?? L10n.tr("无"))
            }

            detailItem(L10n.tr("Bridge"), request.bridgeBaseURL)
            detailItem(L10n.tr("上游"), request.upstreamBaseURL)
        }
        .padding(12)
        .orbitSurface(.neutral, radius: 8)
        .textSelection(.enabled)
    }

    private func eventRow(_ event: ProviderBridgeDebugEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(event.title)
                    .font(.headline)
                Text(event.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let payloadPreview = event.payloadPreview, !payloadPreview.isEmpty {
                ScrollView(.horizontal) {
                    Text(payloadPreview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(OrbitPalette.chromeSubtle, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitSurface(.neutral, radius: 8)
    }

    private func summaryItem(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(OrbitPalette.panel, in: RoundedRectangle(cornerRadius: 8))
    }

    private func detailItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusBadge(_ status: ProviderBridgeDebugRequestStatus) -> some View {
        Text(statusText(status))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(statusColor(status).opacity(0.14), in: Capsule())
            .foregroundStyle(statusColor(status))
    }

    private func statusText(_ status: ProviderBridgeDebugRequestStatus) -> String {
        switch status {
        case .running:
            return L10n.tr("运行中")
        case .completed:
            return L10n.tr("完成")
        case .failed:
            return L10n.tr("失败")
        }
    }

    private func statusColor(_ status: ProviderBridgeDebugRequestStatus) -> Color {
        switch status {
        case .running:
            return OrbitPalette.accent
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private func eventsText(_ events: [ProviderBridgeDebugEvent]) -> String {
        events.map { event in
            var parts = [
                event.timestamp.formatted(date: .numeric, time: .standard),
                event.title,
                event.detail,
            ]
            if let payloadPreview = event.payloadPreview {
                parts.append(payloadPreview)
            }
            return parts.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
