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

/// Why a bulk declaration was refused, naming what to do about it.
public enum DeclarationRefusal: Error, Equatable {
    /// Some of the selection already carries a declaration.
    ///
    /// 🚨 The batch is refused rather than overwriting them (T25). Re-declaring
    /// in bulk is how a video the operator marked `personal` would quietly
    /// become `scene` — the one mistake in this whole area that cannot be
    /// taken back, and the operator would have no way to know it happened.
    case alreadyDeclared(count: Int)
    /// A selected asset is not in this library.
    case missing(count: Int)
    /// The selection includes videos declared `personal`, and an overwrite was
    /// asked for.
    ///
    /// 🚨 Refused even with the overwrite flag set. Correcting `scene` to `film`
    /// in bulk is harmless housekeeping; turning `personal` into `scene` is the
    /// one change in this area that cannot be taken back, and it would arrive as
    /// a side effect of an action aimed at something else entirely.
    case personalInSelection(count: Int)

    public var reason: String {
        switch self {
        case let .alreadyDeclared(count):
            return "\(count) of these already say what they are, so nothing was changed. "
                 + "Use “Change all” if you meant to replace them."
        case let .missing(count):
            return "\(count) of these are no longer in the library. Nothing was changed."
        case let .personalInSelection(count):
            return "\(count) of these are marked as your own videos, and a bulk change "
                 + "will not overwrite that. Nothing was changed — open those individually "
                 + "if you really mean to reclassify them."
        }
    }
}

public extension LibraryStore {

    /// Declares a kind across a selection, all or nothing (T25).
    ///
    /// ⚠️ ONE transaction. The per-row loop it replaces left a half-declared
    /// selection behind any mid-batch failure — the same invisible partial that
    /// `saveEntityProfiles` exists to prevent (DEFECT_INVENTORY M4), and worse
    /// here, because a partly-declared selection looks exactly like a finished
    /// one.
    ///
    /// - Parameter overwritingExisting: replace declarations already present.
    ///   ⚠️ Off by default, and the default is the safe one — a bulk action must
    ///   not silently reclassify something the operator already answered. But
    ///   refusing outright made a wrong bulk declaration correctable only one
    ///   video at a time, which at 2,000 videos is no correction at all. So the
    ///   refusal is now an offer: it reports the count, and the caller may come
    ///   back having meant it.
    ///
    ///   🚨 `personal` is never overwritten, flag or no flag. See
    ///   `DeclarationRefusal.personalInSelection`.
    /// - Returns: how many assets were declared.
    @discardableResult
    func declareContentKind(_ kind: ContentKind, forAssetIds ids: [UUID],
                            overwritingExisting: Bool = false) throws -> Int {
        try performInTransaction { db in
            var assets: [Asset] = []
            var alreadyDeclared = 0
            var personal = 0
            var missing = 0

            for id in ids {
                guard let asset = try Asset.fetchOne(db, key: id.uuidString) else {
                    missing += 1
                    continue
                }
                switch asset.contentKind {
                case .none:
                    assets.append(asset)
                case .personal:
                    // Counted separately whichever mode we are in: with the flag
                    // it is the refusal, without it it is just one of the
                    // already-declared.
                    personal += 1
                    alreadyDeclared += 1
                case .some:
                    alreadyDeclared += 1
                    if overwritingExisting { assets.append(asset) }
                }
            }

            if overwritingExisting && personal > 0 {
                throw DeclarationRefusal.personalInSelection(count: personal)
            }

            // ⭐ The TRANSACTION is what makes this all-or-nothing — throwing
            // anywhere inside rolls back every write, so ordering is not what
            // protects the property. Verified: reordering the checks after the
            // writes kills no test, while removing the transaction kills two.
            //
            // Checked first anyway, because doing no work before a certain
            // refusal is cheaper and reads as the intent rather than relying on
            // a rollback the next reader has to know about.
            if missing > 0 { throw DeclarationRefusal.missing(count: missing) }
            if !overwritingExisting && alreadyDeclared > 0 {
                throw DeclarationRefusal.alreadyDeclared(count: alreadyDeclared)
            }

            for var asset in assets {
                asset.contentKind = kind
                try updateAsset(asset, in: db)
            }
            return assets.count
        }
    }
}
