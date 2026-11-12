import SwiftUI
import UserNotifications
import Darwin

// MARK: - Read the system network counters (cumulative since boot)

enum NetCounters {
    /// Returns [wifiIn, wifiOut, cellIn, cellOut] in bytes.
    /// en0 = Wi-Fi, pdp_ip* = cellular.
    static func read() -> [Double] {
        var wifiIn = 0.0, wifiOut = 0.0, cellIn = 0.0, cellOut = 0.0
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [0, 0, 0, 0] }
        defer { freeifaddrs(head) }

        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr,
               Int32(addr.pointee.sa_family) == AF_LINK,
               let raw = ifa.ifa_data {
                let name = String(cString: ifa.ifa_name)
                let d = raw.assumingMemoryBound(to: if_data.self).pointee
                let rx = Double(d.ifi_ibytes), tx = Double(d.ifi_obytes)
                if name == "en0" { wifiIn += rx; wifiOut += tx }
                else if name.hasPrefix("pdp_ip") { cellIn += rx; cellOut += tx }
            }
            cur = ifa.ifa_next
        }
        return [wifiIn, wifiOut, cellIn, cellOut]
    }
}

// MARK: - Notifications

final class NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }
}

func notify(_ title: String, _ body: String) {
    let c = UNMutableNotificationContent()
    c.title = title; c.body = body; c.sound = .default
    UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
}

// MARK: - Model

final class Meter: ObservableObject {
    private let gb = 1_000_000_000.0   // decimal GB, like carriers

    @Published var running: Bool           { didSet { UserDefaults.standard.set(running, forKey: "running") } }
    @Published var wifiUsed: Double        { didSet { UserDefaults.standard.set(wifiUsed, forKey: "wifiUsed") } }
    @Published var cellUsed: Double        { didSet { UserDefaults.standard.set(cellUsed, forKey: "cellUsed") } }
    @Published var wifiQuotaGB: Double     { didSet { UserDefaults.standard.set(wifiQuotaGB, forKey: "wifiQuotaGB") } }
    @Published var cellQuotaGB: Double     { didSet { UserDefaults.standard.set(cellQuotaGB, forKey: "cellQuotaGB") } }
    @Published var alertPercent: Double    { didSet { UserDefaults.standard.set(alertPercent, forKey: "alertPercent") } }

    private var last: [Double]
    private var fired: Set<String>

    init() {
        let d = UserDefaults.standard
        running      = d.bool(forKey: "running")
        wifiUsed     = d.double(forKey: "wifiUsed")
        cellUsed     = d.double(forKey: "cellUsed")
        wifiQuotaGB  = d.object(forKey: "wifiQuotaGB") as? Double ?? 10
        cellQuotaGB  = d.object(forKey: "cellQuotaGB") as? Double ?? 5
        alertPercent = d.object(forKey: "alertPercent") as? Double ?? 80
        last         = d.array(forKey: "last") as? [Double] ?? NetCounters.read()
        fired        = Set(d.stringArray(forKey: "fired") ?? [])
    }

    func askPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Counters are 32-bit and reset on reboot, so handle both cases.
    private func delta(_ new: Double, _ old: Double) -> Double {
        if new >= old { return new - old }
        let wrap = 4_294_967_296.0
        return (old - new) > wrap / 2 ? new + wrap - old : new
    }

    func tick() {
        let now = NetCounters.read()
        if running {
            wifiUsed += delta(now[0], last[0]) + delta(now[1], last[1])
            cellUsed += delta(now[2], last[2]) + delta(now[3], last[3])
            check("Wi-Fi", wifiUsed, wifiQuotaGB, "w")
            check("بيانات الجوال", cellUsed, cellQuotaGB, "c")
        }
        last = now
        UserDefaults.standard.set(last, forKey: "last")
    }

    private func check(_ name: String, _ used: Double, _ quotaGB: Double, _ key: String) {
        guard quotaGB > 0 else { return }
        let quota = quotaGB * gb
        let fmt = ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .file)
        if used >= quota * alertPercent / 100, !fired.contains(key + "W") {
            fired.insert(key + "W"); saveFired()
            notify("تنبيه استهلاك البيانات", "\(name): وصلت إلى \(Int(alertPercent))٪ من الحد (\(fmt)).")
        }
        if used >= quota, !fired.contains(key + "F") {
            fired.insert(key + "F"); saveFired()
            notify("انتهت الكمية", "\(name): استهلكت الكمية كاملة (\(fmt)).")
        }
    }

    private func saveFired() { UserDefaults.standard.set(Array(fired), forKey: "fired") }

    func start() { last = NetCounters.read(); running = true }
    func stop()  { tick(); running = false }
    func reset() {
        wifiUsed = 0; cellUsed = 0
        fired = []; saveFired()
        last = NetCounters.read()
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var m = Meter()
    @Environment(\.scenePhase) private var phase
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(m.running ? "العداد يعمل" : "العداد متوقف")) {
                    usageRow("Wi-Fi", m.wifiUsed, m.wifiQuotaGB)
                    usageRow("بيانات الجوال", m.cellUsed, m.cellQuotaGB)
                }
                Section {
                    Button(m.running ? "إيقاف العداد" : "تشغيل العداد") {
                        m.running ? m.stop() : m.start()
                    }
                    Button("تصفير", role: .destructive) { m.reset() }
                }
                Section(header: Text("الحدود والتنبيهات"),
                        footer: Text("ضع 0 لتعطيل الحد. التنبيه يصل أثناء فتح التطبيق، وعند فتحه لاحقاً إذا تجاوزت الحد وهو مغلق.")) {
                    quotaField("حد Wi-Fi (GB)", $m.wifiQuotaGB)
                    quotaField("حد بيانات الجوال (GB)", $m.cellQuotaGB)
                    Stepper("تنبيه عند \(Int(m.alertPercent))٪", value: $m.alertPercent, in: 1...100, step: 5)
                }
            }
            .navigationTitle("عداد البيانات")
        }
        .environment(\.layoutDirection, .rightToLeft)
        .onReceive(timer) { _ in m.tick() }
        .onChange(of: phase) { _ in m.tick() }
        .onAppear { m.askPermission(); m.tick() }
    }

    private func usageRow(_ title: String, _ used: Double, _ quotaGB: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .file))
                    .monospacedDigit()
            }
            if quotaGB > 0 {
                ProgressView(value: min(used / (quotaGB * 1_000_000_000), 1))
            }
        }
    }

    private func quotaField(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
    }
}

@main
struct DataMeterApp: App {
    init() { UNUserNotificationCenter.current().delegate = NotifDelegate.shared }
    var body: some Scene { WindowGroup { ContentView() } }
}
