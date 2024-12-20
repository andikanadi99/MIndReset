//
//  HabitViewModel.swift
//  Mind Reset
//  Habit model for the habit tracker on the app.
//  Created by Andika Yudhatrisna on 12/1/24.
//

import Foundation
import FirebaseFirestore
import Combine


class HabitViewModel: ObservableObject {
    @Published var habits: [Habit] = [] //Declaration of public habit variable throughout app
    //Private variables of app to reference listener of model and firestore db
    private var db = Firestore.firestore()
    private var listenerRegistration: ListenerRegistration?
    
    /*
        Purpose: Grabs defined habits from the FireStore Database
    */
    func fetchHabits(for userId: String){
        listenerRegistration = db.collection("habits")
            .whereField("ownerId",isEqualTo: userId)
            .order(by: "startDate", descending: true)
            .addSnapshotListener { [weak self] (querySnapshot, error) in
                if let error = error {
                    print("Error fetching habits: \(error)")
                    return
                }
                self?.habits = querySnapshot?.documents.compactMap { document in
                    try? document.data(as: Habit.self)
                } ?? []
            }
    }
    /*
        Purpose: Adds a new habit to the list of habits associated with the user
    */
    func addHabit(_ habit: Habit){
        do{
            _ = try db.collection("habits").addDocument(from: habit)
        }catch{
            print("Error adding habit: \(error)")
        }
    }
    /*
        Purpose: Update properties of specified habit for user
    */
    func updateHabit(_ habit: Habit){
        //Get id of habit if it exist
        guard let id = habit.id else { return }
        do{
            try db.collection("habits").document(id).setData(from: habit)
        }catch{
            print("Error adding habit: \(error)")
        }
    }
    
    /*
        Purpose: Delete habit function
    */
        func deleteHabit(_ habit: Habit) {
            guard let id = habit.id else {
                print("Habit ID is nil, cannot delete.")
                return
            }
            db.collection("habits").document(id).delete { [weak self] error in
                if let error = error {
                    print("Error deleting habit: \(error)")
                } else {
                    print("Successfully deleted habit with ID: \(id)")
                    // Optionally, remove the habit from the local habits array
                    DispatchQueue.main.async {
                        self?.habits.removeAll { $0.id == id }
                    }
                }
            }
        }
    
        // Remove the listener when not needed
        deinit {
            listenerRegistration?.remove()
        }
}
