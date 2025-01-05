//
//  HabitTrackerView.swift
//  Mind Reset
//  Objective: Serves as the main user interface for the habit-tracking feature of the app. It displays a list of habits, allows users to add new habits, mark habits as completed, and delete habits.
//  Created by Andika Yudhatrisna on 12/1/24.
//

import SwiftUI
import FirebaseAuth
import Combine

@available(iOS 16.0, *)
struct HabitTrackerView: View {
    // MARK: - State & Environment
    @StateObject private var viewModel: HabitViewModel
    @EnvironmentObject var session: SessionStore
    
    @State private var showingAddHabit = false
    
    // Dark theme & accent
    let backgroundBlack = Color.black
    let accentCyan      = Color(red: 0, green: 1, blue: 1) // #00FFFF

    // Placeholder daily quote
    let dailyQuote = "Focus on what matters today."
    
    // Placeholder for total sessions
    @State private var totalSessions: Int = 0

    // MARK: - Combine Cancellables
    @State private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initializer for Dependency Injection
    init(viewModel: HabitViewModel = HabitViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationView { // Wrapped in NavigationView to enable navigation links
            ZStack {
                backgroundBlack.ignoresSafeArea()
                
                VStack(alignment: .leading, spacing: 16) {
                    // Personalized Greeting
                    Text(greetingMessage)
                        .font(.title)
                        .fontWeight(.heavy)
                        .foregroundColor(.white)
                        .shadow(color: .white.opacity(0.8), radius: 4)
                    
                    // Daily Motivational Quote
                    Text(dailyQuote)
                        .font(.subheadline)
                        .foregroundColor(accentCyan)

                    // Total Sessions
                    HStack {
                        Text("Total Sessions: \(totalSessions)")
                            .foregroundColor(.white)
                    }
                    .padding(.vertical, 10)
                    
                    // Habit List
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.habits) { habit in
                                // Use NavigationLink to navigate to HabitDetailView
                                NavigationLink(
                                    destination: HabitDetailView(habit: habit)
                                ) {
                                    // Our row item
                                    HabitRow(
                                        habit: habit,
                                        accentCyan: accentCyan,
                                        onDelete: { deletedHabit in
                                            deleteHabit(deletedHabit)
                                        },
                                        onToggleCompletion: {
                                            toggleHabitCompletion(habit)
                                        }
                                    )
                                }
                            }
                        }
                        .padding(.top, 10)
                    }
                    
                    Spacer()
                }
                .padding()
                // **Important**: Check user doc for defaultHabitsCreated & fetch existing
                .onAppear {
                    guard let userId = session.current_user?.uid else {
                        print("No authenticated user found.")
                        return
                    }
                    // 1) Fetch existing habits
                    viewModel.fetchHabits(for: userId)
                    // 2) Setup default habits if needed (only once)
                    viewModel.setupDefaultHabitsIfNeeded(for: userId)
                    
                    // Then do a daily reset check
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        viewModel.dailyResetIfNeeded()
                    }
                    
                    // Update total sessions based on habits
                    updateTotalSessions()
                    
                    // Observe changes in habits to update totalSessions
                    viewModel.$habits
                        .sink { _ in
                            updateTotalSessions()
                        }
                        .store(in: &cancellables)
                }
                
                // Floating + button for adding new habits
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            showingAddHabit = true
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 50, height: 50)
                                .foregroundColor(.black)
                                .background(accentCyan)
                                .clipShape(Circle())
                                .shadow(color: accentCyan.opacity(0.6), radius: 5)
                        }
                        .padding()
                    }
                }
            }
            .sheet(isPresented: $showingAddHabit) {
                AddHabitView(viewModel: viewModel)
                    .environmentObject(session)
            }
            .navigationBarHidden(true)
        }
    }

    // MARK: - Greeting
    private var greetingMessage: String {
        let userName = session.current_user?.email ?? "User"
        return "Welcome back, let’s get started!"
    }
    
    // MARK: - Toggle Completion
    private func toggleHabitCompletion(_ habit: Habit) {
        guard let userId = session.current_user?.uid else { return }
        viewModel.toggleHabitCompletion(habit, userId: userId)
    }
    
    // MARK: - Delete Habit
    private func deleteHabit(_ habit: Habit) {
        viewModel.deleteHabit(habit)
    }
    
    // MARK: - Update Total Sessions
    private func updateTotalSessions() {
        // Assuming totalSessions is the count of habits where isCompletedToday is true
        totalSessions = viewModel.habits.filter { $0.isCompletedToday }.count
    }
}

// MARK: - HabitRow
struct HabitRow: View {
    let habit: Habit
    let accentCyan: Color
    let onDelete: (Habit) -> Void
    let onToggleCompletion: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Title
                Text(habit.title)
                    .font(.headline)
                    .foregroundColor(.white)
                
                // Description
                Text(habit.description)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                
                // Streak Information
                HStack(spacing: 8) {
                    // Current Streak
                    Text("Streak: \(habit.currentStreak)")
                        .font(.caption)
                        .foregroundColor(.white)
                    
                    // Longest Streak
                    Text("Longest: \(habit.longestStreak)")
                        .font(.caption)
                        .foregroundColor(.white)
                    
                    // Badges
                    if habit.weeklyStreakBadge {
                        StreakBadge(text: "7-Day", color: .green)
                    }
                    if habit.monthlyStreakBadge {
                        StreakBadge(text: "30-Day", color: .yellow)
                    }
                    if habit.yearlyStreakBadge {
                        StreakBadge(text: "365-Day", color: .purple)
                    }
                }
            }
            Spacer()
            
            // Toggle Completion Button
            Button(action: {
                onToggleCompletion()
            }) {
                if habit.isCompletedToday {
                    Text("✓")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.green)
                        .clipShape(Circle())
                } else {
                    Text("+")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(accentCyan)
                        .clipShape(Circle())
                }
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.trailing, 8)
            
            // Trash icon
            Button {
                onDelete(habit)
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
        }
        .padding()
        .background(
            Color(red: 0.15, green: 0.15, blue: 0.15)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(accentCyan.opacity(0.7), lineWidth: 1)
                )
        )
        .cornerRadius(8)
    }
}

// MARK: - StreakBadge Component
struct StreakBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color)
            .clipShape(Capsule())
    }
}

// MARK: - Preview
struct HabitTrackerView_Previews: PreviewProvider {
    static var previews: some View {
        // Create a mock SessionStore
        let session = SessionStore()
        
        // Create a mock HabitViewModel with sample habits
        let mockViewModel = HabitViewModel()
        
        // Sample Habits with corrected parameter order
        let sampleHabit1 = Habit(
            id: "1",
            title: "Daily Coding",
            description: "Review Swift concepts",
            startDate: Date(),
            ownerId: "testOwner",
            isCompletedToday: true,
            lastReset: nil,
            points: 100,
            currentStreak: 5,
            longestStreak: 10,
            weeklyStreakBadge: false,
            monthlyStreakBadge: false,
            yearlyStreakBadge: false
        )
        
        let sampleHabit2 = Habit(
            id: "2",
            title: "Meditation",
            description: "Morning meditation for clarity",
            startDate: Date(),
            ownerId: "testOwner",
            isCompletedToday: false,
            lastReset: nil,
            points: 200,
            currentStreak: 30,
            longestStreak: 30,
            weeklyStreakBadge: true,
            monthlyStreakBadge: true,
            yearlyStreakBadge: false
        )
        
        // Assign sample habits to the mock view model
        mockViewModel.habits = [sampleHabit1, sampleHabit2]
        
        return NavigationView {
            HabitTrackerView(viewModel: mockViewModel)
                .environmentObject(session)
        }
        .preferredColorScheme(.dark)
    }
}
