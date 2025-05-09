//
//  DayViewModel.swift
//  Mind Reset
//
//  Created by Andika Yudhatrisna on 3/25/25.
//

import SwiftUI
import FirebaseFirestore
import Combine

class DayViewModel: ObservableObject {
    @Published var schedule: DaySchedule?  // Represents today's schedule (or any selected date)
    
    // MARK: — Shared, cached Firestore with offline persistence
    private let db = Firestore.firestore()
    
    private var listenerRegistration: ListenerRegistration?
    private let decodeQueue = DispatchQueue(label: "day-decoder", qos: .userInitiated)
    
    
    // MARK: — Shared formatters
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    
    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt
    }()
    
    deinit {
        listenerRegistration?.remove()
    }
    
    /// Listen continuously (and decode off‐main) to today's schedule doc.
    func loadDaySchedule(for date: Date, userId: String) {
        // Stop any earlier listener
        listenerRegistration?.remove()
        
        let startOfDay = Calendar.current.startOfDay(for: date)
        let docId      = DayViewModel.isoFormatter.string(from: startOfDay)
        
        let docRef = db
            .collection("users")
            .document(userId)
            .collection("daySchedules")
            .document(docId)
        
        listenerRegistration = docRef.addSnapshotListener(includeMetadataChanges: false) { [weak self] snapshot, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Error loading day schedule:", error)
                return
            }
            
            // Heavy work → background queue
            self.decodeQueue.async {
                if let snap = snapshot, snap.exists,
                   let daySchedule = try? snap.data(as: DaySchedule.self) {
                    
                    DispatchQueue.main.async {
                        self.schedule = daySchedule
                    }
                } else {
                    // No doc yet – create one (runs on bg queue; inside it we dispatch back)
                    self.createDefaultDaySchedule(date: startOfDay, userId: userId)
                }
            }
        }
    }


    
    private func createDefaultDaySchedule(date: Date, userId: String) {
        let storedWake = UserDefaults.standard.object(forKey: "DefaultWakeUpTime") as? Date
                       ?? Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: date)!
        let storedSleep = UserDefaults.standard.object(forKey: "DefaultSleepTime") as? Date
                        ?? Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: date)!
        
        let defaultSchedule = DaySchedule(
            id: DayViewModel.isoFormatter.string(from: date),
            userId: userId,
            date: date,
            wakeUpTime: storedWake,
            sleepTime: storedSleep,
            priorities: [ TodayPriority(id: UUID(), title: "What matters most today", progress: 0.0) ],
            timeBlocks: generateTimeBlocks(from: storedWake, to: storedSleep)
        )
        
        do {
            try db
                .collection("users")
                .document(userId)
                .collection("daySchedules")
                .document(defaultSchedule.id!)
                .setData(from: defaultSchedule)
            DispatchQueue.main.async {
                self.schedule = defaultSchedule
            }
        } catch {
            print("Error creating default schedule:", error)
        }
    }

    func updateDaySchedule() {
        guard let schedule = schedule, let docId = schedule.id else { return }
        do {
            try db
                .collection("users")
                .document(schedule.userId)
                .collection("daySchedules")
                .document(docId)
                .setData(from: schedule)
        } catch {
            print("Error updating day schedule:", error)
        }
    }
    
    func regenerateBlocks() {
        guard var schedule = schedule else { return }
        schedule.timeBlocks = generateTimeBlocks(from: schedule.wakeUpTime, to: schedule.sleepTime)
        self.schedule = schedule
        updateDaySchedule()
    }
    
    // MARK: — Helpers
    private func generateTimeBlocks(from start: Date, to end: Date) -> [TimeBlock] {
        var blocks: [TimeBlock] = []
        var current = start
        let cal = Calendar.current
        
        while current <= end {
            let label = DayViewModel.timeFormatter.string(from: current)
            blocks.append(TimeBlock(id: UUID(), time: label, task: ""))
            guard let next = cal.date(byAdding: .hour, value: 1, to: current) else { break }
            current = next
        }
        return blocks
    }
    
    func copyPreviousDaySchedule(to targetDate: Date, userId: String, completion: @escaping (Bool) -> Void) {
        let cal = Calendar.current
        let sourceDate = cal.date(byAdding: .day, value: -1, to: targetDate)!
        let sourceId   = DayViewModel.isoFormatter.string(from: cal.startOfDay(for: sourceDate))
        let targetId   = DayViewModel.isoFormatter.string(from: cal.startOfDay(for: targetDate))
        
        let sourceRef = db
            .collection("users").document(userId)
            .collection("daySchedules").document(sourceId)
        let targetRef = db
            .collection("users").document(userId)
            .collection("daySchedules").document(targetId)
        
        // fetch source then write into a listener‐driven cache for the target
        sourceRef.getDocument { [weak self] snap, error in
            guard let self = self else { return }
            if let error = error {
                print("Error fetching source schedule:", error)
                return completion(false)
            }
            guard let snap = snap, snap.exists,
                  let sourceSchedule = try? snap.data(as: DaySchedule.self) else {
                print("Source schedule not found.")
                return completion(false)
            }
            
            targetRef.getDocument { targetSnap, error in
                var targetSchedule = sourceSchedule
                targetSchedule.id = targetId
                targetSchedule.date = cal.startOfDay(for: targetDate)
                
                do {
                    try targetRef.setData(from: targetSchedule)
                    DispatchQueue.main.async { self.schedule = targetSchedule }
                    completion(true)
                } catch {
                    print("Error saving target schedule:", error)
                    completion(false)
                }
            }
        }
    }
}
