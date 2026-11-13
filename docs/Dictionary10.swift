import Foundation
import Darwin
import PronunciationEnglish
func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    } }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}
var rows: [[String:Any]] = []
for british in [false,true] {
    let before = footprint(), start = ProcessInfo.processInfo.systemUptime
    let lexicon = try Lexicon(british: british)
    let seconds = ProcessInfo.processInfo.systemUptime - start
    rows.append(["british":british, "coldSeconds":seconds, "beforeFootprint":before, "afterFootprint":footprint(), "probe":lexicon.getNNP("Alice").0 ?? ""])
    withExtendedLifetime(lexicon) {}
}
print(String(decoding:try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
