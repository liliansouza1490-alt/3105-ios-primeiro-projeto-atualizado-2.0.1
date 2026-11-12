import SwiftUI
import UIKit
import AVFAudio

struct CalculadoraIPhoneView: View {
    let onContinue: () -> Void

    @State private var display = "0"
    @State private var storedValue = 0.0
    @State private var currentOperation: CalculatorOperation?
    @State private var waitingForInput = false
    @State private var showHistory = false
    @State private var showModeMenu = false
    @State private var showNotesAlert = false
    @State private var mode: CalculatorMode = .basic
    @State private var secondFunctions = false
    @State private var degreesMode = false
    @State private var memoryValue = 0.0
    @State private var showingEURFirst = false
    @StateObject private var entryTriggerMonitor = CalculatorEntryTriggerMonitor()

    private let numberColor = Color(red: 0.20, green: 0.20, blue: 0.20)
    private let functionColor = Color(red: 0.64, green: 0.64, blue: 0.64)
    private let operatorColor = Color(red: 1.0, green: 0.584, blue: 0.0)

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 18)
                        .padding(.top, 4)

                    Spacer(minLength: mode == .basic ? 32 : 18)

                    if mode == .conversion {
                        conversionDisplay
                            .padding(.horizontal, 18)
                            .padding(.bottom, 10)
                    } else {
                        mainDisplay
                            .padding(.horizontal, 28)
                            .padding(.bottom, mode == .basic ? 14 : 8)
                    }

                    if mode == .scientific || mode == .conversion {
                        scientificKeypad(availableWidth: geometry.size.width)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }

                    basicKeypad(keyHeight: mode == .basic ? 86 : 48)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }

            if showModeMenu {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeOut(duration: 0.16)) { showModeMenu = false } }
                    .zIndex(1)

                modeMenu
                    .padding(.trailing, 16)
                    .padding(.top, 42)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .zIndex(2)
                    .transition(.asymmetric(insertion: .scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity), removal: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showHistory) {
            historySheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Notas de Cálculo Indisponíveis", isPresented: $showNotesAlert) {
            Button("Cancelar", role: .cancel) { }
            Button("Instalar") {
                if let url = URL(string: "https://apps.apple.com/search?term=Notas") {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text("Instale o app Notas para usar este modo.")
        }
        .onAppear { entryTriggerMonitor.start(onEnter: onContinue) }
        .onDisappear { entryTriggerMonitor.stop() }
    }

    private var topBar: some View {
        HStack {
            glassIcon("clock", accessibility: "Histórico") {
                showHistory = true
            }

            Spacer()

            glassIcon("calculator", accessibility: "Modos da calculadora") {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    showModeMenu.toggle()
                }
            }
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.8).onEnded { _ in
                showModeMenu = false
                onContinue()
            })
            .accessibilityAction(named: Text("Entrar no aplicativo")) { onContinue() }
        }
        .frame(height: 44)
    }

    private func glassIcon(_ symbol: String, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if symbol == "calculator" {
                    CalculatorSwitcherGlyph()
                        .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                        .frame(width: 16, height: 19)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.7))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    private var mainDisplay: some View {
        Text(display)
            .font(.system(size: mode == .basic ? 70 : 48, weight: .light, design: .default))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.35)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("Resultado \(display)")
    }

    private var conversionDisplay: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showingEURFirst.toggle() }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(operatorColor)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(display)
                    .font(.system(size: 38, weight: .light))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                Text(showingEURFirst ? "EUR" : "BRL")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Rectangle().fill(Color.white.opacity(0.14)).frame(height: 0.5)
            HStack(spacing: 5) {
                Spacer()
                Text("0,00")
                    .font(.system(size: 28, weight: .light))
                Text(showingEURFirst ? "BRL" : "EUR")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 4)
    }

    private var modeMenu: some View {
        VStack(spacing: 0) {
            modeRow(.basic, title: "Básica", icon: "plus.forwardslash.minus")
            modeRow(.scientific, title: "Científica", icon: "function")
            modeRow(.notes, title: "Notas de Cálculo", icon: "note.text")
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.7).padding(.horizontal, 14).padding(.vertical, 6)
            modeRow(.conversion, title: "Conversão", icon: "arrow.left.arrow.right")
        }
        .padding(.vertical, 8)
        .frame(width: 238)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .environment(\.colorScheme, .dark)
    }

    private func modeRow(_ selectedMode: CalculatorMode, title: String, icon: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showModeMenu = false
                if selectedMode == .notes {
                    showNotesAlert = true
                } else {
                    mode = selectedMode
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 17)
                Text(title)
                    .font(.system(size: 14, weight: .regular))
                Spacer(minLength: 8)
                if mode == selectedMode {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 15)
                }
            }
            .foregroundStyle(.white.opacity(0.96))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var historySheet: some View {
        ZStack {
            Color(red: 0.045, green: 0.045, blue: 0.05).ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    Button { showHistory = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                VStack(spacing: 9) {
                    Image(systemName: "clock")
                        .font(.system(size: 24, weight: .light))
                    Text("Sem Histórico")
                        .font(.system(size: 14, weight: .regular))
                }
                .foregroundStyle(.white.opacity(0.72))
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
    }

    private func scientificKeypad(availableWidth: CGFloat) -> some View {
        let keys = [
            ["(", ")", "mc", "m+", "m-", "mr"],
            ["2nd", "x²", "x³", "xʸ", "eˣ", "10ˣ"],
            ["¹⁄ₓ", "²√x", "³√x", "ʸ√x", "ln", "log₁₀"],
            ["x!", "sen", "cos", "tg", "e", "EE"],
            ["Rand", "senh", "cosh", "tgh", "π", degreesMode ? "Deg" : "Rad"]
        ]
        return VStack(spacing: 7) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7) {
                    ForEach(row, id: \.self) { key in
                        Button { scientificAction(key) } label: {
                            Text(key)
                                .font(.system(size: key.count > 3 ? 12 : 14, weight: .medium))
                                .minimumScaleFactor(0.65)
                                .lineLimit(1)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(numberColor.opacity(0.98), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func basicKeypad(keyHeight: CGFloat) -> some View {
        let rows: [[CalculatorKey]] = [
            [CalculatorKey(symbol: "delete.left", label: nil, kind: .function, action: .backspace), .text("AC", .function, .clear), .text("%", .function, .percent), .text("÷", .operatorKey, .divide)],
            [.text("7", .number, .digit("7")), .text("8", .number, .digit("8")), .text("9", .number, .digit("9")), .text("×", .operatorKey, .multiply)],
            [.text("4", .number, .digit("4")), .text("5", .number, .digit("5")), .text("6", .number, .digit("6")), .text("−", .operatorKey, .subtract)],
            [.text("1", .number, .digit("1")), .text("2", .number, .digit("2")), .text("3", .number, .digit("3")), .text("+", .operatorKey, .add)],
            [.text("+/−", .number, .toggleSign), .text("0", .number, .digit("0")), .text(",", .number, .decimal), .text("=", .operatorKey, .equals)]
        ]
        return VStack(spacing: mode == .basic ? 8 : 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                        Button { perform(key.action) } label: {
                            Group {
                                if let symbol = key.symbol {
                                    Image(systemName: symbol)
                                        .font(.system(size: key.label == nil ? 27 : 33, weight: .regular))
                                } else {
                                    Text(key.label ?? "")
                                        .font(.system(size: key.label == "AC" ? 30 : 35, weight: .regular))
                                        .minimumScaleFactor(0.65)
                                        .lineLimit(1)
                                }
                            }
                            .foregroundStyle(foreground(for: key.kind))
                            .frame(maxWidth: .infinity)
                            .frame(height: keyHeight)
                            .background(background(for: key.kind), in: Circle())
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func foreground(for kind: CalculatorKey.Kind) -> Color {
        kind == .function ? .black : .white
    }

    private func background(for kind: CalculatorKey.Kind) -> Color {
        switch kind {
        case .number: numberColor
        case .function: functionColor
        case .operatorKey: operatorColor
        }
    }

    private func perform(_ action: CalculatorAction) {
        switch action {
        case .digit(let value): inputDigit(value)
        case .decimal:
            if waitingForInput { display = "0"; waitingForInput = false }
            if !display.contains(",") { display += "," }
        case .clear:
            display = "0"
            storedValue = 0
            currentOperation = nil
            waitingForInput = false
        case .backspace:
            if waitingForInput { return }
            if display.count <= 1 || (display.count == 2 && display.hasPrefix("-")) {
                display = "0"
            } else {
                display.removeLast()
            }
        case .percent:
            let value = currentValue / 100
            display = formatted(currentOperation == .add || currentOperation == .subtract ? storedValue * value : value)
        case .toggleSign:
            if currentValue != 0 { display = formatted(-currentValue) }
        case .divide: setOperation(.divide)
        case .multiply: setOperation(.multiply)
        case .subtract: setOperation(.subtract)
        case .add: setOperation(.add)
        case .equals: calculate()
        }
    }

    private func inputDigit(_ digit: String) {
        if waitingForInput {
            display = digit
            waitingForInput = false
        } else if display == "0" {
            display = digit
        } else if display.count < 14 {
            display += digit
        }
    }

    private func setOperation(_ operation: CalculatorOperation) {
        if let currentOperation, !waitingForInput {
            storedValue = apply(currentOperation, lhs: storedValue, rhs: currentValue)
            display = formatted(storedValue)
        } else {
            storedValue = currentValue
        }
        currentOperation = operation
        waitingForInput = true
    }

    private func calculate() {
        guard let currentOperation else { return }
        let result = apply(currentOperation, lhs: storedValue, rhs: currentValue)
        display = formatted(result)
        storedValue = result
        self.currentOperation = nil
        waitingForInput = true
    }

    private func apply(_ operation: CalculatorOperation, lhs: Double, rhs: Double) -> Double {
        switch operation {
        case .add: return lhs + rhs
        case .subtract: return lhs - rhs
        case .multiply: return lhs * rhs
        case .divide: return rhs == 0 ? 0 : lhs / rhs
        case .power: return pow(lhs, rhs)
        case .root: return rhs == 0 ? 0 : pow(lhs, 1 / rhs)
        }
    }

    private func scientificAction(_ key: String) {
        let value = currentValue
        switch key {
        case "2nd": secondFunctions.toggle()
        case "mc": memoryValue = 0
        case "m+": memoryValue += value
        case "m-": memoryValue -= value
        case "mr": display = formatted(memoryValue)
        case "x²": display = formatted(pow(value, 2))
        case "x³": display = formatted(pow(value, 3))
        case "xʸ": setOperation(.power)
        case "eˣ": display = formatted(exp(value))
        case "10ˣ": display = formatted(pow(10, value))
        case "¹⁄ₓ": display = value == 0 ? "0" : formatted(1 / value)
        case "²√x": display = value < 0 ? "0" : formatted(sqrt(value))
        case "³√x": display = formatted(value < 0 ? -pow(-value, 1 / 3) : pow(value, 1 / 3))
        case "ʸ√x": setOperation(.root)
        case "ln": display = value <= 0 ? "0" : formatted(log(value))
        case "log₁₀": display = value <= 0 ? "0" : formatted(log10(value))
        case "x!": display = formatted(factorial(value))
        case "sen": display = formatted(sin(angle(value)))
        case "cos": display = formatted(cos(angle(value)))
        case "tg": display = formatted(tan(angle(value)))
        case "e": display = formatted(exp(1))
        case "EE": display += "e"
        case "Rand": display = formatted(Double.random(in: 0..<1))
        case "senh": display = formatted(sinh(value))
        case "cosh": display = formatted(cosh(value))
        case "tgh": display = formatted(tanh(value))
        case "π": display = formatted(Double.pi)
        case "Rad", "Deg": degreesMode.toggle()
        case "yˣ": setOperation(.power)
        default: break
        }
        if !["2nd", "mc", "m+", "m-", "mr", "xʸ", "ʸ√x", "Rad", "Deg"].contains(key) {
            waitingForInput = true
        }
    }

    private var currentValue: Double {
        Double(display.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func angle(_ value: Double) -> Double {
        degreesMode ? value * .pi / 180 : value
    }

    private func factorial(_ value: Double) -> Double {
        guard value >= 0, value.rounded() == value, value <= 170 else { return 0 }
        return (1...max(1, Int(value))).reduce(1.0) { $0 * Double($1) }
    }

    private func formatted(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == 0 { return "0" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 8
        formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }
}

private enum CalculatorMode: Equatable {
    case basic, scientific, notes, conversion
}

private enum CalculatorOperation: Equatable {
    case add, subtract, multiply, divide, power, root
}

private enum CalculatorAction {
    case digit(String), decimal, clear, backspace, percent, toggleSign
    case divide, multiply, subtract, add, equals
}

private struct CalculatorKey {
    enum Kind: Equatable { case number, function, operatorKey }
    let symbol: String?
    let label: String?
    let kind: Kind
    let action: CalculatorAction

    static func text(_ label: String, _ kind: Kind, _ action: CalculatorAction) -> CalculatorKey {
        CalculatorKey(symbol: nil, label: label, kind: kind, action: action)
    }
}

private struct CalculatorSwitcherGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 15, rect.height / 18)
        let x = (rect.width - 12 * scale) / 2
        let y = (rect.height - 16 * scale) / 2
        var path = Path()

        let body = CGRect(x: x, y: y, width: 12 * scale, height: 16 * scale)
        path.addRoundedRect(in: body, cornerSize: CGSize(width: 2 * scale, height: 2 * scale))

        let display = CGRect(x: x + 2.5 * scale, y: y + 2 * scale, width: 7 * scale, height: 3 * scale)
        path.addRoundedRect(in: display, cornerSize: CGSize(width: 0.7 * scale, height: 0.7 * scale))

        for row in 0..<3 {
            for column in 0..<2 {
                let dot = CGRect(
                    x: x + (3 + CGFloat(column) * 3.5) * scale,
                    y: y + (7.5 + CGFloat(row) * 2.5) * scale,
                    width: 1.2 * scale,
                    height: 1.2 * scale
                )
                path.addEllipse(in: dot)
            }
        }
        return path
    }
}

private final class CalculatorEntryTriggerMonitor: ObservableObject {
    private var batteryObserver: NSObjectProtocol?
    private var volumeObservation: NSKeyValueObservation?
    private var onEnter: (() -> Void)?
    private var lastObservedVolume: Float = 0
    private var previousBatteryMonitoringEnabled = false
    private var previousAudioCategory: AVAudioSession.Category?
    private var previousAudioMode: AVAudioSession.Mode?
    private var previousAudioOptions: AVAudioSession.CategoryOptions = []
    private var audioSessionConfiguredByMonitor = false
    private var audioSessionActivatedByMonitor = false
    private var isRunning = false
    private var didEnter = false

    func start(onEnter: @escaping () -> Void) {
        guard !isRunning else { return }
        isRunning = true
        didEnter = false
        self.onEnter = onEnter

        let device = UIDevice.current
        previousBatteryMonitoringEnabled = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        batteryObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: device,
            queue: .main
        ) { [weak self] _ in
            self?.enterIfCharging()
        }

        let audioSession = AVAudioSession.sharedInstance()
        previousAudioCategory = audioSession.category
        previousAudioMode = audioSession.mode
        previousAudioOptions = audioSession.categoryOptions
        do {
            try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            audioSessionConfiguredByMonitor = true
            try audioSession.setActive(true)
            audioSessionActivatedByMonitor = true
        } catch {
            // Continue observing; the session may already be configured elsewhere.
        }
        lastObservedVolume = audioSession.outputVolume
        volumeObservation = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let newVolume = change.newValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning else { return }
                let volumeDecreased = newVolume < self.lastObservedVolume
                self.lastObservedVolume = newVolume
                if volumeDecreased { self.enter() }
            }
        }

        enterIfCharging()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let batteryObserver {
            NotificationCenter.default.removeObserver(batteryObserver)
            self.batteryObserver = nil
        }
        volumeObservation?.invalidate()
        volumeObservation = nil
        let audioSession = AVAudioSession.sharedInstance()
        if audioSessionActivatedByMonitor {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActivatedByMonitor = false
        }
        if audioSessionConfiguredByMonitor,
           let previousAudioCategory,
           let previousAudioMode {
            try? audioSession.setCategory(previousAudioCategory, mode: previousAudioMode, options: previousAudioOptions)
            audioSessionConfiguredByMonitor = false
        }
        onEnter = nil
        if !previousBatteryMonitoringEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = false
        }
    }

    private func enterIfCharging() {
        switch UIDevice.current.batteryState {
        case .charging, .full:
            enter()
        default:
            break
        }
    }

    private func enter() {
        guard isRunning, !didEnter else { return }
        didEnter = true
        onEnter?()
    }

    deinit {
        if let batteryObserver { NotificationCenter.default.removeObserver(batteryObserver) }
        volumeObservation?.invalidate()
    }
}
