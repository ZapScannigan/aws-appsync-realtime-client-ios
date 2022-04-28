//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Combine

/// Appsync Real time connection that connects to subscriptions
/// through websocket.
public class RealtimeConnectionProviderBase {
    /// Maximum number of seconds a connection may go without receiving a keep alive
    /// message before we consider it stale and force a disconnect
    static let staleConnectionTimeout: TimeInterval = 5 * 60

    let url: URL
    var listeners: [String: ConnectionProviderCallback]

    let websocket: AppSyncWebsocketProvider

    var status: ConnectionState

    // These are type Any because they can be either Sync or Async and the async versions require iOS 13 support.
    var messageInterceptors: [Any]
    var connectionInterceptors: [Any]
    var useAsyncInterceptors = false

    /// A timer that automatically disconnects the current connection if it goes longer
    /// than `staleConnectionTimeout` without activity. Receiving any data or "keep
    /// alive" message will cause the timer to be reset to the full interval.
    var staleConnectionTimer: CountdownTimer

    /// Intermediate state when the connection is connected and connectivity updates to unsatisfied (offline)
    var isStaleConnection: Bool

    /// Manages concurrency for socket connections, disconnections, writes, and status reports.
    ///
    /// Each connection request will be sent to this queue. Connection request are
    /// handled one at a time.
    let connectionQueue: DispatchQueue

    /// Monitor for connectivity updates
    let connectivityMonitor: ConnectivityMonitor

    /// The serial queue on which status & message callbacks from the web socket are invoked.
    private let serialCallbackQueue: DispatchQueue

    /// Throttle when AppSync sends LimitExceeded error. High rate of subscriptions requests will cause AppSync to send
    /// connection level LimitExceeded errors for each subscribe made. A connection level error means that there is no
    /// subscription id associated with the error. When handling these errors, all subscriptions will receive a message
    /// for the error. Use this subject to send and throttle the errors on the client side.
    var limitExceededThrottleSink: Any?
    var iLimitExceededSubject: Any?
    @available(iOS 13.0, *)
    var limitExceededSubject: PassthroughSubject<ConnectionProviderError, Never> {
        if iLimitExceededSubject == nil {
            iLimitExceededSubject = PassthroughSubject<ConnectionProviderError, Never>()
        }
        return iLimitExceededSubject as! PassthroughSubject<ConnectionProviderError, Never> // swiftlint:disable:this force_cast
    }

    public convenience init(for url: URL, websocket: AppSyncWebsocketProvider) {
        self.init(url: url, websocket: websocket)
    }

    init(
        url: URL,
        websocket: AppSyncWebsocketProvider,
        connectionQueue: DispatchQueue = DispatchQueue(
            label: "com.amazonaws.AppSyncRealTimeConnectionProvider.serialQueue"
        ),
        serialCallbackQueue: DispatchQueue = DispatchQueue(
            label: "com.amazonaws.AppSyncRealTimeConnectionProvider.callbackQueue"
        ),
        connectivityMonitor: ConnectivityMonitor = ConnectivityMonitor()
    ) {
        self.url = url
        self.websocket = websocket
        self.listeners = [:]
        self.status = .notConnected
        self.messageInterceptors = []
        self.connectionInterceptors = []
        self.staleConnectionTimer = CountdownTimer()
        self.isStaleConnection = false
        self.connectionQueue = connectionQueue
        self.serialCallbackQueue = serialCallbackQueue
        self.connectivityMonitor = connectivityMonitor

        connectivityMonitor.start(onUpdates: handleConnectivityUpdates(connectivity:))

        if #available(iOS 13.0, *) {
            subscribeToLimitExceededThrottle()
        }
    }

    // MARK: - ConnectionProvider methods

    func finishWrite(_ signedMessage: AppSyncMessage) {
        let jsonEncoder = JSONEncoder()
        do {
            let jsonData = try jsonEncoder.encode(signedMessage)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                let jsonError = ConnectionProviderError.jsonParse(signedMessage.id, nil)
                updateCallback(event: .error(jsonError))
                return
            }
            websocket.write(message: jsonString)
        } catch {
            AppSyncLogger.error(error)
            switch signedMessage.messageType {
            case .connectionInit:
                receivedConnectionInit()
            default:
                updateCallback(event: .error(ConnectionProviderError.jsonParse(signedMessage.id, error)))
            }
        }
    }

    public func disconnect() {
        connectionQueue.async {
            self.websocket.disconnect()
            self.invalidateStaleConnectionTimer()
        }
    }

    public func addListener(identifier: String, callback: @escaping ConnectionProviderCallback) {
        connectionQueue.async { [weak self] in
            self?.listeners[identifier] = callback
        }
    }

    public func removeListener(identifier: String) {
        connectionQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            self.listeners.removeValue(forKey: identifier)

            if self.listeners.isEmpty {
                AppSyncLogger.debug("[RealtimeConnectionProvider] all subscriptions removed, disconnecting websocket connection.")
                self.status = .notConnected
                self.websocket.disconnect()
                self.invalidateStaleConnectionTimer()
            }
        }
    }

    // MARK: -

    /// Invokes all registered listeners with `event`. The event is dispatched on `serialCallbackQueue`,
    /// but internally this method uses the connectionQueue to get the currently registered listeners.
    ///
    /// - Parameter event: The connection event to dispatch
    func updateCallback(event: ConnectionProviderEvent) {
        connectionQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            let allListeners = Array(self.listeners.values)
            self.serialCallbackQueue.async {
                allListeners.forEach { $0(event) }
            }
        }
    }

    @available(iOS 13.0, *)
    func subscribeToLimitExceededThrottle() {
        limitExceededThrottleSink = limitExceededSubject
            .filter {
                // Make sure the limitExceeded error is a connection level error (no subscription id present).
                // When id is present, it is passed back directly subscription via `updateCallback`.
                if case .limitExceeded(let id) = $0, id == nil {
                    return true
                }
                return false
            }
            .throttle(for: .milliseconds(150), scheduler: connectionQueue, latest: true)
            .sink { completion in
                switch completion {
                case .failure(let error):
                    AppSyncLogger.verbose("limitExceededThrottleSink failed \(error)")
                case .finished:
                    AppSyncLogger.verbose("limitExceededThrottleSink finished")
                }
        } receiveValue: { result in
            self.updateCallback(event: .error(result))
        }
    }

    /// - Warning: This must be invoked from the `connectionQueue`
    private func receivedConnectionInit() {
        status = .notConnected
        updateCallback(event: .error(ConnectionProviderError.connection))
    }
}