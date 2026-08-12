// ContentKind.swift
// What a video IS, and the privacy boundary that reads it.
//
// 🚨 Installing a provider means titles leave the device. That is acceptable
// for commercial content, where the title is public. For personal video it is
// not: a home-video filename can carry family names, children's names, a
// location or an event — and it would also be useless, because no external
// database holds a record of a family holiday.
//
// ⭐ The rule is FAIL CLOSED, and the asymmetry is what decides it. Fail-open is
// irreversible — once a name reaches a third party it cannot be recalled —
// while fail-closed costs a delay. So `nil` is refused too: it is the state
// every row begins in, and treating it as "not personal" would open the
// boundary for the whole library on the day it shipped.
//
// ⚠️ The refusal lives at the BOUNDARY, before a request is constructed, not in
// the loops that happen to call it. "The batch doesn't select it" is a property
// of one caller; a boundary refuses regardless of who asks.

import Foundation

/// What kind of thing a video is. Declared by a person, never inferred.
///
/// 🚨 Nothing may pre-select a kind on the operator's behalf. A pre-filled
/// default is inference wearing a declaration's clothes, and `personal` is the
/// case where being wrong is unrecoverable.
public enum ContentKind: String, Codable, Sendable, CaseIterable {
    /// A scene from a commercial release.
    case scene
    /// A feature-length commercial release.
    case film
    /// Part of a commercial series.
    case episodic
    /// The operator's own video. Never leaves the device.
    case personal

    public var displayName: String {
        switch self {
        case .scene: return "Scene"
        case .film: return "Film"
        case .episodic: return "Episodic"
        case .personal: return "Personal"
        }
    }

    /// Whether a title of this kind may be sent to an external source.
    ///
    /// ⚠️ Read through `ProviderBoundary`, never directly at a call site — the
    /// undeclared case is the one that matters and an enum cannot express it.
    var mayLeaveTheDevice: Bool { self != .personal }
}

/// The single gate every outbound lookup passes through.
///
/// ⭐ A namespace rather than a method on `Asset` deliberately: the decision has
/// to be nameable in a test, and a double that fails if it is called at all
/// (T16, PA4) needs something to assert against.
public enum ProviderBoundary {

    /// Why a lookup was refused, for the operator and for the log.
    public enum Refusal: Equatable, Sendable {
        /// Declared personal. Never sent, by any caller, ever.
        case personalContent
        /// Not declared. Refused because unknown is not the same as safe.
        case undeclared

        public var reason: String {
            switch self {
            case .personalContent:
                return "This is your own video, so its title is never sent to an external source."
            case .undeclared:
                return "This video has not been declared as personal or commercial yet. "
                     + "Nothing is sent until it has been — declare it and try again."
            }
        }
    }

    /// Nil when the lookup may proceed; a refusal otherwise.
    ///
    /// 🚨 `nil` content kind is a REFUSAL, not a pass. Every row starts
    /// undeclared, so the opposite reading would have sent the entire library
    /// on day one.
    public static func refusal(for kind: ContentKind?) -> Refusal? {
        guard let kind else { return .undeclared }
        return kind.mayLeaveTheDevice ? nil : .personalContent
    }

    public static func allows(_ kind: ContentKind?) -> Bool {
        refusal(for: kind) == nil
    }
}
