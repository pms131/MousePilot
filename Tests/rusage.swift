// Prints a process's CPU time and the part of it on performance cores (ms), and the
// instructions it has run, for scripts/check.sh: instructions do not depend on which cores
// macOS picked, time does.
import Darwin

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
var info = rusage_info_v6()
let status = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
}
guard status == 0 else { exit(1) }
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func ms(_ t: UInt64) -> UInt64 { t * UInt64(timebase.numer) / UInt64(timebase.denom) / 1_000_000 }
print(ms(info.ri_user_time + info.ri_system_time), ms(info.ri_user_ptime + info.ri_system_ptime), info.ri_instructions)
