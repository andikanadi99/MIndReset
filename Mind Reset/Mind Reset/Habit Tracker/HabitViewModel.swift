//
//  HabitViewModel.swift
//  Mind Reset
//
//  Manages the fetching and updating of Habit data in Firestore with customizable metrics.
//  Created by Andika Yudhatrisna on 1/3/25.
//

import Foundation
import FirebaseFirestore
import FirebaseAuth
import Combine
import SwiftUI

class HabitViewModel: ObservableObject {
    @Published var habits: [Habit] = []
    @Published var errorMessage: String? = nil
    
    @Published var localStreaks: [String: Int] = [:]
    @Published var localLongestStreaks: [String: Int] = [:]
    
    private var db = Firestore.firestore()
    private var listenerRegistration: ListenerRegistration?
    private var cancellables = Set<AnyCancellable>()
    
    private let dailyCompletionPoint = 1
    private let weeklyStreakBonus = 10
    private let monthlyStreakBonus = 50
    private let yearlyStreakBonus = 100
    
    private let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()
    
    init() {}
    
    deinit {
        listenerRegistration?.remove()
    }
    
    func fetchHabits(for userId: String) {
        listenerRegistration?.remove()
        listenerRegistration = db.collection("habits")
            .whereField("ownerId", isEqualTo: userId)
            .order(by: "startDate", descending: true)
            .addSnapshotListener { [weak self] (querySnapshot, error) in
                guard let self = self else { return }
                if let error = error {
                    print("Error fetching habits: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.errorMessage = "Failed to fetch habits."
                    }
                    return
                }
                guard let documents = querySnapshot?.documents else {
                    print("No habits found.")
                    DispatchQueue.main.async { self.habits = [] }
                    return
                }
                self.habits = documents.compactMap { doc in
                    do {
                        return try doc.data(as: Habit.self)
                    } catch {
                        print("Error decoding habit (ID: \(doc.documentID)): \(error.localizedDescription)")
                        return nil
                    }
                }
                for habit in self.habits {
                    guard let habitID = habit.id else { continue }
                    let localCurrent = self.localStreaks[habitID] ?? 0
                    if habit.currentStreak > localCurrent {
                        self.localStreaks[habitID] = habit.currentStreak
                    }
                    let localLongest = self.localLongestStreaks[habitID] ?? 0
                    if habit.longestStreak > localLongest {
                        self.localLongestStreaks[habitID] = habit.longestStreak
                    }
                }
            }
    }
    
    func addHabit(_ habit: Habit, completion: @escaping (Bool) -> Void) {
        guard let authenticatedUserId = Auth.auth().currentUser?.uid, authenticatedUserId == habit.ownerId else {
            print("User authentication error.")
            completion(false)
            return
        }
        do {
            try db.collection("habits").addDocument(from: habit) { error in
                if let error = error {
                    print("Error adding habit: \(error.localizedDescription)")
                    completion(false)
                } else {
                    completion(true)
                }
            }
        } catch {
            print("Error encoding habit: \(error.localizedDescription)")
            completion(false)
        }
    }
    
    func updateHabit(_ habit: Habit) {
        guard let id = habit.id else { return }
        do {
            try db.collection("habits").document(id).setData(from: habit)
            print("Habit '\(habit.title)' updated (ID: \(id)).")
        } catch {
            print("Error updating habit: \(error.localizedDescription)")
            DispatchQueue.main.async { self.errorMessage = "Failed to update habit." }
        }
    }
    
    func deleteHabit(_ habit: Habit) {
        guard let id = habit.id else {
            print("Cannot delete: Habit has no ID.")
            DispatchQueue.main.async { self.errorMessage = "Failed to delete habit (no ID)." }
            return
        }
        db.collection("habits").document(id).delete { [weak self] err in
            if let e = err {
                print("Error deleting habit: \(e)")
                DispatchQueue.main.async { self?.errorMessage = "Failed to delete habit." }
            } else {
                print("Habit (ID: \(id)) deleted successfully.")
                DispatchQueue.main.async {
                    self?.habits.removeAll { $0.id == id }
                    self?.localStreaks.removeValue(forKey: id)
                    self?.localLongestStreaks.removeValue(forKey: id)
                }
            }
        }
    }
    
    func awardPointsToUser(userId: String, points: Int) {
        let userRef = db.collection("users").document(userId)
        db.runTransaction({ (transaction, errorPointer) -> Any? in
            do {
                let userSnap = try transaction.getDocument(userRef)
                let currentPoints = userSnap.data()?["totalPoints"] as? Int ?? 0
                transaction.updateData(["totalPoints": currentPoints + points], forDocument: userRef)
            } catch {
                if let errPointer = errorPointer { errPointer.pointee = error as NSError }
                return nil
            }
            return nil
        }) { (result, error) in
            if let e = error {
                print("Error awarding points: \(e.localizedDescription)")
                DispatchQueue.main.async { self.errorMessage = "Failed to award points." }
            } else {
                print("Points awarded successfully: +\(points)")
            }
        }
    }
    
    func setupDefaultHabitsIfNeeded(for userId: String) {
        let userRef = db.collection("users").document(userId)
        userRef.getDocument { [weak self] snapshot, err in
            guard let self = self else { return }
            if let e = err {
                print("Error fetching user doc: \(e)")
                return
            }
            guard let doc = snapshot, doc.exists else {
                print("No user doc found for \(userId). Skipping default habits.")
                return
            }
            let data = doc.data() ?? [:]
            let defaultsCreated = data["defaultHabitsCreated"] as? Bool ?? false
            if !defaultsCreated {
                print("Creating default habits for user: \(userId).")
                self.createDefaultHabits(for: userId)
                userRef.updateData(["defaultHabitsCreated": true]) { updateErr in
                    if let ue = updateErr {
                        print("Error updating defaultHabitsCreated: \(ue)")
                    } else {
                        print("Default habits set for user: \(userId).")
                    }
                }
            } else {
                print("Default habits already exist for \(userId). Doing nothing.")
            }
        }
    }
    
    private func createDefaultHabits(for userId: String) {
        let defaultHabits: [Habit] = [
            Habit(
                title: "Daily Walk",
                description: "Take a short walk outside to increase overall health and physical well-being.",
                goal: "Promote an active lifestyle and improve physical health.",
                startDate: Date(),
                ownerId: userId,
                metricCategory: .quantity,
                metricType: .predefined(QuantityMetric.distanceMiles.rawValue),
                dailyRecords: []
            ),
            Habit(
                title: "Reading",
                description: "Read for a specific amount of time or pages to improve and learn new things.",
                goal: "Encourage knowledge acquisition and mental stimulation.",
                startDate: Date(),
                ownerId: userId,
                metricCategory: .quantity,
                metricType: .predefined(QuantityMetric.pagesRead.rawValue),
                dailyRecords: []
            ),
            Habit(
                title: "Journaling",
                description: "Write down your thoughts and feelings to enhance mindfulness and self-reflection.",
                goal: "Promote self-awareness and personal growth.",
                startDate: Date(),
                ownerId: userId,
                metricCategory: .quantity,
                metricType: .predefined(QuantityMetric.entriesWritten.rawValue),
                dailyRecords: []
            ),
            Habit(
                title: "Plan Daily Tasks",
                description: "Plan and organize your daily tasks to ensure efficiency throughout the day.",
                goal: "Increase productivity and manage stress effectively.",
                startDate: Date(),
                ownerId: userId,
                metricCategory: .completion,
                metricType: .predefined(CompletionMetric.completed.rawValue),
                dailyRecords: []
            ),
            Habit(
                title: "Meditation",
                description: "Practice mindfulness through meditation, focus on your breath, or other techniques.",
                goal: "Reduce stress, enhance focus, and promote emotional well-being.",
                startDate: Date(),
                ownerId: userId,
                metricCategory: .time,
                metricType: .predefined(TimeMetric.minutes.rawValue),
                dailyRecords: []
            )
        ]
        for habit in defaultHabits {
            addHabit(habit) { success in
                if success {
                    print("Default habit '\(habit.title)' added successfully.")
                } else {
                    print("Failed to add default habit '\(habit.title)'.")
                }
            }
        }
        DispatchQueue.main.async {
            self.habits.append(contentsOf: defaultHabits)
        }
    }
    
    func dailyResetIfNeeded() {
        let today = Date()
        let todayString = dateFormatter.string(from: today)
        for i in 0..<habits.count {
            var habit = habits[i]
            // Check if the last record is for today; if not, remove all records not from today.
            if let lastRecord = habit.dailyRecords.last,
               !Calendar.current.isDate(lastRecord.date, inSameDayAs: today) {
                habit.dailyRecords.removeAll { !Calendar.current.isDate($0.date, inSameDayAs: today) }
                updateHabit(habit)
                habits[i] = habit
            }
        }
    }

    
    // MARK: - Updated Toggle Habit Completion (for both marking and unmarking)
    func toggleHabitCompletion(_ habit: Habit, userId: String) {
        guard let idx = habits.firstIndex(where: { $0.id == habit.id }),
              let habitId = habit.id else { return }
        let oldHabit = habits[idx]
        var updated = habit
        let calendar = Calendar.current
        let today = Date()
        
        if isHabitCompleted(updated, on: today) {
            // UNMARK: Remove today's record from dailyRecords.
            updated.dailyRecords.removeAll { record in
                calendar.isDate(record.date, inSameDayAs: today)
            }
            // Update streaks and lastReset accordingly.
            updated.currentStreak = max(updated.currentStreak - 1, 0)
            if updated.currentStreak < updated.longestStreak,
               oldHabit.currentStreak == oldHabit.longestStreak {
                updated.longestStreak = updated.currentStreak
            }
            updated.lastReset = nil
        } else {
            // MARK: Add a new record for today.
            let newRecord = HabitRecord(date: today, value: 1)
            updated.dailyRecords.append(newRecord)
            // Update streak if this is the first record for today.
            let todayStr = dateFormatter.string(from: today)
            let lastResetStr = updated.lastReset == nil ? "" : dateFormatter.string(from: updated.lastReset!)
            if lastResetStr != todayStr {
                updated.currentStreak += 1
                if updated.currentStreak > updated.longestStreak {
                    updated.longestStreak = updated.currentStreak
                }
                updated.lastReset = today
            }
        }
        
        // Update local streak dictionaries.
        localStreaks[habitId] = updated.currentStreak
        localLongestStreaks[habitId] = updated.longestStreak
        habits[idx] = updated
        
        do {
            try db.collection("habits").document(habitId).setData(from: updated)
            // Award points if the habit is now completed for today.
            if isHabitCompleted(updated, on: today) {
                var totalPoints = dailyCompletionPoint + updated.currentStreak
                if updated.currentStreak == 7 { totalPoints += weeklyStreakBonus }
                if updated.currentStreak == 30 { totalPoints += monthlyStreakBonus }
                if updated.currentStreak == 365 { totalPoints += yearlyStreakBonus }
                awardPointsToUser(userId: userId, points: totalPoints)
            }
        } catch {
            print("Error updating habit in Firestore: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.habits[idx] = oldHabit
                self.localStreaks[habitId] = oldHabit.currentStreak
                self.localLongestStreaks[habitId] = oldHabit.longestStreak
                self.errorMessage = "Failed to update habit."
            }
        }
    }

    
    // MARK: - New Note-Saving Method
    
    func saveUserNote(for habitID: String, note: String, completion: @escaping (Bool) -> Void) {
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !habitID.isEmpty else {
            completion(false)
            return
        }
        
        let newNote = UserNote(habitID: habitID, noteText: note)
        
        do {
            try db.collection("UserNotes").addDocument(from: newNote) { error in
                if let error = error {
                    print("Error saving user note: \(error.localizedDescription)")
                    completion(false)
                } else {
                    print("User note saved successfully for habitID: \(habitID)")
                    completion(true)
                }
            }
        } catch {
            print("Error encoding user note: \(error.localizedDescription)")
            completion(false)
        }
    }
    
    // MARK: - New Delete Note Method
    
    func deleteUserNote(note: UserNote, completion: @escaping (Bool) -> Void) {
        guard let noteID = note.id else {
            completion(false)
            return
        }
        db.collection("UserNotes").document(noteID).delete { error in
            if let error = error {
                print("Error deleting note: \(error.localizedDescription)")
                completion(false)
            } else {
                print("Note deleted successfully.")
                completion(true)
            }
        }
    }
}

extension HabitViewModel {
    /// Returns true if the habit has a record for `day` with a positive value.
    func isHabitCompleted(_ habit: Habit, on day: Date) -> Bool {
        let cal = Calendar.current
        return habit.dailyRecords.contains { record in
            cal.isDate(record.date, inSameDayAs: day) && ((record.value ?? 0) > 0)
        }
    }
}
