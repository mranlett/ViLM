import Foundation
import GRDB

extension LibraryStore {
    
    /// Merges two profiles by ID, specifically for deduplicating profiles with the exact same name.
    public func mergeProfiles(losingId: String, survivingId: String) throws -> Bool {
        var merged = false
        try dbQueue.write { db in
            try db.execute(sql: "SAVEPOINT merge_profiles")
            do {
                guard let oldProfile = try EntityProfile.fetchOne(db, key: losingId),
                      var dest = try EntityProfile.fetchOne(db, key: survivingId) else {
                    return
                }
                
                // Merge destination and source
                dest.bio = dest.bio ?? oldProfile.bio
                dest.photoUrl = dest.photoUrl ?? oldProfile.photoUrl
                dest.homePage = dest.homePage ?? oldProfile.homePage
                dest.gender = dest.gender ?? oldProfile.gender
                dest.hairColor = dest.hairColor ?? oldProfile.hairColor
                dest.birthYear = dest.birthYear ?? oldProfile.birthYear
                dest.countryOfOrigin = dest.countryOfOrigin ?? oldProfile.countryOfOrigin
                dest.rating = dest.rating ?? oldProfile.rating
                dest.tags = (dest.tags + oldProfile.tags.filter { !dest.tags.contains($0) })
                dest.galleryUrls = (dest.galleryUrls + oldProfile.galleryUrls.filter { !dest.galleryUrls.contains($0) })
                dest.akas = (dest.akas + oldProfile.akas.filter { !dest.akas.contains($0) })
                dest.birthDate = dest.birthDate ?? oldProfile.birthDate
                dest.careerSpanRaw = dest.careerSpanRaw ?? oldProfile.careerSpanRaw
                dest.careerStartYear = dest.careerStartYear ?? oldProfile.careerStartYear
                dest.careerEndYear = dest.careerEndYear ?? oldProfile.careerEndYear
                dest.ageAtCareerStart = dest.ageAtCareerStart ?? oldProfile.ageAtCareerStart
                dest.enrichmentState = dest.enrichmentState ?? oldProfile.enrichmentState
                dest.enrichmentSource = dest.enrichmentSource ?? oldProfile.enrichmentSource
                dest.enrichmentSourceId = dest.enrichmentSourceId ?? oldProfile.enrichmentSourceId
                dest.enrichmentCheckedAt = dest.enrichmentCheckedAt ?? oldProfile.enrichmentCheckedAt
                dest.links = EntityLink.merged(dest.links, adding: oldProfile.links)
                try dest.save(db)
                
                // Move edges
                for (table, column) in GraphTable.entityReferences {
                    try db.execute(sql:
                        "UPDATE OR IGNORE \(table) SET \(column) = ? WHERE \(column) = ?",
                        arguments: [survivingId, losingId])
                    try db.execute(sql: "DELETE FROM \(table) WHERE \(column) = ?",
                                   arguments: [losingId])
                }
                
                try db.execute(sql:
                    "UPDATE OR IGNORE studio_parent SET studio_id = ? WHERE studio_id = ?",
                    arguments: [survivingId, losingId])
                try db.execute(sql: "DELETE FROM studio_parent WHERE studio_id = ?",
                               arguments: [losingId])
                
                try db.execute(sql: "DELETE FROM studio_parent WHERE parent_studio_id = studio_id")
                
                // Tombstone
                try recordTombstone(EntityTombstone(entityId: losingId, replacedBy: survivingId), in: db)
                
                // Delete old profile
                try oldProfile.delete(db)
                
                // Move photos
                let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
                let sourceFile = profilesDir.appendingPathComponent("\(losingId).jpg")
                let destFile = profilesDir.appendingPathComponent("\(survivingId).jpg")
                if FileManager.default.fileExists(atPath: sourceFile.path) {
                    if !FileManager.default.fileExists(atPath: destFile.path) {
                        try? FileManager.default.moveItem(at: sourceFile, to: destFile)
                    } else {
                        try? FileManager.default.removeItem(at: sourceFile)
                    }
                }
                
                try db.execute(sql: "RELEASE SAVEPOINT merge_profiles")
                merged = true
            } catch {
                try db.execute(sql: "ROLLBACK TO SAVEPOINT merge_profiles")
                throw error
            }
        }
        return merged
    }
}
