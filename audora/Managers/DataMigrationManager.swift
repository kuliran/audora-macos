// DataMigrationManager.swift
// Handles data migration between different app versions

import Foundation

/// Manages data migration between different app versions
class DataMigrationManager {
    static let shared = DataMigrationManager()
    
    private init() {}
    
    /// Migrates a meeting from an older version to the current version
    /// - Parameter meeting: The meeting to migrate
    /// - Returns: The migrated meeting, or nil if migration failed
    func migrateMeeting(_ meeting: Meeting) -> Meeting? {
        // No releases prior to version 1 – any older file is considered unsupported.
        guard meeting.dataVersion >= 1 else {
            print("🚫 Cannot migrate meeting \(meeting.id) – unsupported data version \(meeting.dataVersion)")
            return nil
        }

        var migratedMeeting = meeting

        // Run sequential migrations if needed
        while migratedMeeting.dataVersion < Meeting.currentDataVersion {
            let nextVersion = migratedMeeting.dataVersion + 1
            print("🔄 Migrating meeting \(migratedMeeting.id) to version \(nextVersion)")
            
            // Future migrations can be added here as `if nextVersion == X` blocks
            
            migratedMeeting.dataVersion = nextVersion
        }

        return migratedMeeting
    }
    
    // Future migrateXToVersionY helpers will go here as needed
    
    /// Performs a backup of the meetings directory before migration
    /// - Returns: The backup directory URL, or nil if backup failed
    func backupMeetingsDirectory() -> URL? {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let meetingsDirectory = documentsDirectory.appendingPathComponent("Meetings")
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        
        var backupDirectory = documentsDirectory.appendingPathComponent("Meetings_Backup_\(timestamp)")
        
        if FileManager.default.fileExists(atPath: backupDirectory.path) {
            backupDirectory = documentsDirectory.appendingPathComponent("Meetings_Backup_\(timestamp)_\(UUID().uuidString)")
        }
        
        do {
            try FileManager.default.copyItem(at: meetingsDirectory, to: backupDirectory)
            print("✅ Created backup at: \(backupDirectory)")
            return backupDirectory
        } catch {
            print("❌ Failed to create backup: \(error)")
            return nil
        }
    }
} 