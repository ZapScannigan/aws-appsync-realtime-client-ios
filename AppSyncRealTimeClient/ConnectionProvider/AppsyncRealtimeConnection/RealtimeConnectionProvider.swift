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
public class RealtimeConnectionProviderBase: ConnectionProvider {
    /// Maximum number of seconds a connection may go without receiving a keep alive
    /// message before we consider it stale and force a disconnect
    static let staleConnectionTimeout: TimeInterval = 5 * 60

    let url: URL
    var listeners: [String: ConnectionProviderCallback]

    let websocket: AppSyncWebsocketProvider

    var status: ConnectionState

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
        // swiftlint:disable:next force_cast
        return iLimitExceededSubject as! PassthroughSubject<ConnectionProviderError, Never>
    }

    // Prevent this class from being instantiated directly.
    // Use RealtimeConnectionProvider or RealtimeConnectionProviderAsync instead
    fileprivate init(
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

    // The following two methods are overridden in
    // RealtimeConnectionProvider and RealtimeConnectionProviderAsync below.
    public func connect() {}
    public func write(_ message: AppSyncMessage) {}

    func sendConnectionInitMessage() {
        let message = AppSyncMessage(type: .connectionInit("connection_init"))
        write(message)
    }

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
                AppSyncLogger.debug(
                    "[RealtimeConnectionProvider] all subscriptions removed, disconnecting websocket connection."
                )
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

// MARK: - RealtimeConnectionProvider

public class RealtimeConnectionProvider: RealtimeConnectionProviderBase {

    var messageInterceptors = [MessageInterceptor]()
    var connectionInterceptors = [ConnectionInterceptor]()

    override internal init(
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
        super.init(
            url: url,
            websocket: websocket,
            connectionQueue: connectionQueue,
            serialCallbackQueue: serialCallbackQueue,
            connectivityMonitor: connectivityMonitor
        )
    }

    public convenience init(for url: URL, websocket: AppSyncWebsocketProvider) {
        self.init(url: url, websocket: websocket)
    }

    override public func connect() {
        connectionQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            guard self.status == .notConnected else {
                self.updateCallback(event: .connection(self.status))
                return
            }
            self.status = .inProgress
            self.updateCallback(event: .connection(self.status))
            let request = AppSyncConnectionRequest(url: self.url)
            let signedRequest = self.interceptConnection(request, for: self.url)
            DispatchQueue.global().async {
                self.websocket.connect(
                    url: signedRequest.url,
                    protocols: ["graphql-ws"],
                    delegate: self
                )
            }
        }
    }

    override public func write(_ message: AppSyncMessage) {
        connectionQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            let signedMessage = self.interceptMessage(message, for: self.url)
            self.finishWrite(signedMessage)
        }
    }
}

// MARK: - RealtimeConnectionProviderAsync

@available(iOS 13.0, *)
public class RealtimeConnectionProviderAsync: RealtimeConnectionProviderBase {

    var messageInterceptors = [MessageInterceptorAsync]()
    var connectionInterceptors = [ConnectionInterceptorAsync]()

    override internal init(
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
        super.init(
            url: url,
            websocket: websocket,
            connectionQueue: connectionQueue,
            serialCallbackQueue: serialCallbackQueue,
            connectivityMonitor: connectivityMonitor
        )
    }

    public convenience init(for url: URL, websocket: AppSyncWebsocketProvider) {
        self.init(url: url, websocket: websocket)
    }

    override public func connect() {
        connectionQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            guard self.status == .notConnected else {
                self.updateCallback(event: .connection(self.status))
                return
            }
            self.status = .inProgress
            self.updateCallback(event: .connection(self.status))
            let request = AppSyncConnectionRequest(url: self.url)

            Task {
                let signedRequest = await self.interceptConnection(request, for: self.url)
                self.websocket.connect(
                    url: signedRequest.url,
                    protocols: ["graphql-ws"],
                    delegate: self
                )
            }
        }
    }

    override public func write(_ message: AppSyncMessage) {
        connectionQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            Task {
                let signedMessage = await self.interceptMessage(message, for: self.url)
                self.finishWrite(signedMessage)
            }
        }
    }
}
