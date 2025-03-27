//
//  HabitDetailView.swift
//  Mind Reset
//
//  Displays details/stats for a single habit. Includes custom overlay pop-ups for:
//    - picking real weeks (Sunday–Saturday) or real months,
//    - entering metric values when marking the habit as done,
//    - confirming unmarking,
//    - and now for picking a custom date range for the graph.
//  The habit screen remains visible underneath (tinted white).
//
//  Created by Andika Yudhatrisna on 1/3/25.
//

import SwiftUI
import Combine
import FirebaseFirestore

struct HabitDetailView: View {
    // MARK: - The Habit Being Displayed
    @Binding var habit: Habit

    // MARK: - Environment & Dependencies
    @EnvironmentObject var viewModel: HabitViewModel
    @EnvironmentObject var session: SessionStore
    @Environment(\.presentationMode) var presentationMode

    // MARK: - Editable Local Fields
    @State private var editableTitle: String
    @State private var editableDescription: String

    // MARK: - Tabs (Focus, Progress, Notes)
    @State private var selectedTabIndex: Int = 0  // 0=Focus, 1=Progress, 2=Notes

    // MARK: - Timer States
    @State private var countdownSeconds: Int = 0
    @State private var timer: Timer? = nil
    @State private var isTimerRunning = false
    @State private var isTimerPaused: Bool = false
    @State private var totalFocusTime: Int = 0

    // Countdown pickers
    @State private var selectedHours: Int = 0
    @State private var selectedMinutes: Int = 0

    // MARK: - Notes
    @State private var sessionNotes: String = ""
    @State private var pastSessionNotes: [UserNote] = []

    // MARK: - Habit Goal
    @State private var goal: String

    // MARK: - Additional UI
    @Namespace private var animation
    @State private var showCharts: Bool = false
    @State private var showPreviousNotes: Bool = false
    @State private var showBanner: Bool = false

    // NEW: For showing the metric input overlay when marking the habit as done.
    @State private var showMetricInput: Bool = false
    @State private var metricInput: String = ""

    // NEW: For showing the unmark confirmation overlay.
    @State private var showUnmarkConfirmation: Bool = false

    // NEW: For showing the custom date range overlay and the custom graph overlay.
    @State private var showCustomDateRangeOverlay: Bool = false
    @State private var customGraphOverlay: Bool = false
    @State private var customStartDate: Date = Date()
    @State private var customEndDate: Date = Date()
    // NEW: For showing an alert if an invalid range is selected.
    @State private var showAlert: Bool = false
    @State private var alertMessage: String = ""

    // MARK: - Styling
    let backgroundBlack = Color.black
    let accentCyan = Color(red: 0, green: 1, blue: 1)
    let textFieldBackground = Color(red: 0.15, green: 0.15, blue: 0.15)

    // MARK: - Local Streak Tracking
    @State private var localStreaks: [String: Int] = [:]
    @State private var localLongestStreaks: [String: Int] = [:]

    // MARK: - Combine
    @State private var cancellables: Set<AnyCancellable> = []

    // MARK: - Time Range
    fileprivate enum TimeRange { case weekly, monthly }
    @State private var selectedTimeRange: TimeRange = .weekly
    @State private var weekOffset: Int = 0
    @State private var monthOffset: Int = 0
    @State private var showDateRangeOverlay: Bool = false

    // MARK: - Initialization
    init(habit: Binding<Habit>) {
        _habit = habit
        _editableTitle = State(initialValue: habit.wrappedValue.title)
        _editableDescription = State(initialValue: habit.wrappedValue.description)
        _goal = State(initialValue: habit.wrappedValue.goal)
    }

    // MARK: - Body
    var body: some View {
        ZStack {
            mainContent

            // Existing overlays.
            if showDateRangeOverlay {
                Color.white.opacity(0.9)
                    .ignoresSafeArea()
                dateRangeOverlayView
                    .transition(.scale)
            }
            if showMetricInput {
                metricInputOverlay
                    .transition(.opacity)
            }
            if showUnmarkConfirmation {
                unmarkConfirmationOverlay
                    .transition(.opacity)
            }
            // NEW: Custom Date Range Overlay.
            if showCustomDateRangeOverlay {
                customDateRangeOverlayView
                    .transition(.opacity)
            }
            if customGraphOverlay {
                customGraphView
                    .transition(.opacity)
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Invalid Date Range"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
        .banner(message: "Note Saved!", isPresented: $showBanner)
        .onAppear {
            guard let userId = session.current_user?.uid else { return }
            viewModel.fetchHabits(for: userId)
            viewModel.setupDefaultHabitsIfNeeded(for: userId)
            initializeLocalStreaks()
            goal = habit.goal
            viewModel.$habits
                .sink { _ in initializeLocalStreaks() }
                .store(in: &cancellables)
            fetchUserNotes()
        }
        .onDisappear { saveEditsToHabit() }
        .onChange(of: selectedHours) { _ in
            if !isTimerRunning && !isTimerPaused {
                countdownSeconds = selectedHours * 3600 + selectedMinutes * 60
            }
        }
        .onChange(of: selectedMinutes) { _ in
            if !isTimerRunning && !isTimerPaused {
                countdownSeconds = selectedHours * 3600 + selectedMinutes * 60
            }
        }
        .sheet(isPresented: $showPreviousNotes) {
            PreviousNotesView(habitID: habit.id ?? "")
        }
    }

    // MARK: - Main Content
    private var mainContent: some View {
        ZStack {
            backgroundBlack.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 15) {
                    topBarSection

                    TextEditor(text: $editableDescription)
                        .foregroundColor(.white.opacity(0.8))
                        .font(.subheadline)
                        .disableAutocorrection(true)
                        .scrollContentBackground(.hidden)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(8)
                        .frame(minHeight: 50)
                        .overlay(
                            Group {
                                if editableDescription.isEmpty {
                                    Text("Habit Description")
                                        .foregroundColor(.white.opacity(0.5))
                                        .padding(.horizontal, 15)
                                        .padding(.vertical, 2)
                                }
                            }, alignment: .topLeading
                        )

                    goalSection

                    // Updated Tab Picker with a small black divider.
                    VStack(spacing: 4) {
                        Picker("Tabs", selection: $selectedTabIndex) {
                            Text("Progress").tag(0)
                            Text("Focus Timer").tag(1)
                            Text("Notes").tag(2)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .tint(.gray)
                        .background(Color.gray)
                        .cornerRadius(8)
                        .padding(.horizontal, 10)
                        
                        // More visible black divider.
                        Rectangle()
                            .fill(Color.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 4)
                            .padding(.horizontal, 10)
                    }


                    Group {
                        switch selectedTabIndex {
                        case 0: progressTab
                        case 1: focusTab
                        default: notesTab
                        }
                    }
                    
                    Spacer()
                    
                    // Display metric info.
                    // Display metric info.
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Metric Category:")
                                .font(.caption)
                                .foregroundColor(.white)
                            Text(habit.metricCategory.rawValue)
                                .font(.caption)
                                .foregroundColor(accentCyan)
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Metric Type:")
                                .font(.caption)
                                .foregroundColor(.white)
                            let metricText: String = {
                                switch habit.metricType {
                                case .predefined(let value):
                                    return value
                                case .custom(let value):
                                    return value
                                }
                            }()
                            Text(metricText)
                                .font(.caption)
                                .foregroundColor(accentCyan)
                        }
                    }
                    .padding(.horizontal)
                    
                    // Mark/Unmark button.
                    Button {
                        if completedToday {
                            showUnmarkConfirmation = true
                        } else {
                            metricInput = ""
                            showMetricInput = true
                        }
                    } label: {
                        Text(completedToday ? "Unmark Habit as Done" : "Mark Habit as Done")
                            .foregroundColor(.black)
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(completedToday ? Color.red : accentCyan)
                            .cornerRadius(8)
                    }
                    .padding(.bottom, 30)


                }
                .padding()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Overlays

    // Metric Input Overlay (for marking as done)
    private var metricInputOverlay: some View {
        let prompt = metricPrompt()
        return VStack(spacing: 16) {
            Text(prompt)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
            TextField("Enter a number", text: $metricInput)
                .keyboardType(.numberPad)
                .padding()
                .background(Color.white.opacity(0.2))
                .cornerRadius(8)
                .foregroundColor(.white)
            if !metricInput.isEmpty {
                if habit.metricType.isCompletedMetric() {
                    if metricInput != "0" && metricInput != "1" {
                        Text("Please enter either 0 (No) or 1 (Yes)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } else if Int(metricInput) == nil {
                    Text("Please enter a valid number")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            HStack {
                Button("Cancel") {
                    withAnimation { showMetricInput = false }
                }
                .foregroundColor(.red)
                Spacer()
                Button("Save") {
                    if let metricValue = Int(metricInput) {
                        completeHabit(with: metricValue)
                        withAnimation { showMetricInput = false }
                    }
                }
                .disabled({
                    if habit.metricType.isCompletedMetric() {
                        return !(metricInput == "0" || metricInput == "1")
                    } else {
                        return Int(metricInput) == nil
                    }
                }())
                .foregroundColor(.green)
            }
        }
        .padding()
        .frame(width: 300)
        .background(Color.black.opacity(0.9))
        .cornerRadius(12)
        .shadow(radius: 8)
    }

    // Unmark Confirmation Overlay.
    private var unmarkConfirmationOverlay: some View {
        VStack(spacing: 16) {
            Text("Are you sure you want to unmark this habit as done?")
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
            HStack {
                Button("Cancel") {
                    withAnimation { showUnmarkConfirmation = false }
                }
                .foregroundColor(.red)
                Spacer()
                Button("Ok") {
                    toggleHabitDone()
                    withAnimation { showUnmarkConfirmation = false }
                }
                .foregroundColor(.green)
            }
        }
        .padding()
        .frame(width: 300)
        .background(Color.black.opacity(0.9))
        .cornerRadius(12)
        .shadow(radius: 8)
    }

    // NEW: Custom Date Range Overlay.
    private var customDateRangeOverlayView: some View {
        VStack(spacing: 16) {
            Text("Custom Date Range")
                .font(.title3.weight(.semibold))
                .foregroundColor(.white)
            // Use the custom calendar view instead of standard DatePickers.
            CustomCalendarView(month: Date(), minDate: habit.startDate, maxDate: Date(), startDate: $customStartDate, endDate: $customEndDate, accentColor: accentCyan)
                .frame(height: 300)
                .padding(.horizontal)
            HStack(spacing: 20) {
                Button("Show Graph") {
                    // Validate that the selected range is within allowed dates.
                    if customStartDate < habit.startDate || customEndDate > Date() {
                        alertMessage = "Please select dates between \(formattedDate(habit.startDate)) and today."
                        showAlert = true
                    } else {
                        withAnimation {
                            showCustomDateRangeOverlay = false
                            customGraphOverlay = true
                        }
                    }
                }
                .foregroundColor(.black)
                .padding()
                .background(Color.white)
                .cornerRadius(8)
                Button("Cancel") {
                    withAnimation { showCustomDateRangeOverlay = false }
                }
                .foregroundColor(.red)
            }
        }
        .padding()
        .frame(width: 350, height: 500)
        .background(Color.black) // Fully black background.
        .cornerRadius(12)
        .shadow(radius: 10)
    }

    // NEW: Custom Graph Overlay view.
    private var customGraphView: some View {
        let customData = getCustomGraphData()
        return VStack(spacing: 16) {
            Text("Graph from \(formattedDate(customStartDate)) to \(formattedDate(customEndDate))")
                .font(.headline)
                .foregroundColor(.white)
            SingleLineGraphView(
                timeRange: .weekly,
                dates: customData.labels,
                intensities: customData.intensities,
                accentColor: .white // Graph line in white.
            )
            .frame(minHeight: 300)
            .background(Color.black)
            .cornerRadius(8)
            Button("Done") {
                withAnimation { customGraphOverlay = false }
            }
            .foregroundColor(.black)
            .padding()
            .background(Color.white)
            .cornerRadius(8)
        }
        .padding()
        .background(Color.black)
        .cornerRadius(12)
        .shadow(radius: 10)
    }

    // NEW: Helper to generate custom graph data by iterating through every day in the range.
    private func getCustomGraphData() -> (labels: [String], intensities: [CGFloat?]) {
        let calendar = Calendar.current
        var labels: [String] = []
        var intensities: [CGFloat?] = []
        var date = calendar.startOfDay(for: customStartDate)
        let endDate = calendar.startOfDay(for: customEndDate)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        while date <= endDate {
            labels.append(formatter.string(from: date))
            if let record = habit.dailyRecords.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
                intensities.append(CGFloat(record.value ?? 0))
            } else {
                intensities.append(0)
            }
            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = nextDate
        }
        return (labels, intensities)
    }

    // NEW: Helper to format a Date.
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    // MARK: - Helper for Dynamic Prompt (for metric input)
    private func metricPrompt() -> String {
        switch habit.metricType {
        case .predefined(let value):
            if value.lowercased().contains("minute") {
                return "How many minutes did you meditate today?"
            } else if value.lowercased().contains("miles") {
                return "How many miles did you run today?"
            } else if value.lowercased().contains("pages") {
                return "How many pages did you read today?"
            } else if value.lowercased().contains("reps") {
                return "How many reps did you complete today?"
            } else if value.lowercased().contains("steps") {
                return "How many steps did you take today?"
            } else if value.lowercased().contains("calories") {
                return "How many calories did you burn/consume today?"
            } else if value.lowercased().contains("hours") {
                return "How many hours did you sleep today?"
            } else if value.lowercased().contains("completed") {
                return "Were you able to complete the task? (Enter 1 for Yes, 0 for No)"
            } else {
                return "Enter today's \(value.lowercased()) value:"
            }
        case .custom(let customValue):
            return "Enter today's \(customValue.lowercased()) value:"
        }
    }

    // MARK: - Complete Habit With Metric
    private func completeHabit(with metricValue: Int) {
        let newRecord = HabitRecord(date: Date(), value: Double(metricValue))
        var updatedHabit = habit
        let calendar = Calendar.current
        let today = Date()
        let alreadyCompleted = updatedHabit.dailyRecords.contains { record in
            calendar.isDate(record.date, inSameDayAs: today) && ((record.value ?? 0) > 0)
        }
        
        updatedHabit.dailyRecords.append(newRecord)
        
        if !alreadyCompleted {
            updatedHabit.currentStreak += 1
            if updatedHabit.currentStreak > updatedHabit.longestStreak {
                updatedHabit.longestStreak = updatedHabit.currentStreak
            }
        }
        
        viewModel.updateHabit(updatedHabit)
        habit = updatedHabit
    }


    // MARK: - Date Range Overlay (Existing Code)
    @ViewBuilder
    private var dateRangeOverlayView: some View {
        VStack(spacing: 0) {
            Text(selectedTimeRange == .weekly ? "Select a Week" : "Select a Month")
                .font(.title3.weight(.semibold))
                .padding()
                .foregroundColor(.black)
            Divider()
            if selectedTimeRange == .weekly {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(realWeeks(), id: \.self) { interval in
                            let label = formatWeekInterval(interval)
                            Button {
                                weekOffset = computeWeekOffset(for: interval)
                                showDateRangeOverlay = false
                            } label: {
                                Text(label)
                                    .font(.callout)
                                    .foregroundColor(.black)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(realMonths(), id: \.self) { monthDate in
                            let label = formatMonth(monthDate)
                            Button {
                                monthOffset = computeMonthOffset(for: monthDate)
                                showDateRangeOverlay = false
                            } label: {
                                Text(label)
                                    .font(.callout)
                                    .foregroundColor(.black)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                }
            }
            Divider()
            // NEW: Custom Range button.
            Button {
                withAnimation { showCustomDateRangeOverlay = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.callout)
                    Text("Custom Range")
                        .font(.callout)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundColor(.black)
                .background(accentCyan)
                .cornerRadius(6)
            }
            Divider()
            Button("Cancel") {
                showDateRangeOverlay = false
            }
            .font(.callout.weight(.semibold))
            .foregroundColor(.blue)
            .padding(.vertical, 12)
        }
        .background(Color.white.cornerRadius(12))
        .frame(width: 300, height: 400)
        .shadow(color: .gray.opacity(0.3), radius: 10)
    }
}

// MARK: - CustomCalendarView
/// A custom calendar view that displays all days of the current month with navigation controls,
/// highlights dates between the selected start and end dates, and greys out dates that are not selectable.
struct CustomCalendarView: View {
    @State private var currentMonth: Date
    let minDate: Date
    let maxDate: Date
    @Binding var startDate: Date
    @Binding var endDate: Date
    let accentColor: Color

    private let columns = Array(repeating: GridItem(.flexible()), count: 7)
    
    init(month: Date, minDate: Date, maxDate: Date, startDate: Binding<Date>, endDate: Binding<Date>, accentColor: Color) {
        self._currentMonth = State(initialValue: month)
        self.minDate = minDate
        self.maxDate = maxDate
        self._startDate = startDate
        self._endDate = endDate
        self.accentColor = accentColor
    }
    
    var body: some View {
        VStack {
            // Header with month navigation.
            HStack {
                Button(action: {
                    if let prevMonth = Calendar.current.date(byAdding: .month, value: -1, to: currentMonth) {
                        currentMonth = prevMonth
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.white)
                }
                Spacer()
                Text(monthYearString(from: currentMonth))
                    .foregroundColor(.white)
                    .font(.headline)
                Spacer()
                Button(action: {
                    if let nextMonth = Calendar.current.date(byAdding: .month, value: 1, to: currentMonth) {
                        currentMonth = nextMonth
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal)
            
            // Calendar grid
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(generateDays(for: currentMonth), id: \.self) { day in
                    let isSelectable = day >= minDate && day <= maxDate
                    Text(dayString(from: day))
                        .font(.caption)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .foregroundColor(isSelectable ? .white : .gray)
                        .background(background(for: day))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .onTapGesture {
                            if isSelectable {
                                select(day: day)
                            }
                        }
                }
            }
            .padding(.horizontal)
        }
    }
    
    private func monthYearString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
    
    private func dayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }
    
    private func background(for date: Date) -> Color {
        // Highlight if the date falls between the selected start and end dates.
        if date >= startDate && date <= endDate {
            return accentColor.opacity(0.5)
        } else if Calendar.current.isDate(date, inSameDayAs: startDate) || Calendar.current.isDate(date, inSameDayAs: endDate) {
            return accentColor
        } else {
            return Color.clear
        }
    }
    
    private func select(day: Date) {
        // Update the selected dates based on the tap.
        if day < startDate {
            startDate = day
        } else if day > endDate {
            endDate = day
        } else {
            // If tapped within the range, choose the closer boundary to update.
            let diffToStart = abs(Calendar.current.dateComponents([.day], from: startDate, to: day).day ?? 0)
            let diffToEnd = abs(Calendar.current.dateComponents([.day], from: day, to: endDate).day ?? 0)
            if diffToStart < diffToEnd {
                startDate = day
            } else {
                endDate = day
            }
        }
    }
    
    private func generateDays(for month: Date) -> [Date] {
        var dates: [Date] = []
        let calendar = Calendar.current
        guard let monthInterval = calendar.dateInterval(of: .month, for: month) else { return dates }
        var date = calendar.startOfDay(for: monthInterval.start)
        while date < monthInterval.end {
            dates.append(date)
            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = nextDate
        }
        return dates
    }
}

// MARK: - Subviews & Helpers (unchanged)
extension HabitDetailView {
    private var topBarSection: some View {
        HStack {
            Button {
                presentationMode.wrappedValue.dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .foregroundColor(accentCyan)
                    .font(.title2)
            }
            Spacer()
            TextField("Habit Title", text: $editableTitle)
                .multilineTextAlignment(.center)
                .font(.title2.weight(.bold))
                .foregroundColor(.white)
                .frame(maxWidth: 200)
                .disableAutocorrection(true)
            Spacer()
            Spacer().frame(width: 40)
        }
    }
    
    private var completedToday: Bool {
        let calendar = Calendar.current
        return habit.dailyRecords.contains { record in
            calendar.isDate(record.date, inSameDayAs: Date()) && ((record.value ?? 0) > 0)
        }
    }
    
    private var goalSection: some View {
        VStack() {
            Text("Goal Related to Habit:")
                .foregroundColor(accentCyan)
                .font(.headline)
            ZStack(alignment: .topLeading) {
                if goal.isEmpty {
                    Text("e.g. Read 50 books by the end of the year")
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                }
                TextEditor(text: $goal)
                    .foregroundColor(.white)
                    .accentColor(accentCyan)
                    .padding(8)
                    .background(textFieldBackground)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(accentCyan.opacity(0.6), lineWidth: 1)
                    )
                    .frame(minHeight: 100, maxHeight: .infinity)
                    .scrollContentBackground(.hidden)
            }
        }
    }
    
    private var focusTab: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(accentCyan.opacity(0.2), lineWidth: 10)
                    .frame(width: 180, height: 180)
                    .shadow(color: accentCyan.opacity(0.4), radius: 5)
                Text(formatTime(countdownSeconds))
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
            }
            if !isTimerRunning && !isTimerPaused {
                HStack(spacing: 20) {
                    timePickerBlock(label: "HRS", range: 0..<24, selection: $selectedHours)
                    timePickerBlock(label: "MIN", range: 0..<60, selection: $selectedMinutes)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(accentCyan.opacity(0.4), lineWidth: 1)
                        )
                        .shadow(color: accentCyan.opacity(0.3), radius: 5)
                )
            }
            HStack(spacing: 20) {
                if !isTimerRunning && !isTimerPaused {
                    Button("Start") {
                        if countdownSeconds == 0 {
                            countdownSeconds = selectedHours * 3600 + selectedMinutes * 60
                        }
                        startTimer()
                    }
                    .buttonStyle(HolographicButtonStyle())
                } else if isTimerRunning && !isTimerPaused {
                    Button("Pause") { pauseTimer() }
                        .buttonStyle(HolographicButtonStyle())
                    Button("Reset") { resetTimer() }
                        .buttonStyle(HolographicButtonStyle())
                } else if isTimerPaused {
                    Button("Resume") { startTimer() }
                        .buttonStyle(HolographicButtonStyle())
                    Button("Reset") { resetTimer() }
                        .buttonStyle(HolographicButtonStyle())
                }
            }
            HStack {
                Text("Focused: \(formatTime(totalFocusTime))")
                    .foregroundColor(.white)
            }
        }
    }
    
    private func timePickerBlock(label: String, range: Range<Int>, selection: Binding<Int>) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .foregroundColor(accentCyan)
                .font(.subheadline)
            Picker(label, selection: selection) {
                ForEach(range, id: \.self) { value in
                    Text("\(value)")
                        .font(.title3.monospacedDigit())
                        .foregroundColor(.white)
                }
            }
            .labelsHidden()
            .frame(width: 45, height: 80)
            .pickerStyle(WheelPickerStyle())
        }
    }
    
    private func navigationButtonLabel(title: String, isDisabled: Bool) -> some View {
        Text(title)
            .multilineTextAlignment(.center)
            .foregroundColor(isDisabled ? Color.gray : accentCyan)
            .fixedSize(horizontal: false, vertical: true)
    }
    
    private var progressTab: some View {
        let userCreationDate = session.userModel?.createdAt ?? habit.startDate
        return VStack(spacing: 20) {
            if selectedTimeRange == .weekly {
                Text("Current Week: \(formatWeekInterval(currentWeekInterval(offset: weekOffset)))")
                    .foregroundColor(.white)
                    .font(.headline)
            } else {
                Text("Current Month: \(formatMonth(currentMonthDate(offset: monthOffset)))")
                    .foregroundColor(.white)
                    .font(.headline)
            }
            Picker("Time Range", selection: $selectedTimeRange) {
                Text("Weekly").tag(TimeRange.weekly)
                Text("Monthly").tag(TimeRange.monthly)
            }
            .pickerStyle(SegmentedPickerStyle())
            .tint(.gray)
            .background(.gray)
            .cornerRadius(8)
            .padding(.horizontal, 10)
            if selectedTimeRange == .weekly {
                let (weekLabels, weekValues) = weeklyData(habit: habit, offset: weekOffset, userCreationDate: userCreationDate)
                SingleLineGraphView(
                    timeRange: .weekly,
                    dates: weekLabels,
                    intensities: weekValues,
                    accentColor: accentCyan
                )
                .frame(maxWidth: .infinity, minHeight: 300)
                .background(accentCyan.opacity(0.15))
                .cornerRadius(8)
                .padding(.horizontal, 12)
                HStack(spacing: 20) {
                    Button {
                        if weekOffset > minWeekOffset {
                            weekOffset -= 1
                        }
                    } label: {
                        navigationButtonLabel(title: "Prev\nWeek", isDisabled: weekOffset <= minWeekOffset)
                    }
                    .disabled(weekOffset <= minWeekOffset)
                    Button {
                        showDateRangeOverlay = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                                .font(.callout)
                            Text("Choose Week")
                                .font(.callout)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundColor(.black)
                        .background(accentCyan)
                        .cornerRadius(6)
                    }
                    // NEW: Custom Range button.
                    Button {
                        withAnimation { showCustomDateRangeOverlay = true }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar.badge.plus")
                                .font(.callout)
                            Text("Custom Range")
                                .font(.callout)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundColor(.black)
                        .background(accentCyan)
                        .cornerRadius(6)
                    }
                    Button {
                        if weekOffset < maxWeekOffset {
                            weekOffset += 1
                        }
                    } label: {
                        navigationButtonLabel(title: "Next\nWeek", isDisabled: weekOffset >= maxWeekOffset)
                    }
                    .disabled(weekOffset >= maxWeekOffset)
                }
                .padding(.top, 10)
            } else {
                MonthlyCurrentMonthGridView(
                    accentColor: accentCyan,
                    offset: monthOffset,
                    dailyRecords: habit.dailyRecords,
                    userCreationDate: userCreationDate
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                HStack(spacing: 20) {
                    Button {
                        if monthOffset > minMonthOffset {
                            monthOffset -= 1
                        }
                    } label: {
                        navigationButtonLabel(title: "Prev\nMonth", isDisabled: monthOffset <= minMonthOffset)
                    }
                    .disabled(monthOffset <= minMonthOffset)
                    Button {
                        showDateRangeOverlay = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                                .font(.callout)
                            Text("Choose Month")
                                .font(.callout)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundColor(.black)
                        .background(accentCyan)
                        .cornerRadius(6)
                    }
                    Button {
                        if monthOffset < maxMonthOffset {
                            monthOffset += 1
                        }
                    } label: {
                        navigationButtonLabel(title: "Next\nMonth", isDisabled: monthOffset >= maxMonthOffset)
                    }
                    .disabled(monthOffset >= maxMonthOffset)
                }
                .padding(.top, 10)
            }
        }
        .padding(.top, 10)
    }
    
    private func weeklyData(habit: Habit, offset: Int, userCreationDate: Date) -> ([String], [CGFloat?]) {
        let dayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var intensities: [CGFloat?] = Array(repeating: nil, count: 7)
        let calendar = Calendar.current
        let now = Date()
        let weekday = calendar.component(.weekday, from: now)
        let distanceFromSunday = weekday - 1
        guard let startOfThisWeek = calendar.date(byAdding: .day, value: -distanceFromSunday + (offset * 7), to: now) else {
            return (dayLabels, intensities)
        }
        for i in 0..<7 {
            guard let dayDate = calendar.date(byAdding: .day, value: i, to: startOfThisWeek) else { continue }
            if dayDate < userCreationDate || dayDate > now {
                intensities[i] = nil
                continue
            }
            if let record = habit.dailyRecords.first(where: { rec in
                calendar.isDate(rec.date, inSameDayAs: dayDate)
            }) {
                intensities[i] = record.value ?? 0
            } else {
                intensities[i] = 0
            }
        }
        return (dayLabels, intensities)
    }
}

// MARK: - Real Weeks/Months Helpers
extension HabitDetailView {
    private func realWeeks() -> [DateInterval] {
        let calendar = Calendar.current
        var results: [DateInterval] = []
        let now = Date()
        let weekday = calendar.component(.weekday, from: now)
        let distanceFromSunday = weekday - 1
        guard let startOfThisWeek = calendar.date(byAdding: .day, value: -distanceFromSunday, to: now) else {
            return results
        }
        for offset in minWeekOffset...maxWeekOffset {
            if let start = calendar.date(byAdding: .day, value: offset * 7, to: startOfThisWeek),
               let end = calendar.date(byAdding: .day, value: 6, to: start) {
                results.append(DateInterval(start: start, end: end))
            }
        }
        results.sort { $0.start < $1.start }
        return results
    }
    
    private func formatWeekInterval(_ interval: DateInterval) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        let startStr = fmt.string(from: interval.start)
        let endStr = fmt.string(from: interval.end)
        return "\(startStr) - \(endStr)"
    }
    
    private func computeWeekOffset(for interval: DateInterval) -> Int {
        let calendar = Calendar.current
        let now = Date()
        let weekday = calendar.component(.weekday, from: now)
        let distanceFromSunday = weekday - 1
        guard let startOfThisWeek = calendar.date(byAdding: .day, value: -distanceFromSunday, to: now) else {
            return 0
        }
        let comps = calendar.dateComponents([.day], from: startOfThisWeek, to: interval.start)
        let dayDiff = comps.day ?? 0
        return dayDiff / 7
    }
    
    private func realMonths() -> [Date] {
        let calendar = Calendar.current
        let now = Date()
        var months: [Date] = []
        for offset in minMonthOffset...maxMonthOffset {
            if let shifted = calendar.date(byAdding: .month, value: offset, to: now) {
                months.append(shifted)
            }
        }
        return months.sorted()
    }
    
    private func formatMonth(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "LLLL yyyy"
        return fmt.string(from: date)
    }
    
    private func computeMonthOffset(for date: Date) -> Int {
        let calendar = Calendar.current
        let now = Date()
        let comps = calendar.dateComponents([.month], from: startOfMonth(now), to: startOfMonth(date))
        return comps.month ?? 0
    }
    
    private func startOfMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }
    
    private func currentWeekInterval(offset: Int) -> DateInterval {
        let calendar = Calendar.current
        let now = Date()
        let weekday = calendar.component(.weekday, from: now)
        let distanceFromSunday = weekday - 1
        guard let startOfThisWeek = calendar.date(byAdding: .day, value: -distanceFromSunday + (offset * 7), to: now),
              let end = calendar.date(byAdding: .day, value: 6, to: startOfThisWeek)
        else {
            return DateInterval(start: now, end: now)
        }
        return DateInterval(start: startOfThisWeek, end: end)
    }
    
    private func currentMonthDate(offset: Int) -> Date {
        let calendar = Calendar.current
        let now = Date()
        return calendar.date(byAdding: .month, value: offset, to: now) ?? now
    }
}

// MARK: - Notes Tab
extension HabitDetailView {
    private var notesTab: some View {
        VStack(spacing: 16) {
            Text("Session Notes")
                .font(.headline)
                .foregroundColor(accentCyan)
            TextEditor(text: $sessionNotes)
                .foregroundColor(.white)
                .background(textFieldBackground)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(accentCyan.opacity(0.6), lineWidth: 1)
                )
                .frame(minHeight: 150)
                .padding(.horizontal, 4)
                .scrollContentBackground(.hidden)
            Button("Save Note") {
                saveNote()
            }
            .foregroundColor(.black)
            .padding()
            .background(accentCyan)
            .cornerRadius(8)
            Button("View Previous Notes") {
                showPreviousNotes = true
            }
            .foregroundColor(.black)
            .padding()
            .background(Color.white)
            .cornerRadius(8)
        }
    }
    
    private func saveNote() {
        guard !sessionNotes.isEmpty, let habitID = habit.id else { return }
        viewModel.saveUserNote(for: habitID, note: sessionNotes) { success in
            if success {
                DispatchQueue.main.async {
                    sessionNotes = ""
                    showBanner = true
                    fetchUserNotes()
                }
            } else {
                print("Failed to save note for habitID: \(habitID)")
            }
        }
    }
    
    private func fetchUserNotes() {
        guard let habitID = habit.id else { return }
        let db = Firestore.firestore()
        db.collection("UserNotes")
            .whereField("habitID", isEqualTo: habitID)
            .order(by: "timestamp", descending: true)
            .getDocuments { snapshot, error in
                if let error = error {
                    print("Error fetching notes: \(error.localizedDescription)")
                    return
                }
                guard let documents = snapshot?.documents else { return }
                let notes: [UserNote] = documents.compactMap { doc in
                    return try? doc.data(as: UserNote.self)
                }
                DispatchQueue.main.async {
                    self.pastSessionNotes = notes
                }
            }
    }
    
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func deleteNote(_ note: UserNote) {
        viewModel.deleteUserNote(note: note) { success in
            if success {
                fetchUserNotes()
            } else {
                print("Failed to delete note with id: \(note.id ?? "unknown")")
            }
        }
    }
}

// MARK: - Timer & Habit Edits
extension HabitDetailView {
    private func startTimer() {
        guard !isTimerRunning || isTimerPaused else { return }
        isTimerRunning = true
        isTimerPaused = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if countdownSeconds > 0 {
                countdownSeconds -= 1
                totalFocusTime += 1
            } else {
                timer?.invalidate()
                isTimerRunning = false
            }
        }
    }
    
    private func pauseTimer() {
        guard isTimerRunning && !isTimerPaused else { return }
        isTimerPaused = true
        timer?.invalidate()
    }
    
    private func resetTimer() {
        timer?.invalidate()
        countdownSeconds = 0
        isTimerRunning = false
        isTimerPaused = false
        selectedHours = 0
        selectedMinutes = 0
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    private func toggleHabitDone() {
        let calendar = Calendar.current
        var updatedHabit = habit
        // Determine if the habit is marked as done for today by checking dailyRecords.
        let isCompletedToday = updatedHabit.dailyRecords.contains { record in
            calendar.isDate(record.date, inSameDayAs: Date()) && ((record.value ?? 0) > 0)
        }
        
        if isCompletedToday {
            // Unmark the habit: Remove all records for today.
            updatedHabit.dailyRecords.removeAll { record in
                calendar.isDate(record.date, inSameDayAs: Date())
            }
            // Update local streak by decrementing.
            if let habitID = habit.id {
                let localVal = localStreaks[habitID] ?? habit.currentStreak
                localStreaks[habitID] = max(localVal - 1, 0)
            }
        } else {
            // Mark the habit as done: Append a new record with a default value of 1.
            let newRecord = HabitRecord(date: Date(), value: 1)
            updatedHabit.dailyRecords.append(newRecord)
            // Update local streak by incrementing.
            if let habitID = habit.id {
                let localVal = localStreaks[habitID] ?? habit.currentStreak
                localStreaks[habitID] = localVal + 1
            }
        }
        
        viewModel.updateHabit(updatedHabit)
        habit = updatedHabit
    }

    
    private func saveEditsToHabit() {
        guard editableTitle != habit.title ||
              editableDescription != habit.description ||
              goal != habit.goal else { return }
        habit.title = editableTitle
        habit.description = editableDescription
        habit.goal = goal
        viewModel.updateHabit(habit)
    }
}

// MARK: - Local Streak Initialization
extension HabitDetailView {
    private func initializeLocalStreaks() {
        guard let habitID = habit.id else { return }
        if let lastReset = habit.lastReset, Calendar.current.isDateInToday(lastReset) {
            // same day, do nothing
        } else {
            localStreaks[habitID] = max(localStreaks[habitID] ?? 0, habit.currentStreak)
        }
        localLongestStreaks[habitID] = max(localLongestStreaks[habitID] ?? 0, habit.longestStreak)
    }
}

// MARK: - Offset Calculations
extension HabitDetailView {
    private var minWeekOffset: Int {
        let calendar = Calendar.current
        let now = Date()
        guard let accountWeekStart = calendar.dateInterval(of: .weekOfYear, for: session.userModel?.createdAt ?? now)?.start,
              let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return 0
        }
        let weeks = calendar.dateComponents([.weekOfYear], from: accountWeekStart, to: currentWeekStart).weekOfYear ?? 0
        return -weeks
    }
    
    private var maxWeekOffset: Int { 0 }
    private var minMonthOffset: Int {
        let calendar = Calendar.current
        let now = Date()
        guard let accountMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: session.userModel?.createdAt ?? now)),
              let currentMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) else {
            return 0
        }
        let months = calendar.dateComponents([.month], from: accountMonthStart, to: currentMonthStart).month ?? 0
        return -months
    }
    private var maxMonthOffset: Int { 0 }
}

// MARK: - SingleLineGraphView
fileprivate struct SingleLineGraphView: View {
    let timeRange: HabitDetailView.TimeRange
    let dates: [String]
    let intensities: [CGFloat?]  // Days with no data (e.g. future days) are nil.
    let accentColor: Color

    var body: some View {
        let computedMax = intensities.compactMap { $0 }.max() ?? 0
        let maxValue = max(computedMax, 1)
        let gridLines: [CGFloat] = (maxValue == 1)
            ? [0, 1]
            : Array(stride(from: 0, through: maxValue, by: maxValue / 5))
        let topPadding: CGFloat = 20
        let desiredHeight: CGFloat = (maxValue == 1)
            ? 150
            : min(max(250, maxValue * 30), 400)

        return GeometryReader { geo in
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 20, y: topPadding))
                    p.addLine(to: CGPoint(x: 20, y: geo.size.height))
                }
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                
                ForEach(gridLines.indices, id: \.self) { index in
                    let value = gridLines[index]
                    let y = yPosition(for: value, in: geo.size.height, maxValue: maxValue, topPadding: topPadding)
                    Path { path in
                        path.move(to: CGPoint(x: 20, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    Text("\(Int(value))")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .position(x: 10, y: y)
                }
                
                ConnectedLineShape(values: intensities, maxValue: maxValue, axisPadding: 20, topPadding: topPadding)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                
                ForEach(intensities.indices, id: \.self) { i in
                    if let value = intensities[i] {
                        let x = xPosition(for: i, totalWidth: geo.size.width, axisPadding: 20)
                        let y = yPosition(for: value, in: geo.size.height, maxValue: maxValue, topPadding: topPadding)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 6, height: 6)
                            .position(x: x, y: y)
                        let labelY = max(y - 30, topPadding + 15)
                        Text("\(Int(value))")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .position(x: x, y: labelY)
                    }
                    if i < dates.count {
                        let x = xPosition(for: i, totalWidth: geo.size.width, axisPadding: 20)
                        Text(dates[i])
                            .font(.caption2)
                            .foregroundColor(.white)
                            .frame(width: 30, alignment: .center)
                            .position(x: x, y: geo.size.height - 10)
                    }
                }
            }
        }
        .frame(minHeight: desiredHeight)
        .padding()
    }
    
    private func xPosition(for index: Int, totalWidth: CGFloat, axisPadding: CGFloat) -> CGFloat {
        guard intensities.count > 1 else {
            return axisPadding + totalWidth / 2
        }
        let usableWidth = totalWidth - axisPadding
        let step = usableWidth / CGFloat(intensities.count - 1)
        return axisPadding + CGFloat(index) * step
    }
    
    private func yPosition(for value: CGFloat, in height: CGFloat, maxValue: CGFloat, topPadding: CGFloat) -> CGFloat {
        let availableHeight = height - topPadding
        let ratio = value / maxValue
        return height - (ratio * availableHeight)
    }
}

// MARK: - ConnectedLineShape
fileprivate struct ConnectedLineShape: Shape {
    let values: [CGFloat?]
    let maxValue: CGFloat
    let axisPadding: CGFloat
    let topPadding: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = values.count
        let width = rect.width - axisPadding
        let step = width / CGFloat(max(count - 1, 1))
        var previousPoint: CGPoint? = nil
        
        for i in 0..<count {
            let x = axisPadding + CGFloat(i) * step
            guard let value = values[i] else {
                previousPoint = nil
                continue
            }
            let availableHeight = rect.height - topPadding
            let y = rect.height - (value / maxValue * availableHeight)
            let currentPoint = CGPoint(x: x, y: y)
            if let previous = previousPoint {
                path.addLine(to: currentPoint)
            } else {
                path.move(to: currentPoint)
            }
            previousPoint = currentPoint
        }
        return path
    }
}

// MARK: - PreviousNotesView
fileprivate struct PreviousNotesView: View {
    let habitID: String
    @EnvironmentObject var viewModel: HabitViewModel
    @State private var notes: [UserNote] = []
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            List {
                ForEach(notes) { note in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(note.noteText)
                                .font(.body)
                                .foregroundColor(.primary)
                            Text(formatTimestamp(note.timestamp))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: {
                            viewModel.deleteUserNote(note: note) { success in
                                if success {
                                    fetchNotes()
                                } else {
                                    print("Failed to delete note with id: \(note.id ?? "unknown")")
                                }
                            }
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Previous Notes")
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
            .onAppear(perform: fetchNotes)
        }
    }
    
    private func fetchNotes() {
        let db = Firestore.firestore()
        db.collection("UserNotes")
            .whereField("habitID", isEqualTo: habitID)
            .order(by: "timestamp", descending: true)
            .getDocuments { snapshot, error in
                if let error = error {
                    print("Error fetching notes: \(error.localizedDescription)")
                    return
                }
                guard let documents = snapshot?.documents else { return }
                let fetchedNotes: [UserNote] = documents.compactMap { doc in
                    return try? doc.data(as: UserNote.self)
                }
                DispatchQueue.main.async {
                    self.notes = fetchedNotes
                }
            }
    }
    
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium  // e.g., "Mar 14, 2025"
        formatter.timeStyle = .short   // e.g., "2:45 PM"
        return formatter.string(from: date)
    }
}

// MARK: - HolographicButtonStyle
fileprivate struct HolographicButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.cyan, lineWidth: 1)
                    .shadow(color: .cyan, radius: configuration.isPressed ? 1 : 3)
                    .blendMode(.plusLighter)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut, value: configuration.isPressed)
    }
}

// MARK: - MonthlyCurrentMonthGridView
fileprivate struct MonthlyCurrentMonthGridView: View {
    let accentColor: Color
    let offset: Int
    let dailyRecords: [HabitRecord]
    let userCreationDate: Date

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(monthDayData(offset: offset), id: \.self) { item in
                    VStack(spacing: 4) {
                        Text(item.dayLabel)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.8))
                        if let intensity = item.intensity, intensity > 0 {
                            Image(systemName: "star.fill")
                                .foregroundColor(accentColor)
                                .font(.caption)
                        } else if item.intensity == nil {
                            Image(systemName: "star")
                                .foregroundColor(.gray)
                                .font(.caption)
                        } else {
                            Image(systemName: "star")
                                .foregroundColor(.gray)
                                .font(.caption)
                        }
                    }
                    .frame(minHeight: 40)
                }
            }
            .padding()
        }
        .padding()
        .background(accentColor.opacity(0.15))
        .cornerRadius(8)
    }
    
    private func monthDayData(offset: Int) -> [DayData] {
        let calendar = Calendar.current
        let now = Date()
        guard let baseDate = calendar.date(byAdding: .month, value: offset, to: now),
              let range = calendar.range(of: .day, in: .month, for: baseDate),
              let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: baseDate))
        else {
            return []
        }
        let daysInMonth = range.count
        var results: [DayData] = []
        for dayNum in 1...daysInMonth {
            guard let dayDate = calendar.date(byAdding: .day, value: dayNum - 1, to: startOfMonth) else { continue }
            if dayDate < userCreationDate {
                results.append(DayData(date: dayDate, dayLabel: "\(dayNum)", intensity: nil))
                continue
            }
            if dayDate > now {
                results.append(DayData(date: dayDate, dayLabel: "\(dayNum)", intensity: nil))
                continue
            }
            let record = dailyRecords.first(where: { calendar.isDate($0.date, inSameDayAs: dayDate) })
            let intensity: CGFloat? = record?.value.map { CGFloat($0) }
            results.append(DayData(date: dayDate, dayLabel: "\(dayNum)", intensity: intensity))
        }
        return results
    }
}

struct DayData: Hashable {
    let date: Date
    let dayLabel: String
    let intensity: CGFloat?
}
