// CallKit adapters: CXProvider (+ its delegate) and CXCallController behind
// the CallProviding / CallControlling seams. The delegate runs on the main
// queue (`setDelegate(_, queue: nil)`), so the conformance is declared
// `@preconcurrency` (SE-0423): the delegate methods are main-actor isolated
// like the rest of the class and the runtime asserts the hop. The CXAction
// objects are non-Sendable, and this keeps them on the main actor without
// "sending" them into an `assumeIsolated` closure (a Swift 6 error).
//
// AUDIO SESSION RULE (the classic silent-call bug): we CONFIGURE the
// AVAudioSession (category .playAndRecord, mode .voiceChat) in
// providerDidBegin / before answering, and NEVER call setActive(true)
// ourselves on the CallKit path — CallKit activates it and tells us via
// provider(_:didActivate:), which is the ONLY point the voice engine may
// start. Activating it ourselves races CallKit's activation and yields a
// connected call with no audio either way.

import AVFoundation
import CallKit
import Foundation
import UIKit

@MainActor
final class CallKitProvider: NSObject, CallProviding {
    private let provider: CXProvider
    weak var coordinator: CallCoordinator?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.includesCallsInRecents = false
        config.supportedHandleTypes = [.generic]
        // No bundled ringtone asset → the system default rings. Drop a
        // "ring.caf" into App/Resources and set `config.ringtoneSound = "ring.caf"`.
        if Bundle.main.url(forResource: "ring", withExtension: "caf") != nil {
            config.ringtoneSound = "ring.caf"
        }
        if let icon = UIImage(named: "AppIcon")?.pngData() {
            config.iconTemplateImageData = icon
        }
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)   // nil → main queue
    }

    func reportIncoming(uuid: UUID, callerName: String, completion: @escaping @MainActor (Error?) -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Unstuck")
        update.localizedCallerName = callerName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            Task { @MainActor in completion(error) }
        }
    }

    func reportEnded(uuid: UUID, reason: CallEndedReason) {
        let cx: CXCallEndedReason
        switch reason {
        case .failed: cx = .failed
        case .remoteEnded: cx = .remoteEnded
        case .unanswered: cx = .unanswered
        case .answeredElsewhere: cx = .answeredElsewhere
        case .declinedElsewhere: cx = .declinedElsewhere
        }
        provider.reportCall(with: uuid, endedAt: nil, reason: cx)
    }

    /// Category + mode only. NO setActive — see the file header.
    func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
    }
}

// Main-actor delegate: CXProvider was given `queue: nil` (= main), so every
// callback already arrives on the main actor — `@preconcurrency` lets the
// methods stay isolated (a runtime assertion guards the assumption).
extension CallKitProvider: @preconcurrency CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        coordinator?.providerDidReset()
    }

    func providerDidBegin(_ provider: CXProvider) {
        coordinator?.providerDidBegin()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if coordinator?.performAnswer(uuid: action.callUUID) == true { action.fulfill() } else { action.fail() }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // Fulfil even for an unknown UUID: CallKit is telling us the call is
        // gone either way, and failing would leave a phantom call in its UI.
        _ = coordinator?.performEnd(uuid: action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        _ = coordinator?.performSetMuted(uuid: action.callUUID, muted: action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        // Holding isn't supported (supportsHolding=false); fail so CallKit keeps the call live.
        action.fail()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        coordinator?.audioSessionDidActivate()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        coordinator?.audioSessionDidDeactivate()
    }
}

@MainActor
final class CallKitController: CallControlling {
    private let controller = CXCallController()

    func requestEnd(uuid: UUID, completion: @escaping @MainActor (Error?) -> Void) {
        let transaction = CXTransaction(action: CXEndCallAction(call: uuid))
        controller.request(transaction) { error in
            Task { @MainActor in completion(error) }
        }
    }
}
