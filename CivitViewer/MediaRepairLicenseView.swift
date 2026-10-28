import SwiftUI

struct MediaRepairLicenseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("FFmpeg").font(.title2.bold())
                Text("This software uses libraries from the FFmpeg project under the LGPLv2.1 or later.")
                Text("本机视频修复使用 FFmpeg 读取、转封装和解码，使用 Apple VideoToolbox 编码兼容视频。本构建未启用 GPL、nonfree 或 libx264。")
                Link("FFmpeg 官方网站", destination: URL(string: "https://ffmpeg.org/")!)
                if let url = Bundle.main.url(forResource: "FFmpeg-LGPL", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) {
                    Text(text).font(.caption).textSelection(.enabled)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.navigationTitle("开源组件").ordinaryAppearance()
    }
}
