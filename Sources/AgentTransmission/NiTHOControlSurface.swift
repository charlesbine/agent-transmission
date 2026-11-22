import Foundation
import IOKit.hid
import AgentTransmissionCore

final class NiTHOControlSurface: ControlSurface {
    static let vendorID = 0x2345
    static let productID = 0xe00c

    let name = "NiTHO GS-SH Gearshifter"
    var onEvents: (([ControlSurfaceEvent]) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?

    private let manager: IOHIDManager
    private var buttons: Set<Int> = []
    private var stateMachine = ShifterStateMachine()
    private var settleWorkItem: DispatchWorkItem?
    private var neutralWorkItem: DispatchWorkItem?
    private var modifierHeld = false

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let owner = Unmanaged<NiTHOControlSurface>.fromOpaque(context).takeUnretainedValue()
            owner.onConnectionChanged?(true)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let owner = Unmanaged<NiTHOControlSurface>.fromOpaque(context).takeUnretainedValue()
            owner.buttons.removeAll()
            owner.modifierHeld = false
            owner.onConnectionChanged?(false)
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let owner = Unmanaged<NiTHOControlSurface>.fromOpaque(context).takeUnretainedValue()
            owner.receive(value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func stop() {
        settleWorkItem?.cancel()
        neutralWorkItem?.cancel()
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func receive(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == kHIDPage_Button else { return }

        let usage = Int(IOHIDElementGetUsage(element))
        guard (1...10).contains(usage) else { return }

        let hadDirectButtons = !buttons.intersection(1...7).isEmpty
        if IOHIDValueGetIntegerValue(value) == 0 {
            buttons.remove(usage)
        } else {
            buttons.insert(usage)
        }
        sample()

        let hasDirectButtons = !buttons.intersection(1...7).isEmpty
        if hasDirectButtons {
            neutralWorkItem?.cancel()
            neutralWorkItem = nil
            settleWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in self?.sample() }
            settleWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.030, execute: workItem)
        } else if hadDirectButtons {
            settleWorkItem?.cancel()
            settleWorkItem = nil
            neutralWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in self?.sample() }
            neutralWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + stateMachine.neutralSettleInterval + 0.010, execute: workItem)
        }
    }

    private func sample() {
        let rawEvents = stateMachine.sample(
            buttons: buttons,
            at: ProcessInfo.processInfo.systemUptime
        )
        let events = rawEvents.map { event -> ControlSurfaceEvent in
            switch event {
            case let .engaged(position):
                return .selectPosition(position)
            case .enteredNeutral:
                return .enteredNeutral
            case let .sequentialStep(direction):
                return modifierHeld ? .stepModelFamily(direction) : .stepEffort(direction)
            case let .parkingChanged(pressed):
                modifierHeld = pressed
                return .modifierChanged(pressed)
            }
        }
        if !events.isEmpty { onEvents?(events) }
    }
}
