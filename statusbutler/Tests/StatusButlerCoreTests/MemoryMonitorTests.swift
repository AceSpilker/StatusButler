import Foundation
import Testing
@testable import StatusButlerCore

// T-027: 内存换算纯函数（固定值断言）+ swap 文本解析 + live 冒烟
@Suite struct MemoryMonitorTests {
    @Test func mapsPagesToBytesWithDocumentedUsedFormula() {
        // used 口径 = active + wired + compressed（页 × pageSize）
        let stats = VMStatisticsValues(
            activePages: 100, wiredPages: 50, compressedPages: 25, freePages: 825, pageSize: 4096
        )
        let usage = MemoryMonitor.usage(stats: stats, totalBytes: 4096 * 1024, swapUsedBytes: 2048)
        #expect(usage.totalBytes == 4_194_304)
        #expect(usage.wiredBytes == 204_800)        // 50 × 4096
        #expect(usage.compressedBytes == 102_400)   // 25 × 4096
        #expect(usage.freeBytes == 3_379_200)       // 825 × 4096
        #expect(usage.usedBytes == 100 * 4096 + 204_800 + 102_400)  // 716_800
        #expect(usage.swapUsedBytes == 2048)
    }

    @Test func sixteenKPagesMapCorrectly() {
        // Apple Silicon 16K 页：换算不写死 4096
        let stats = VMStatisticsValues(
            activePages: 1, wiredPages: 1, compressedPages: 1, freePages: 1, pageSize: 16_384
        )
        let usage = MemoryMonitor.usage(stats: stats, totalBytes: 65_536, swapUsedBytes: 0)
        #expect(usage.usedBytes == 49_152)  // 3 × 16384
        #expect(usage.freeBytes == 16_384)
    }

    @Test func swapParsingHandlesUnits() {
        #expect(
            MemoryMonitor.parseSwapUsedBytes(
                "total = 1024.00M  used = 1.50M  free = 1022.50M  (encrypted)"
            ) == 1_572_864
        )
        #expect(
            MemoryMonitor.parseSwapUsedBytes(
                "total = 4096.00M  used = 0.00M  free = 4096.00M  (encrypted)"
            ) == 0
        )
        #expect(
            MemoryMonitor.parseSwapUsedBytes("total = 2.00G  used = 512.00K  free = 2047.50M") == 524_288
        )
        #expect(
            MemoryMonitor.parseSwapUsedBytes("total = 1.00T  used = 2.00G  free = 1022.00G")
                == 2_147_483_648
        )
        // 无 used 字段 → nil（不猜 0，交给调用方决定降级语义）
        #expect(MemoryMonitor.parseSwapUsedBytes("free = 0M") == nil)
        #expect(MemoryMonitor.parseSwapUsedBytes("") == nil)
    }

    // MARK: - live 冒烟（只验不变量，不断言具体内存值）

    @Test func liveReadStaysWithinPhysicalTotal() async {
        guard let usage = await MemoryMonitor().read() else { return }
        #expect(usage.totalBytes > 0)
        #expect(usage.usedBytes <= usage.totalBytes)
        #expect(usage.freeBytes <= usage.totalBytes)
        // used 包含 wired 与 compressed（口径自洽）
        #expect(usage.wiredBytes <= usage.usedBytes)
        #expect(usage.compressedBytes <= usage.usedBytes)
    }

    @Test func liveSwapValueIsSaneOrNull() {
        guard let swap = MemoryMonitor.swapUsedBytes() else { return }
        #expect(swap < 1 << 40)  // < 1TB：解析错单位（比如把 M 当字节）在这里暴露
    }
}
