//
//  DayViewModel.swift
//  Mind Reset
//
//  Created by Andika Yudhatrisna on 3/25/25.
//

import SwiftUI
import Firebase
import FirebaseFirestore
import Combine

class DayViewModel: ObservableObject {
    @Published var schedule: DaySchedule?  // Represents today's schedule (or any selected date)
    
    private var db = Firestore.firestore()
    
    // Loads the schedule doc for a specific day and user.
    func loadDaySchedule(for date: Date, userId: String) {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)  // e.g., midnight of that date
        
        // We'll use a doc with the date in some stable format as the doc ID:
        let docId = isoDayString(from: startOfDay)
        
        let docRef = db
            .collection("users")
            .document(userId)
            .collection("daySchedules")
            .document(docId)
        
        docRef.getDocument { [weak self] snapshot, error in
            if let error = error {
                print("Error loading day schedule: \(error)")
                return
            }
            
            if let snapshot = snapshot, snapshot.exists {
                // Decode existing doc
                do {
                    let daySchedule = try snapshot.data(as: DaySchedule.self)
                    DispatchQueue.main.async {
                        self?.schedule = daySchedule
                    }
                } catch {
                    print("Error decoding DaySchedule: \(error)")
                }
            } else {
                // If no doc -> create default
                self?.createDefaultDaySchedule(date: startOfDay, userId: userId)
            }
        }
    }
    
    // If no doc exists, create it with sensible defaults.
    private func createDefaultDaySchedule(date: Date, userId: String) {
        // Ensure you use the date for the schedule as your base date.
        let baseDate = date
        
        let defaultSchedule = DaySchedule(
            id: isoDayString(from: date),  // e.g., "2025-03-24"
            userId: userId,
            date: date,
            wakeUpTime: generateDate(hour: 7, minute: 0, on: baseDate),
            sleepTime: generateDate(hour: 22, minute: 0, on: baseDate),
            priorities: [
                TodayPriority(id: UUID(), title: "What matters most today", progress: 0.0)
            ],
            timeBlocks: generateTimeBlocks(
                from: generateDate(hour: 7, minute: 0, on: baseDate),
                to: generateDate(hour: 22, minute: 0, on: baseDate)
            )
        )
        
        do {
            let ref = try db
                .collection("users")
                .document(userId)
                .collection("daySchedules")
                .document(defaultSchedule.id!)
                .setData(from: defaultSchedule)
            DispatchQueue.main.async {
                self.schedule = defaultSchedule
            }
        } catch {
            print("Error creating default schedule: \(error)")
        }
    }

    
    // Writes the entire schedule back to Firestore.
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
            print("Error updating day schedule: \(error)")
        }
    }
    
    // Optionally: If the user changes wakeUpTime or sleepTime, you can regenerate timeBlocks
    func regenerateBlocks() {
        guard var schedule = schedule else { return }
        schedule.timeBlocks = generateTimeBlocks(from: schedule.wakeUpTime, to: schedule.sleepTime)
        self.schedule = schedule
        
        // Save immediately or wait for user action
        updateDaySchedule()
    }
    
    // Utility: generate hour blocks between two times
    private func generateTimeBlocks(from start: Date, to end: Date) -> [TimeBlock] {
        var blocks: [TimeBlock] = []
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        
        var current = start
        while current <= end {
            let block = TimeBlock(
                id: UUID(),
                time: formatter.string(from: current),
                task: ""
            )
            blocks.append(block)
            
            guard let next = calendar.date(byAdding: .hour, value: 1, to: current) else { break }
            current = next
        }
        return blocks
    }
    
    // Utility: create a date with a specific hour/minute
    private func generateDate(hour: Int, minute: Int, on baseDate: Date) -> Date {
        // Use the given baseDate to set the hour and minute
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: baseDate) ?? baseDate
    }
    
    // Utility: create an ISO-like string "yyyy-MM-dd" from a Date
    private func isoDayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    
    func copyPreviousDaySchedule(to targetDate: Date, userId: String, completion: @escaping (Bool) -> Void) {
        let calendar = Calendar.current
        let sourceDate = calendar.date(byAdding: .day, value: -1, to: targetDate) ?? targetDate
        let sourceDocId = isoDayString(from: calendar.startOfDay(for: sourceDate))
        let targetDocId = isoDayString(from: calendar.startOfDay(for: targetDate))
        
        let sourceRef = db.collection("users").document(userId).collection("daySchedules").document(sourceDocId)
        let targetRef = db.collection("users").document(userId).collection("daySchedules").document(targetDocId)
        
        // Fetch the source schedule.
        sourceRef.getDocument { [weak self] snapshot, error in
            if let error = error {
                print("Error fetching source schedule: \(error)")
                completion(false)
                return
            }
            guard let snapshot = snapshot, snapshot.exists,
                  let sourceSchedule = try? snapshot.data(as: DaySchedule.self) else {
                print("Source schedule not found.")
                completion(false)
                return
            }
            
            // Now fetch (or create) the target schedule.
            targetRef.getDocument { snapshot, error in
                var targetSchedule: DaySchedule
                let baseDate = calendar.startOfDay(for: targetDate)
                if let snapshot = snapshot, snapshot.exists,
                   let existingSchedule = try? snapshot.data(as: DaySchedule.self) {
                    targetSchedule = existingSchedule
                } else {
                    // Create a default schedule if there is no document.
                    targetSchedule = DaySchedule(
                        id: targetDocId,
                        userId: userId,
                        date: baseDate,
                        wakeUpTime: sourceSchedule.wakeUpTime,  // default values will be overwritten below
                        sleepTime: sourceSchedule.sleepTime,
                        priorities: [],
                        timeBlocks: []
                    )
                }
                
                // Copy the fields from the source schedule into the target schedule.
                targetSchedule.priorities = sourceSchedule.priorities
                targetSchedule.wakeUpTime = sourceSchedule.wakeUpTime
                targetSchedule.sleepTime = sourceSchedule.sleepTime
                targetSchedule.timeBlocks = sourceSchedule.timeBlocks
                
                // Save the updated target schedule to Firestore.
                do {
                    try targetRef.setData(from: targetSchedule)
                    DispatchQueue.main.async {
                        self?.schedule = targetSchedule
                    }
                    completion(true)
                } catch {
                    print("Error saving target schedule: \(error)")
                    completion(false)
                }
            }
        }
    }



}
